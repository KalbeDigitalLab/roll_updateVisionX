#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const axios = require('axios');
const { URLSearchParams } = require('url');
const consoleUtils = require('../utils/consoleUtils');

// =================== CONFIG ===================
const {
    CANON,
    AUTH_TYPE,
    BEARER_TOKEN: BEARER_TOKEN_ENV,
    BASIC_USER,
    BASIC_PASS,
    TOKEN_SCOPE,
    CURL_INSECURE,

    DCM_BASE,
    DCM_AET,
    KC_TOKEN_URL,
    KC_CLIENT_ID,
    KC_CLIENT_SECRET,
    KC_USERNAME,
    KC_PASSWORD
} = process.env;

// [1] Configurable page size (default 1000 - optimal balance)
const LIMIT = parseInt(process.env.PATIENT_PAGE_SIZE || '1000', 10);
// [2] Tentukan mode Dry Run (dibaca dari run.sh, default 'false')
const DRY_RUN = (process.env.DRY_RUN || 'false').toLowerCase() === 'true';
let BEARER_TOKEN = BEARER_TOKEN_ENV || ''; // Default '' aman

// Set 'true' untuk mengabaikan error TLS (seperti curl -k)
const NODE_TLS_REJECT_UNAUTHORIZED = (CURL_INSECURE || 'false').toLowerCase() === 'true' ? '0' : '1';
process.env.NODE_TLS_REJECT_UNAUTHORIZED = NODE_TLS_REJECT_UNAUTHORIZED;

// ================ INTERNALS ===================
const ts = new Date().toISOString().replace(/[-:.]/g, '').replace('T', '_').substring(0, 15);
const LOG_DIR = path.join(__dirname, `merge_logs_${ts}`);
const OPS_CSV = path.join(LOG_DIR, 'merged_ops.csv');

// Global Axios instance for QIDO/merge calls
const api = axios.create();

function normalizeIssuer(issuer) {
  // Only treat truly empty/null as empty; keep `.null` suffixes so we can merge them explicitly
  if (!issuer) return "";

  if (typeof issuer === "string") {
    // Check if issuer has the pattern ending with .null
    if (issuer.toLowerCase().endsWith(".null")) {
      // Handle cases like "DCM4CHEE.xxx.null"
      if (issuer.toLowerCase().startsWith("dcm4chee.")) {
        return "elvasoft";
      }

      // Handle cases like "^^^DCM4CHEE.xxx.null" (just the issuer part after ^^^)
      if (issuer.toLowerCase().startsWith("^^^dcm4chee.")) {
        return "^^^elvasoft";
      }

      // Handle cases like "prefix^^^DCM4CHEE.xxx.null"
      const prefixMatch = issuer.match(/^(.+)\^\^\^(DCM4CHEE\.[^.]*)\.null$/i);
      if (prefixMatch) {
        const prefix = prefixMatch[1]; // This captures the prefix before ^^^
        return prefix + "^^^elvasoft";
      }

      // Handle cases like "04.18.26DCM4CHEE.E016EE26.null" where there's no separator
      const directMatch = issuer.match(/^(.*?)(DCM4CHEE\.[^.]*)\.null$/i);
      if (directMatch) {
        const prefix = directMatch[1]; // This captures any prefix before DCM4CHEE
        return prefix + "elvasoft";
      }

      // If it's just ending with .null but not in DCM4CHEE format, return empty string
      return "";
    }
  }
  return issuer;
}

/**
 * Fetches the OIDC token if required.
 */
async function getToken() {
  consoleUtils.info('Attempting to fetch auth token...');
  try {
    const params = new URLSearchParams();
    params.append('grant_type', 'password');
    params.append('client_secret', KC_CLIENT_SECRET);
    params.append('client_id', KC_CLIENT_ID);
    params.append('username', KC_USERNAME);
    params.append('password', KC_PASSWORD);
    params.append('scope', TOKEN_SCOPE);

    const response = await axios.post(KC_TOKEN_URL, params, {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    });

    const token = response.data?.access_token;
    if (!token) {
      throw new Error('access_token not found in response');
    }
    consoleUtils.success(`Token fetched successfully: ${token.substring(0, 20)}...`);
    return token;
  } catch (err) {
    consoleUtils.error(`Failed to fetch auth token: ${err.response?.data || err.message}`);
    throw err;
  }
}

