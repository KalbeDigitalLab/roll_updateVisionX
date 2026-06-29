const fs = require("fs");
const path = require("path");
const { URLSearchParams } = require("url");
const consoleUtils = require("../utils/consoleUtils");

// =================== CONFIG ===================
const FHIR_BASE = process.env.FHIR_BASE;
const DCM_BASE = process.env.DCM_BASE;
const DCM_AET = process.env.DCM_AET;
const DCM_QIDO = process.env.DCM_QIDO;
const DCM_MWL = process.env.DCM_MWL;
const TOKEN_SCOPE = process.env.TOKEN_SCOPE;

const KC_TOKEN_URL = process.env.KC_TOKEN_URL;
const KC_CLIENT_ID = process.env.KC_CLIENT_ID;
const KC_CLIENT_SECRET = process.env.KC_CLIENT_SECRET;
const KC_USERNAME = process.env.KC_USERNAME;
const KC_PASSWORD = process.env.KC_PASSWORD;

// System identifiers
const ACC_SYSTEM = process.env.ACC_SYSTEM;
const SPS_SYSTEM = process.env.SPS_SYSTEM;
const STUDYID_SYSTEM = process.env.STUDYID_SYSTEM;
// Options
const VERBOSE = process.env.VERBOSE;
const DRY_RUN = (process.env.DRY_RUN || 'false').toLowerCase() === 'true';
const CURL_INSECURE = process.env.CURL_INSECURE;

// Logging
const ts = new Date()
  .toISOString()
  .replace(/[-:.]/g, "")
  .replace("T", "_")
  .substring(0, 15);
const LOG_DIR = path.join(__dirname, `auto_sync_logs_${ts}`);
const LOG_FILE = path.join(LOG_DIR, `auto_sync_${ts}.log`);
const AUDIT_FILE = path.join(LOG_DIR, "auto_sync_ops.csv");
const DEBUG_DIR = path.join(LOG_DIR, "debug");

// Setup TLS if insecure
if (CURL_INSECURE) {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
}

// =================== HELPERS ===================

/**
 * Logging function
 */
function log(msg) {
  const timestamp = new Date().toISOString();
  const logMsg = `[${timestamp}] ${msg}`;
  consoleUtils.info(logMsg);
  fs.appendFileSync(LOG_FILE, logMsg + "\n");
}

/**
 * Verbose logging function (only logs if VERBOSE is enabled)
 */
function verboseLog(msg) {
  if (VERBOSE) {
    log(`[VERBOSE] ${msg}`);
  }
}

/**
 * Save debug content to file
 */
function debugSave(filename, content) {
  try {
    const filepath = path.join(DEBUG_DIR, filename);
    fs.writeFileSync(
      filepath,
      typeof content === "string" ? content : JSON.stringify(content, null, 2),
    );
  } catch (err) {
    // Ignore debug save errors
  }
}

/**
 * Audit logging
 */
function audit(unscheduled, scheduled, step, httpCode, result, info) {
  const timestamp = new Date().toISOString();
  const line = `${timestamp},${unscheduled},${scheduled},${step},${httpCode},${result},${info}\n`;
  fs.appendFileSync(AUDIT_FILE, line);
}

/**
 * URL encode helper
 */
function enc(str) {
  return encodeURIComponent(str);
}

/**
 * Trim whitespace
 */
function trim(str) {
  return str ? str.trim() : "";
}

// =================== AUTH ===================

/**
 * Get Keycloak access token
 */
async function getKeycloakToken() {
  try {
    log("Getting Keycloak token...");
    verboseLog(`Keycloak token URL: ${KC_TOKEN_URL}`);
    const params = new URLSearchParams();
    params.append("grant_type", "password");
    params.append("client_id", KC_CLIENT_ID);
    params.append("client_secret", KC_CLIENT_SECRET);
    params.append("username", KC_USERNAME);
    params.append("password", KC_PASSWORD);
    params.append("scope", TOKEN_SCOPE);

    const response = await fetch(KC_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: params,
    });

    verboseLog(
      `Keycloak response: HTTP ${response.status} ${response.statusText}`,
    );

    if (!response.ok) {
      const errorText = await response.text();
      verboseLog(`Keycloak error response: ${errorText}`);
      throw new Error(
        `Failed to get Keycloak token: ${response.statusText} - ${errorText}`,
      );
    }

    const data = await response.json();
    const token = data.access_token;

    if (!token || token === "null") {
      throw new Error("Access token is null or empty");
    }

    log("Token obtained successfully");
    verboseLog(`Token preview: ${token.substring(0, 20)}...`);
    return token;
  } catch (error) {
    log(`ERROR: Cannot get Keycloak token: ${error.message}`);
    verboseLog(`Keycloak token error details: ${error.stack}`);
    throw error;
  }
}