/**
 * Configures the global axios instance with auth headers.
 */
async function setupAuth() {
  if (AUTH_TYPE === 'bearer' && !BEARER_TOKEN) {
    BEARER_TOKEN = await getToken();
  }

  switch (AUTH_TYPE) {
    case 'bearer':
      api.defaults.headers.common['Authorization'] = `Bearer ${BEARER_TOKEN}`;
      break;
    case 'basic':
      const basicToken = Buffer.from(`${BASIC_USER}:${BASIC_PASS}`).toString('base64');
      api.defaults.headers.common['Authorization'] = `Basic ${basicToken}`;
      break;
    case 'none':
      // No auth needed
      break;
    default:
      throw new Error(`AUTH_TYPE must be bearer|basic|none, got: ${AUTH_TYPE}`);
  }
}

/**
 * URL-encodes a string.
 */
function urlencode(str) {
  return encodeURIComponent(str);
}

/**
 * Fetches a single page of patients.
 */
async function qidoPatientsPage(offset) {
  const url = `${DCM_BASE}/${DCM_AET}/rs/patients?includefield=all&offset=${offset}&limit=${LIMIT}`;
  const response = await api.get(url);
  return response.data;
}

/**
 * Picks the best demographic data for a given PatientID.
 * Prefers data from the canonical issuer, otherwise from the most recent study.
 */
async function pickDemoForPid(pid) {
  const pidEnc = urlencode(pid);

  // 1. Prioritas 1: Coba dapatkan demo dari Patient Record Kanonis
  try {
    const patUrl = `${DCM_BASE}/${DCM_AET}/rs/patients?00100020=${pidEnc}&includefield=all`;
    const patResponse = await api.get(patUrl);
    const pats_json = patResponse.data;

    // Equivalent of: if ! echo "$pats_json" | jq -e 'type=="array"'
    if (!Array.isArray(pats_json)) {
      // Jika bukan array (misal string warning dari server), perlakukan sebagai empty.
      return { name: '', dob: '', sex: '' }; 
    }

    // Cari entri yang memiliki CANON issuer
    const canonicalPat = pats_json.find(p => p['00100021']?.Value[0] === CANON);

    let name = '';
    let dob = '';
    let sex = '';

    if (canonicalPat) {
      // Ambil data jika canonicalPat ditemukan
      name = canonicalPat['00100010']?.Value[0]?.Alphabetic ?? '';
      dob = canonicalPat['00100030']?.Value[0] ?? '';
      sex = canonicalPat['00100040']?.Value[0] ?? '';
    }

    if (name || dob || sex) {
      // Jika ada data yang ditemukan dari canonical patient record, kembalikan
      return { name, dob, sex };
    }

  } catch (err) {
    // Jika fetch gagal total (misal 404, 500, atau koneksi), dicatat dan lanjut ke Prioritas 2
    consoleUtils.warn(`Could not fetch patient records for ${pid}: ${err.message}`);
  }

  // 2. Prioritas 2: Jika tidak ditemukan, dapatkan demo dari studi terbaru
  try {
    const studyUrl = `${DCM_BASE}/${DCM_AET}/rs/studies?00100020=${pidEnc}&includefield=all`;
    const studyResponse = await api.get(studyUrl);
    const studies_json = studyResponse.data;

    // Equivalent of: if ! echo "$studies_json" | jq -e 'type=="array"'
    if (!Array.isArray(studies_json)) {
      return { name: '', dob: '', sex: '' };
    }

    // Replikasi logika dtkey dan sorting dari JQ
    const getDtKey = (study) => {
      const d = study['00080020']?.Value[0] ?? ''; // Study Date
      const t = study['00080030']?.Value[0] ?? ''; // Study Time
      return `${d}T${t}`;
    };

    const mappedStudies = studies_json.map(study => ({
      k: getDtKey(study),
      n: study['00100010']?.Value[0]?.Alphabetic ?? '',
      d: study['00100030']?.Value[0] ?? '',
      s: study['00100040']?.Value[0] ?? '',
    }));

    // Sort descending by datetime key (k)
    mappedStudies.sort((a, b) => b.k.localeCompare(a.k)); 

    const latest = mappedStudies[0] ?? {};
    return {
      name: latest.n ?? '',
      dob: latest.d ?? '',
      sex: latest.s ?? '',
    };

  } catch (err) {
    consoleUtils.warn(`Could not fetch studies for ${pid}: ${err.message}`);
    return { name: '', dob: '', sex: '' };
  }
}