// =================== QIDO OPERATIONS ===================

/**
 * Query studies by accession number (not filtering by patient)
 */
async function qidoUidByAccession(accession, token) {
  const url = `${DCM_QIDO}/studies?00080050=${enc(
    accession,
  )}&includedefaults=false&includefield=0020000D&includefield=00100020&includefield=00080050`;
  verboseLog(`QIDO query by accession: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/dicom+json",
      },
    });

    verboseLog(`QIDO response: HTTP ${response.status} ${response.statusText}`);

    if (!response.ok) {
      const errorText = await response.text();
      debugSave(
        `qido_${accession}.json`,
        `HTTP ${response.status}: ${errorText}`,
      );
      verboseLog(`QIDO query failed: ${errorText}`);
      return [];
    }

    const data = await response.json();
    debugSave(`qido_${accession}.json`, JSON.stringify(data, null, 2));
    verboseLog(
      `QIDO query result: ${
        Array.isArray(data) ? data.length : 0
      } studies found`,
    );

    return Array.isArray(data) ? data : [];
  } catch (error) {
    log(`  ERROR QIDO query for ${accession}: ${error.message}`);
    verboseLog(`QIDO query error details: ${error.stack}`);
    return [];
  }
}

/**
 * Update study metadata
 */
async function updateStudyMetadata(
  studyUid,
  accession,
  studyDesc,
  examDate,
  examTime,
  refDoc,
  clinical,
  patientId,
  token,
) {
  const payload = {
    "0020000D": { vr: "UI", Value: [studyUid] },
    "00100020": { vr: "LO", Value: [patientId] },
    "00080050": { vr: "SH", Value: [accession] },
  };

  if (studyDesc) {
    payload["00081030"] = { vr: "LO", Value: [studyDesc] };
  }
  if (examDate) {
    payload["00080020"] = { vr: "DA", Value: [examDate] };
  }
  if (examTime) {
    payload["00080030"] = { vr: "TM", Value: [examTime] };
  }
  if (refDoc) {
    payload["00080090"] = { vr: "PN", Value: [refDoc] };
  }
  if (clinical) {
    payload["001021B0"] = { vr: "LT", Value: [clinical] };
  }

  const url = `${DCM_QIDO}/studies/${enc(studyUid)}`;
  verboseLog(`Updating study metadata: ${url}`);
  debugSave(
    `update_payload_${studyUid}.json`,
    JSON.stringify(payload, null, 2),
  );

  if (DRY_RUN) {
    log(`  [DRY-RUN] Would PUT ${url}`);
    return "200";
  }

  try {
    const response = await fetch(url, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/dicom+json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload),
    });

    const code = response.status.toString();
    verboseLog(
      `Study metadata update response: HTTP ${code} ${response.statusText}`,
    );

    return code;
  } catch (error) {
    verboseLog(`Study metadata update error: ${error.stack}`);
    return "error";
  }
}

/**
 * Move study to different patient
 */
async function moveStudyToPatient(
  studyUid,
  patientId,
  patientName,
  patientSex,
  patientBirthDate,
  token,
) {
  let query = `PatientID=${enc(patientId)}&PatientName=${enc(
    patientName,
  )}&PatientSex=${enc(patientSex)}`;
  if (patientBirthDate) {
    query += `&PatientBirthDate=${enc(patientBirthDate)}`;
  }

  const url = `${DCM_QIDO}/studies/${enc(studyUid)}/patient?${query}`;
  verboseLog(`Moving study to patient: ${url}`);

  if (DRY_RUN) {
    log(`  [DRY-RUN] Would POST ${url}`);
    return "200";
  }

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
      },
    });

    const code = response.status.toString();
    verboseLog(`Move study response: HTTP ${code} ${response.statusText}`);

    return code;
  } catch (error) {
    verboseLog(`Move study error: ${error.stack}`);
    return "error";
  }
}

// =================== MWL OPERATIONS ===================

/**
 * Check if accession exists in MWL
 */
async function checkMwlExists(accession, token) {
  const url = `${DCM_MWL}/mwlitems?00080050=${enc(
    accession,
  )}&includedefaults=false`;
  verboseLog(`Checking MWL: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/dicom+json",
      },
    });

    verboseLog(
      `MWL check response: HTTP ${response.status} ${response.statusText}`,
    );

    if (!response.ok) {
      const errorText = await response.text();
      debugSave(
        `mwl_${accession}.json`,
        `HTTP ${response.status}: ${errorText}`,
      );
      verboseLog(`MWL check failed: ${errorText}`);
      return "not_exists";
    }

    const data = await response.json();
    debugSave(`mwl_${accession}.json`, JSON.stringify(data, null, 2));
    verboseLog(
      `MWL check result: ${Array.isArray(data) ? data.length : 0} items found`,
    );

    if (Array.isArray(data) && data.length > 0) {
      return "exists";
    }

    return "not_exists";
  } catch (error) {
    log(`  ERROR checking MWL for ${accession}: ${error.message}`);
    verboseLog(`MWL check error details: ${error.stack}`);
    return "not_exists";
  }
}

/**
 * Complete MWL item (set status to COMPLETED)
 */
async function mwlComplete(study225, sps, token) {
  if (!study225 || !sps) {
    return "skip";
  }

  const url = `${DCM_MWL}/mwlitems/${enc(study225)}/${enc(
    sps,
  )}/status/COMPLETED`;
  verboseLog(`Completing MWL: ${url}`);

  if (DRY_RUN) {
    log(`  [DRY-RUN] Would POST ${url}`);
    return "200";
  }

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
      },
    });

    const code = response.status.toString();
    verboseLog(`MWL complete response: HTTP ${code} ${response.statusText}`);

    return code;
  } catch (error) {
    verboseLog(`MWL complete error: ${error.stack}`);
    return "error";
  }
}

// =================== FHIR OPERATIONS ===================

/**
 * Fetch ServiceRequest bundle from FHIR
 */
async function fetchServiceRequestBundle(token) {
  const url = `${FHIR_BASE}/ServiceRequest`;
  verboseLog(`Fetching ServiceRequest bundle: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/fhir+json",
      },
    });

    verboseLog(
      `ServiceRequest bundle response: HTTP ${response.status} ${response.statusText}`,
    );

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const data = await response.json();
    debugSave("sr_bundle.json", JSON.stringify(data, null, 2));
    verboseLog(
      `ServiceRequest bundle: ${data.entry?.length || 0} entries found`,
    );
    return data;
  } catch (error) {
    log(`ERROR fetching ServiceRequest bundle: ${error.message}`);
    verboseLog(`ServiceRequest bundle error details: ${error.stack}`);
    throw error;
  }
}

/**
 * Fetch ServiceRequest by ID
 */
async function fetchServiceRequestById(serviceRequestId, token) {
  const url = `${FHIR_BASE}/ServiceRequest/${enc(serviceRequestId)}`;
  verboseLog(`  Fetching ServiceRequest: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/fhir+json",
      },
    });

    verboseLog(
      `  ServiceRequest response: HTTP ${response.status} ${response.statusText}`,
    );

    if (!response.ok) {
      return null;
    }

    const data = await response.json();
    debugSave(`sr_${serviceRequestId}.json`, JSON.stringify(data, null, 2));
    return data;
  } catch (error) {
    log(
      `  ERROR fetching ServiceRequest ${serviceRequestId}: ${error.message}`,
    );
    verboseLog(`  ServiceRequest fetch error details: ${error.stack}`);
    return null;
  }
}

/**
 * Fetch Patient by ID
 */
async function fetchPatient(patientId, token) {
  const url = `${FHIR_BASE}/Patient/${enc(patientId)}`;
  verboseLog(`  Fetching Patient: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/fhir+json",
      },
    });

    verboseLog(
      `  Patient response: HTTP ${response.status} ${response.statusText}`,
    );

    if (!response.ok) {
      return null;
    }

    const data = await response.json();
    debugSave(`patient_${patientId}.json`, JSON.stringify(data, null, 2));
    return data;
  } catch (error) {
    log(`  ERROR fetching Patient ${patientId}: ${error.message}`);
    verboseLog(`  Patient fetch error details: ${error.stack}`);
    return null;
  }
}

/**
 * Search Patient by identifier (MRN)
 */
async function searchPatientByIdentifier(mrn, token) {
  const url = `${FHIR_BASE}/Patient?identifier=${enc(mrn)}`;
  verboseLog(`  Searching Patient by MRN: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/fhir+json",
      },
    });

    if (!response.ok) {
      return null;
    }

    const data = await response.json();
    debugSave(`patient_search_${mrn}.json`, JSON.stringify(data, null, 2));

    if (data.entry && data.entry.length > 0 && data.entry[0].resource) {
      return data.entry[0].resource.id;
    }

    return null;
  } catch (error) {
    verboseLog(`  Patient search error: ${error.stack}`);
    return null;
  }
}