/**
 * Builds the DICOM+JSON merge payload.
 */
function buildPayload(pid, name, dob, sex) {
  const payload = {
    '00100020': { vr: 'LO', Value: [pid] },
    '00100021': { vr: 'LO', Value: [CANON] },
  };
  if (name) {
    payload['00100010'] = { vr: 'PN', Value: [{ Alphabetic: name }] };
  }
  if (dob) {
    payload['00100030'] = { vr: 'DA', Value: [dob] };
  }
  if (sex) {
    payload['00100040'] = { vr: 'CS', Value: [sex] };
  }
  // The API expects an array containing this one object
  return [payload];
}

/**
 * Performs the direct update operation for patient issuer (or simulates if DRY_RUN).
 */
async function doDirectUpdate(pid, originalIssuer, payload) {
  // Use a safer URL encoding approach for special characters in patient ID
  const pathPid = encodeURIComponent(pid);
  const originalIssuerStr = originalIssuer || '<empty>';
  const url = `${DCM_BASE}/${DCM_AET}/rs/patients/${pathPid}`;

  const now = new Date().toISOString();

  if (DRY_RUN) {
    consoleUtils.info(`[DRY] PUT ${url}`);
    consoleUtils.info(`[DRY] DATA: ${JSON.stringify(payload)}`);
    const logLine = `${now},${pid},${originalIssuerStr},${CANON},direct_update,DRY_RUN\n`;
    fs.appendFileSync(OPS_CSV, logLine);
    return;
  }

  try {
    const response = await api.put(url, payload, {
      headers: { 'Content-Type': 'application/dicom+json' },
    });

    // Success (2xx status)
    const logLine = `${now},${pid},${originalIssuerStr},${CANON},direct_update,${response.status}\n`;
    fs.appendFileSync(OPS_CSV, logLine);

    consoleUtils.success(`Direct update successful for ${pid} from '${originalIssuerStr}' to '${CANON}'`);

  } catch (err) {
    // Failure (non-2xx status)
    const httpCode = err.response?.status || 'ERR_NO_RESPONSE';
    const body = err.response?.data || err.message;
    consoleUtils.warn(`Direct update failed for ${pid} ${originalIssuerStr} -> ${CANON}, HTTP ${httpCode}`);

    const logLine = `${now},${pid},${originalIssuerStr},${CANON},direct_update,ERR_${httpCode}\n`;
    fs.appendFileSync(OPS_CSV, logLine);

    const errLogFile = path.join(LOG_DIR, `err_${pid}_${originalIssuer || 'EMPTY'}_${now.replace(/:/g, '-')}.log`);
    fs.writeFileSync(errLogFile, typeof body === 'object' ? JSON.stringify(body, null, 2) : String(body));
  }
}

/**
 * Final cleanup function to get all DCM4CHEE records and individually update them
 */