/**
 * Delete FHIR resource with ETag handling
 */
async function fhirDeleteWithEtag(resourceUrl, token) {
  verboseLog(`  Deleting FHIR resource: ${resourceUrl}`);

  if (DRY_RUN) {
    log(`  [DRY-RUN] Would DELETE ${resourceUrl}`);
    return "200";
  }

  try {
    // First attempt: DELETE without ETag
    const response = await fetch(resourceUrl, {
      method: "DELETE",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/fhir+json",
      },
    });

    const code = response.status.toString();

    // Success codes
    if (["200", "204", "404"].includes(code)) {
      return code;
    }

    // If 409 Conflict, try with ETag
    if (code === "409") {
      verboseLog(`  Conflict (409), trying with ETag...`);

      // Get current resource to get ETag
      const getResponse = await fetch(resourceUrl, {
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/fhir+json",
        },
      });

      const etag = getResponse.headers.get("etag");
      if (etag) {
        const etagValue = etag.replace(/^W\//, "").replace(/"/g, "");
        verboseLog(`  Found ETag: ${etagValue}`);

        const retryResponse = await fetch(resourceUrl, {
          method: "DELETE",
          headers: {
            Authorization: `Bearer ${token}`,
            Accept: "application/fhir+json",
            "If-Match": etagValue,
          },
        });

        return retryResponse.status.toString();
      }
    }

    return code;
  } catch (error) {
    verboseLog(`  FHIR delete error: ${error.stack}`);
    return "error";
  }
}

/**
 * Search and delete resources by based-on reference
 */
async function deleteResourcesByBasedOn(basedOnRef, resourceType, token) {
  const srRefEnc = enc(basedOnRef);
  const url = `${FHIR_BASE}/${resourceType}?based-on=${srRefEnc}`;
  verboseLog(`  Searching ${resourceType} by based-on: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/fhir+json",
      },
    });

    if (!response.ok) {
      return;
    }

    const data = await response.json();
    if (data.entry && Array.isArray(data.entry)) {
      for (const entry of data.entry) {
        if (entry.resource && entry.resource.id) {
          const resourceUrl = `${FHIR_BASE}/${resourceType}/${enc(
            entry.resource.id,
          )}`;
          await fhirDeleteWithEtag(resourceUrl, token);
        }
      }
    }
  } catch (error) {
    verboseLog(`  Error deleting ${resourceType}: ${error.stack}`);
  }
}

/**
 * Get all accession numbers from ServiceRequest bundle
 */
function extractAccessionNumbers(srBundle) {
  const allIds = new Set();

  if (srBundle.entry && Array.isArray(srBundle.entry)) {
    for (const entry of srBundle.entry) {
      const resource = entry.resource;
      if (!resource || resource.resourceType !== "ServiceRequest") continue;

      // Get accession from identifier (matching bash: select(.system==$sys) | .value)
      if (resource.identifier && Array.isArray(resource.identifier)) {
        for (const ident of resource.identifier) {
          if (
            ident.system === ACC_SYSTEM &&
            ident.value &&
            typeof ident.value === "string"
          ) {
            allIds.add(ident.value);
          }
        }
      }

      // Also add resource ID (matching bash: $r.id)
      if (resource.id && typeof resource.id === "string") {
        allIds.add(resource.id);
      }
    }
  }

  // Return sorted array (matching bash: sort -u)
  return Array.from(allIds).sort();
}

/**
 * Get unscheduled accessions (ending with -unscheduled)
 */
function getUnscheduledAccessions(allIds) {
  return allIds.filter((id) => id.endsWith("-unscheduled"));
}

/**
 * Fetch Procedure by ID
 */
async function fetchProcedure(procedureId, token) {
  const url = `${FHIR_BASE}/Procedure/${enc(procedureId)}`;
  verboseLog(`  Fetching Procedure: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/fhir+json",
      },
    });

    verboseLog(
      `  Procedure response: HTTP ${response.status} ${response.statusText}`,
    );

    if (!response.ok) {
      return null;
    }

    const data = await response.json();
    debugSave(`procedure_${procedureId}.json`, JSON.stringify(data, null, 2));
    verboseLog(`  Procedure fetched: ${data.resourceType} ${data.id}`);
    return data;
  } catch (error) {
    log(`  ERROR fetching Procedure ${procedureId}: ${error.message}`);
    verboseLog(`  Procedure fetch error details: ${error.stack}`);
    return null;
  }
}