async function finalCleanupDcm4cheeNullIssuers() {
  // First, let's get all patients with DCM4CHEE issuers through a broader query
  let offset = 0;
  const processedPatients = new Set(); // Track to avoid duplicate processing

  while (true) {
    let pageJson;
    try {
      // Query for all patients, we'll filter for DCM4CHEE issuers in the response
      const url = `${DCM_BASE}/${DCM_AET}/rs/patients?includefield=all&offset=${offset}&limit=${LIMIT}`;
      const response = await api.get(url);
      pageJson = response.data;
    } catch (err) {
      consoleUtils.error(`Failed to fetch patients page at offset ${offset} for final cleanup: ${err.response?.data || err.message}`);
      break;
    }

    if (!Array.isArray(pageJson) || pageJson.length === 0) {
      consoleUtils.info('No more patients found for final cleanup.');
      break;
    }

    // Process each patient found
    for (const patient of pageJson) {
      try {
        const pid = patient['00100020']?.Value[0];
        const rawIssuer = patient['00100021']?.Value?.[0];

        if (!pid || !rawIssuer) continue;

        // Check if issuer contains DCM4CHEE and ends with .null
        if (rawIssuer.toLowerCase().includes('dcm4chee') && rawIssuer.toLowerCase().endsWith('.null')) {
          // Only skip truly empty patient IDs
          if (!pid || pid.trim() === '') {
            consoleUtils.warn(`Skipping empty patient ID with issuer: ${rawIssuer}`);
            continue;
          }

          if (processedPatients.has(`${pid}|${rawIssuer}`)) continue;

          processedPatients.add(`${pid}|${rawIssuer}`);

          consoleUtils.status(`Final cleanup: Processing DCM4CHEE patient: ${pid}^^^${rawIssuer}`);

          // Get the patient demographic data from the patient record
          const name = patient['00100010']?.Value?.[0]?.Alphabetic || '';
          const dob = patient['00100030']?.Value?.[0] || '';
          const sex = patient['00100040']?.Value?.[0] || '';

          // Create payload with current data but updated issuer
          const payload = buildPayload(pid, name, dob, sex);

          // Use direct update to avoid merge conflicts
          await doDirectUpdate(pid, rawIssuer, payload);
        }
      } catch (e) {
        consoleUtils.warn('Error processing patient in final cleanup:', e.message);
      }
    }

    // [1] Check if last page - break jika data.length < LIMIT
    if (pageJson.length < LIMIT) {
      consoleUtils.info(`Last page detected for final cleanup (got ${pageJson.length} records, less than ${LIMIT})`);
      break;
    }

    offset += LIMIT;
  }
}

/**
 * Performs the merge operation (or simulates if DRY_RUN).
 */
async function doMerge(pid, srcIssuer, payload) {
  let url;
  const pathPid = urlencode(pid);
  const srcIssuerStr = srcIssuer || '<empty>';

  if (!srcIssuer) {
    url = `${DCM_BASE}/${DCM_AET}/rs/patients/${pathPid}?merge=true`;
  } else {
    const pathIss = urlencode(srcIssuer);
    url = `${DCM_BASE}/${DCM_AET}/rs/patients/${pathPid}^^^${pathIss}?merge=true`;
  }

  const now = new Date().toISOString();

  if (DRY_RUN) {
    consoleUtils.info(`[DRY] PUT ${url}`);
    consoleUtils.info(`[DRY] DATA: ${JSON.stringify(payload)}`);
    const logLine = `${now},${pid},${srcIssuerStr},${CANON},merge,DRY_RUN\n`;
    fs.appendFileSync(OPS_CSV, logLine);
    return;
  }

  try {
    const response = await api.put(url, payload, {
      headers: { 'Content-Type': 'application/dicom+json' },
    });

    // Success (2xx status)
    const logLine = `${now},${pid},${srcIssuerStr},${CANON},merge,${response.status}\n`;
    fs.appendFileSync(OPS_CSV, logLine);

  } catch (err) {
    // Failure (non-2xx status)
    const httpCode = err.response?.status || 'ERR_NO_RESPONSE';
    const body = err.response?.data || err.message;
    consoleUtils.warn(`Merge failed for ${pid} ${srcIssuerStr} -> ${CANON}, HTTP ${httpCode}`);

    const logLine = `${now},${pid},${srcIssuerStr},${CANON},merge,ERR_${httpCode}\n`;
    fs.appendFileSync(OPS_CSV, logLine);

    const errLogFile = path.join(LOG_DIR, `err_${pid}_${srcIssuer || 'EMPTY'}_${now.replace(/:/g, '-')}.log`);
    fs.writeFileSync(errLogFile, typeof body === 'object' ? JSON.stringify(body, null, 2) : String(body));
  }
}

/**
 * Main execution function.
 */
async function runPatientMerge() {

  consoleUtils.info("Memvalidasi konfigurasi (Patient Merge) dari run.sh...");

  const requiredVars = { DCM_BASE, DCM_AET, CANON, AUTH_TYPE };
  const missing = Object.keys(requiredVars).filter(key => !requiredVars[key]);

  if (missing.length > 0) {
      consoleUtils.error(`Konfigurasi di run.sh tidak lengkap.`);
      consoleUtils.error(`Variabel berikut WAJIB di-export: ${missing.join(', ')}`);
      consoleUtils.error("Proses Patient Merge dibatalkan.");
      return; // Stop
  }

  // Validasi kondisional (jika auth 'bearer' dan token tidak diset manual)
  if (AUTH_TYPE === 'bearer' && !BEARER_TOKEN) {
    const kcVars = { KC_TOKEN_URL, KC_CLIENT_ID, KC_CLIENT_SECRET, KC_USERNAME, KC_PASSWORD, TOKEN_SCOPE };
    const missingKc = Object.keys(kcVars).filter(key => !kcVars[key]);
    if (missingKc.length > 0) {
        consoleUtils.error(`AUTH_TYPE='bearer' dan BEARER_TOKEN kosong.`);
        consoleUtils.error(`Skrip perlu mengambil token, tapi variabel ini tidak diset di run.sh: ${missingKc.join(', ')}`);
        consoleUtils.error("Proses Patient Merge dibatalkan.");
        return;
    }
  }

  // Validasi kondisional (jika auth 'basic')
  if (AUTH_TYPE === 'basic') {
      if (!BASIC_USER || !BASIC_PASS) {
          consoleUtils.error(`AUTH_TYPE='basic', tapi BASIC_USER atau BASIC_PASS kosong di run.sh.`);
          consoleUtils.error("Proses Patient Merge dibatalkan.");
          return;
      }
  }

  consoleUtils.success("Konfigurasi (Patient Merge) valid.");
  
  await setupAuth();

  // Setup logging
  fs.mkdirSync(LOG_DIR, { recursive: true });
  const csvHeader = 'timestamp,patient_id,src_issuer,target_issuer,action,result\n';
  fs.writeFileSync(OPS_CSV, csvHeader);
  consoleUtils.info(`Logging operations to: ${OPS_CSV}`);

  // --- 1. Build PatientID -> Issuers map ---
  consoleUtils.info('Building PatientID -> issuers map...');
  const pidIssuersMap = new Map();
  const seen = new Set();
  let offset = 0;

  while (true) {
    let pageJson;
    try {
      pageJson = await qidoPatientsPage(offset);
    } catch (err) {
      consoleUtils.error(`Failed to fetch patient page at offset ${offset}: ${err.response?.data || err.message}`);
      break;
    }

    if (!Array.isArray(pageJson) || pageJson.length === 0) {
      consoleUtils.info('No more patients found.');
      break;
    }

    for (const patient of pageJson) {
      try {
        const pid = patient['00100020']?.Value[0];
        const rawIssuer = patient['00100021']?.Value?.[0];
        const issuer = normalizeIssuer(rawIssuer); 

        if (!pid) continue;
        const key = `${pid}|${issuer}`;
        if (seen.has(key)) continue;
        seen.add(key);

        if (!pidIssuersMap.has(pid)) {
          pidIssuersMap.set(pid, new Set());
        }
        pidIssuersMap.get(pid).add(issuer);
        
      } catch (e) {
        consoleUtils.warn('Skipping malformed patient record:', patient);
      }
    }

    // [1] Check if last page - break jika data.length < LIMIT
    if (pageJson.length < LIMIT) {
      consoleUtils.info(`Last page detected (got ${pageJson.length} records, less than ${LIMIT})`);
      break;
    }

    offset += LIMIT;
  }

  consoleUtils.info(`Found ${pidIssuersMap.size} unique PatientIDs.`);

  // --- 2. Merge per PID into canonical issuer ---
  consoleUtils.info(`Merging per PID into canonical issuer ${CANON}...`);

  for (const [pid, issuersSet] of pidIssuersMap.entries()) {
    const issuers = Array.from(issuersSet);

    if (issuers.length === 1 && issuers[0] === CANON) {
      continue;
    }
    consoleUtils.status(`Processing PID ${pid} with issuers: [${issuers.join(', ')}]`);

    // 1. Cek: Apakah hanya ada 1 issuer DAN itu adalah <empty>? (Kasus HTTP 409)
    if (issuers.length === 1 && !issuers[0]) {
        consoleUtils.warn(`  [SKIP/409] Hanya ada issuer <empty>. Server biasanya menolak (409). Dilewatkan; tangani via SQL cleanup.`);
        const now = new Date().toISOString();
        const logLine = `${now},${pid},<empty>,${CANON},merge,SKIP_EMPTY_ISSUER\n`;
        fs.appendFileSync(OPS_CSV, logLine);
        continue;
    }

    let seed = issuers.find(iss => iss === CANON);
    if (!seed) {
      seed = issuers.find(iss => iss && iss !== CANON && iss !== 'DCM4CHEE.null.null');
    }
    if (seed === undefined) {
      seed = issuers[0];
    }

    const demo = await pickDemoForPid(pid);

    // Kirim hanya field yang tersedia; jika sebagian kosong, tetap lanjut dengan payload parsial
    const name = (demo.name || '').trim();
    const dob = (demo.dob || '').trim();
    const sex = (demo.sex || '').trim();

    const missingFields = [];
    if (!name) missingFields.push('name');
    if (!dob) missingFields.push('dob');
    if (!sex) missingFields.push('sex');

    if (missingFields.length > 0) {
      consoleUtils.warn(`  Demografi parsial untuk ${pid}. Field kosong: ${missingFields.join(', ')}. Mengirim payload hanya dengan field yang ada.`);
    }

    const payload = buildPayload(pid, name, dob, sex);

    // For issuers that are DCM4CHEE type, use direct update instead of merge to avoid merge conflicts
    // This approach works for updating the issuer from DCM4CHEE formats to elvasoft directly
    for (const iss of issuers) {
      if (iss === CANON) continue;

      if (!iss) { // Jika 'iss' adalah string kosong atau null
        continue; // Lanjut ke issuer berikutnya
      }

      // Check if this is a DCM4CHEE issuer (contains DCM4CHEE) - use direct update
      if (iss.toLowerCase().includes('dcm4chee')) {
        consoleUtils.info(`  Direct updating patient ${pid} from '${iss}' -> ${CANON}`);
        await doDirectUpdate(pid, iss, payload);
      } else {
        // For non-DCM4CHEE issuers, use the traditional merge approach
        consoleUtils.info(`  Merging variant '${iss || '<empty>'}' -> ${CANON}`);
        await doMerge(pid, iss, payload);
      }
    }
  }

  consoleUtils.success(`Done. Log: ${OPS_CSV}`);
  if (DRY_RUN) {
    consoleUtils.warn('Ini adalah DRY RUN. Tidak ada data yang diubah.');
    consoleUtils.info(`Cek operasinya di: ${OPS_CSV}`);
  }

  // Final cleanup: Process any remaining DCM4CHEE records with .null issuers
  consoleUtils.info('Starting final cleanup for any remaining DCM4CHEE .null issuers...');
  await finalCleanupDcm4cheeNullIssuers();
}


module.exports = runPatientMerge;