/**
 * Extract SPS ID and Study225 from Procedure
 */
function extractMwlIdentifiers(procedure) {
  if (!procedure || procedure.resourceType !== "Procedure") {
    return { spsId: null, study225: null };
  }

  let spsId = null;
  let study225 = null;

  if (procedure.identifier && Array.isArray(procedure.identifier)) {
    for (const ident of procedure.identifier) {
      if (ident.system === SPS_SYSTEM && ident.value) {
        spsId = ident.value;
      }
      if (ident.system === STUDYID_SYSTEM && ident.value) {
        study225 = ident.value;
      }
    }
  }

  return { spsId, study225 };
}

/**
 * Search ImagingStudy by identifier
 */
async function searchImagingStudyByIdentifier(identifier, token) {
  const url = `${FHIR_BASE}/ImagingStudy?identifier=${enc(identifier)}`;
  verboseLog(`  Searching ImagingStudy: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/fhir+json",
      },
    });

    if (!response.ok) {
      return { id: null, resource: null };
    }

    const data = await response.json();
    debugSave(`is_search_${identifier}.json`, JSON.stringify(data, null, 2));

    if (data.entry && data.entry.length > 0 && data.entry[0].resource) {
      return {
        id: data.entry[0].resource.id,
        resource: data.entry[0].resource,
      };
    }

    return { id: null, resource: null };
  } catch (error) {
    verboseLog(`  ImagingStudy search error: ${error.stack}`);
    return { id: null, resource: null };
  }
}

/**
 * Fetch ImagingStudy by ID
 */
async function fetchImagingStudy(imagingStudyId, token) {
  const url = `${FHIR_BASE}/ImagingStudy/${enc(imagingStudyId)}`;
  verboseLog(`  Fetching ImagingStudy: ${url}`);

  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/fhir+json",
      },
    });

    if (!response.ok) {
      return null;
    }

    const data = await response.json();
    debugSave(`is_${imagingStudyId}.json`, JSON.stringify(data, null, 2));
    return data;
  } catch (error) {
    verboseLog(`  ImagingStudy fetch error: ${error.stack}`);
    return null;
  }
}

/**
 * Create or update ImagingStudy
 */
async function putImagingStudy(imagingStudyId, imagingStudyData, token) {
  const url = `${FHIR_BASE}/ImagingStudy/${enc(imagingStudyId)}`;
  verboseLog(`  Creating/Updating ImagingStudy: ${url}`);

  if (DRY_RUN) {
    log(`  [DRY-RUN] Would PUT ${url}`);
    return "200";
  }

  try {
    const response = await fetch(url, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/fhir+json",
        Accept: "application/fhir+json",
      },
      body: JSON.stringify(imagingStudyData),
    });

    const code = response.status.toString();
    verboseLog(
      `  ImagingStudy PUT response: HTTP ${code} ${response.statusText}`,
    );
    return code;
  } catch (error) {
    verboseLog(`  ImagingStudy PUT error: ${error.stack}`);
    return "error";
  }
}

// =================== MAIN LOGIC ===================

/**
 * Main execution function
 */
async function main() {
  // Setup logging directories
  fs.mkdirSync(LOG_DIR, { recursive: true });
  fs.mkdirSync(DEBUG_DIR, { recursive: true });

  // Initialize audit CSV
  fs.writeFileSync(
    AUDIT_FILE,
    "timestamp,unscheduled,scheduled,step,http_code,result,info\n",
  );

  log("=========================================");
  if (DRY_RUN) {
    log("========= DRY RUN MODE =========");
    log("== NO DATA WILL BE CHANGED ==");
  } else {
    log("========= EXECUTION MODE =========");
    log("== WARNING! DATA WILL BE CHANGED! ==");
  }
  log("=========================================");
  log("");

  // 1. Get Keycloak token
  let token;
  try {
    token = await getKeycloakToken();
  } catch (error) {
    log("❌ Failed to get token. Exiting.");
    process.exit(1);
  }

  // 2. Fetch ServiceRequest bundle
  log("Fetching ServiceRequest bundle from FHIR...");
  let srBundle;
  try {
    srBundle = await fetchServiceRequestBundle(token);
  } catch (error) {
    log(`❌ Failed to fetch ServiceRequest bundle: ${error.message}`);
    process.exit(1);
  }

  // 3. Extract accession numbers
  const allIds = extractAccessionNumbers(srBundle);
  const unscheduledIds = getUnscheduledAccessions(allIds);
  const allSet = new Set(allIds);

  log(`Found ${allIds.length} total accessions`);
  log(`Found ${unscheduledIds.length} unscheduled studies:`);
  unscheduledIds.forEach((id) => log(`  - ${id}`));
  log("");

  // 4. Process each unscheduled accession
  let syncCount = 0;
  let skipCount = 0;

  for (const uAcc of unscheduledIds) {
    log("=========================================");
    log(`Processing: ${uAcc}`);

    const base = uAcc.replace(/-unscheduled$/, "");

    // Check if base accession exists in the set
    if (!allSet.has(base)) {
      log(`  Skip: no scheduled pair found`);
      skipCount++;
      continue;
    }

    log(`  ✓ Found scheduled pair: ${base}`);

    // Check if base accession exists in MWL
    const mwlStatus = await checkMwlExists(base, token);
    if (mwlStatus === "exists") {
      log(`  ⏸️  Skip: still in MWL (exam not completed)`);
      skipCount++;
      continue;
    }

    log(`  ✅ Not in MWL - proceeding with sync`);

    // Fetch scheduled SR & patient
    const schedSrJson = await fetchServiceRequestById(base, token);

    if (!schedSrJson || schedSrJson.resourceType !== "ServiceRequest") {
      log(`  ❌ Cannot fetch ServiceRequest`);
      skipCount++;
      continue;
    }

    const patRef = schedSrJson.subject?.reference || "";
    if (!patRef) {
      log(`  ❌ No patient reference`);
      skipCount++;
      continue;
    }

    const patId = patRef.replace("Patient/", "");
    const patJson = await fetchPatient(patId, token);

    if (!patJson) {
      log(`  ❌ Cannot fetch Patient`);
      skipCount++;
      continue;
    }

    // Extract patient demographics
    const mrn = (patJson.identifier?.[0]?.value || patJson.id || "").trim();
    const pname = (
      patJson.name?.[0]?.text ||
      [patJson.name?.[0]?.given?.[0], patJson.name?.[0]?.family]
        .filter(Boolean)
        .join(" ") ||
      ""
    ).trim();
    const birth = (patJson.birthDate || "").trim();
    const sexRaw = (patJson.gender || "O").trim();
    const sex = sexRaw.charAt(0).toUpperCase();
    const birthDcm = birth ? birth.replace(/-/g, "") : "";

    log(`  Patient: MRN=${mrn}, Name=${pname}`);

    // Get study metadata from scheduled SR
    const studyDesc = (schedSrJson.code?.text || "").trim();
    const refDoc = (schedSrJson.requester?.display || "").trim();
    const clinical = (schedSrJson.note?.[0]?.text || "").trim();
    const examDate = (schedSrJson.occurrenceDateTime || "").trim();

    let examDateDcm = "";
    let examTimeDcm = "";
    if (examDate) {
      const datePart = examDate.split("T")[0];
      examDateDcm = datePart.replace(/-/g, "");
      if (examDate.includes("T")) {
        const timePart = examDate.split("T")[1].split(".")[0];
        examTimeDcm = timePart.replace(/:/g, "").substring(0, 6);
      }
    }

    // =================== DICOM STUDY OPERATIONS ===================
    log(`  Searching DICOM for study...`);

    let studySearch = await qidoUidByAccession(base, token);
    debugSave(
      `study_search_${base}.json`,
      JSON.stringify(studySearch, null, 2),
    );

    let srcUid = studySearch[0]?.["0020000D"]?.Value?.[0] || "";
    let currentPatientId = studySearch[0]?.["00100020"]?.Value?.[0] || "";
    let currentAccession = studySearch[0]?.["00080050"]?.Value?.[0] || "";

    if (!srcUid) {
      // Try with unscheduled accession as fallback
      log(`  Trying unscheduled accession...`);
      studySearch = await qidoUidByAccession(uAcc, token);
      debugSave(
        `study_search_${uAcc}.json`,
        JSON.stringify(studySearch, null, 2),
      );

      srcUid = studySearch[0]?.["0020000D"]?.Value?.[0] || "";
      currentPatientId = studySearch[0]?.["00100020"]?.Value?.[0] || "";
      currentAccession = studySearch[0]?.["00080050"]?.Value?.[0] || "";
    }

    if (!srcUid) {
      log(`  ❌ Cannot find StudyInstanceUID in DICOM`);
      skipCount++;
      continue;
    }

    log(`  ✓ Found Study UID: ${srcUid}`);
    log(
      `  Current: Patient=${currentPatientId}, Accession=${currentAccession}`,
    );

    // Check if study needs to be moved to different patient
    if (currentPatientId === mrn) {
      log(`  ✓ Already correct patient, skipping MOVE`);
    } else {
      log(`  → Moving study to patient ${mrn}`);
      const moveCode = await moveStudyToPatient(
        srcUid,
        mrn,
        pname,
        sex,
        birthDcm,
        token,
      );
      log(`  MOVE result: http=${moveCode}`);

      if (!["200", "202", "204", "403"].includes(moveCode)) {
        log(`  ❌ MOVE failed with code ${moveCode}`);
        skipCount++;
        continue;
      }
    }

    // Check if metadata needs updating
    if (currentAccession === base) {
      log(`  ✓ Already correct accession`);
    } else {
      log(`  → Updating metadata`);
      const updateCode = await updateStudyMetadata(
        srcUid,
        base,
        studyDesc,
        examDateDcm,
        examTimeDcm,
        refDoc,
        clinical,
        mrn,
        token,
      );
      log(`  UPDATE result: http=${updateCode}`);
    }

    // =================== FHIR OPERATIONS ===================
    log(`  Processing FHIR resources...`);

    // Get Patient ID from FHIR for ImagingStudy update
    let patientFhirId = await searchPatientByIdentifier(mrn, token);
    if (!patientFhirId) {
      patientFhirId = patId;
      log(`  Using Patient ID from ServiceRequest: ${patientFhirId}`);
    }

    // =================== IMAGING STUDY OPERATIONS ===================
    log(`  Looking for ImagingStudy...`);

    const uAccEnc = enc(uAcc);
    const baseEnc = enc(base);

    // Search for unscheduled ImagingStudy
    const isSearchUnsched = await searchImagingStudyByIdentifier(uAcc, token);
    debugSave(
      `is_search_unsched_${uAcc}.json`,
      JSON.stringify(isSearchUnsched, null, 2),
    );
    const isIdUnsched = isSearchUnsched.id;

    if (isIdUnsched) {
      log(`  ✓ Found ImagingStudy/${isIdUnsched} with unscheduled accession`);

      // Get the full existing ImagingStudy
      const isJson = await fetchImagingStudy(isIdUnsched, token);
      debugSave(
        `is_unsched_full_${isIdUnsched}.json`,
        JSON.stringify(isJson, null, 2),
      );

      if (!isJson) {
        log(`  ❌ Cannot fetch ImagingStudy`);
        skipCount++;
        continue;
      }

      // Prepare new ImagingStudy with base accession as ID
      log(`  → Preparing new ImagingStudy JSON...`);

      const newIs = {
        ...isJson,
        id: base,
        status: "available",
        subject: {
          ...isJson.subject,
          reference: `Patient/${patientFhirId}`,
        },
        identifier: [
          { system: ACC_SYSTEM, value: base },
          ...(isJson.identifier || []).filter(
            (id) => id.system === STUDYID_SYSTEM,
          ),
        ],
      };

      delete newIs.meta;
      delete newIs.text;

      debugSave(`is_new_prepared_${base}.json`, JSON.stringify(newIs, null, 2));

      // Validate JSON
      if (!newIs.resourceType || newIs.resourceType !== "ImagingStudy") {
        log(`  ❌ Failed to prepare valid ImagingStudy JSON`);
        skipCount++;
        continue;
      }

      log(`  ✓ Prepared new ImagingStudy data with ID=${base}`);

      // Delete the unscheduled ImagingStudy FIRST
      log(`  → Deleting old ImagingStudy/${isIdUnsched} (to free Study UID)`);
      const isDelCode = await fhirDeleteWithEtag(
        `${FHIR_BASE}/ImagingStudy/${isIdUnsched}`,
        token,
      );
      log(`  DELETE result: http=${isDelCode}`);

      if (["200", "204"].includes(isDelCode)) {
        // Create new ImagingStudy with base accession as ID
        log(`  → Creating new ImagingStudy/${base}`);
        const isCreateCode = await putImagingStudy(base, newIs, token);
        log(`  CREATE result: http=${isCreateCode}`);

        if (!["200", "201"].includes(isCreateCode)) {
          log(
            `  ❌ Failed to create new ImagingStudy after deletion (code=${isCreateCode})`,
          );
          log(
            `  ⚠️  Data loss: original ImagingStudy deleted but new one not created`,
          );
          log(
            `  ⚠️  Backup stored in: ${DEBUG_DIR}/is_new_prepared_${base}.json`,
          );
        } else {
          log(
            `  ✅ Successfully migrated ImagingStudy from ${isIdUnsched} to ${base}`,
          );
        }
      } else {
        log(
          `  ⚠️  Failed to delete unscheduled ImagingStudy (code=${isDelCode}), skipping creation`,
        );
      }
    } else {
      // No unscheduled ImagingStudy found, check if base already exists
      log(`  No unscheduled ImagingStudy, checking for base...`);
      const isSearchBase = await searchImagingStudyByIdentifier(base, token);
      debugSave(
        `is_search_base_${base}.json`,
        JSON.stringify(isSearchBase, null, 2),
      );
      const isIdBase = isSearchBase.id;

      if (isIdBase) {
        log(`  ✓ Found existing ImagingStudy/${isIdBase}`);
        const isJson = await fetchImagingStudy(isIdBase, token);
        debugSave(`is_base_${isIdBase}.json`, JSON.stringify(isJson, null, 2));

        if (isJson) {
          // Update status to available and patient reference
          const updatedIs = {
            ...isJson,
            status: "available",
            subject: {
              ...isJson.subject,
              reference: `Patient/${patientFhirId}`,
            },
          };

          log(`  → Updating ImagingStudy`);
          const isUpdateCode = await putImagingStudy(
            isIdBase,
            updatedIs,
            token,
          );
          log(`  UPDATE result: http=${isUpdateCode}`);
        }
      } else {
        log(`  ⚠️  No ImagingStudy found (neither unscheduled nor base)`);
      }
    }

    // Try to complete MWL if procedure exists
    log(`  Checking for Procedure...`);
    const procJson = await fetchProcedure(base, token);
    debugSave(`procedure_${base}.json`, JSON.stringify(procJson, null, 2));

    if (procJson && procJson.resourceType === "Procedure") {
      const { spsId, study225 } = extractMwlIdentifiers(procJson);
      if (spsId && study225) {
        log(`  → Completing MWL`);
        const mwlCode = await mwlComplete(study225, spsId, token);
        log(`  MWL result: http=${mwlCode}`);
      }
    }

    // =================== FHIR CLEANUP ===================
    log(`  Cleaning up unscheduled resources...`);

    // Delete unscheduled Procedure
    const procDelCode = await fhirDeleteWithEtag(
      `${FHIR_BASE}/Procedure/${uAcc}`,
      token,
    );
    if (["200", "204", "404"].includes(procDelCode)) {
      log(`  DEL Procedure: http=${procDelCode}`);
    }

    // Delete unscheduled ServiceRequest
    const srDelCode = await fhirDeleteWithEtag(
      `${FHIR_BASE}/ServiceRequest/${uAcc}`,
      token,
    );
    log(`  DEL ServiceRequest: http=${srDelCode}`);

    // Delete linked resources
    const srRef = `ServiceRequest/${uAcc}`;
    await deleteResourcesByBasedOn(srRef, "Observation", token);
    await deleteResourcesByBasedOn(srRef, "DiagnosticReport", token);
    await deleteResourcesByBasedOn(srRef, "Media", token);

    if (["200", "204"].includes(srDelCode)) {
      log(`✅ Successfully synchronized: ${uAcc} → ${base}`);
      audit(uAcc, base, "complete", "200", "success", "synchronized");
      syncCount++;
    } else {
      log(`⚠️  Partial sync (some operations may have failed)`);
      audit(uAcc, base, "partial", srDelCode, "partial", "check_logs");
      syncCount++;
    }

    log("");
  }

  // 5. Summary
  log("=========================================");
  log("SYNCHRONIZATION COMPLETE");
  log(`  Synchronized: ${syncCount} pairs`);
  log(`  Skipped: ${skipCount} pairs`);
  log(`  Audit log: ${AUDIT_FILE}`);
  log(`  Full log: ${LOG_FILE}`);
  log(`  Debug files: ${DEBUG_DIR}`);
  log("=========================================");
}

module.exports = main;

if (require.main === module) {
  main().catch((err) => {
    log(`CRITICAL ERROR: ${err.message}`);
    consoleUtils.error(err.message);
    process.exit(1);
  });
}
