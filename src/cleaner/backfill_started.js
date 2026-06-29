const {
    SUPABASE_URL,
    SUPABASE_KEY,
    DCM_QIDO,
    KC_TOKEN_URL,
    KC_CLIENT_ID,
    KC_CLIENT_SECRET,
    KC_USERNAME,
    KC_PASSWORD
} = process.env;

const DRY_RUN = (process.env.DRY_RUN || 'false').toLowerCase() === 'true';

const PAGE_SIZE = parseInt(
    process.env.BACKFILL_PAGE_SIZE || process.env.RECOUNT_PAGE_SIZE || '1000',
    10
);

const consoleUtils = require('../utils/consoleUtils');
const log = (msg) => consoleUtils.info(`[${new Date().toISOString()}] ${msg}`);

/**
 * Cari Study Instance UID di dalam identifier array.
 */
function findStudyInstanceUID(identifierArray) {
    if (!Array.isArray(identifierArray) || identifierArray.length === 0) {
        return null;
    }
    const studyIdObj = identifierArray.find(
        item => item.system && item.system.endsWith('/study-id')
    );
    return studyIdObj ? studyIdObj.value : null;
}

/**
 * Bangun ISO UTC string dari StudyDate DICOM (YYYYMMDD) dan StudyTime (HHMMSS[.ffffff]).
 * Output: "2026-02-22T10:24:14.000Z"
 * Kembalikan null jika StudyDate tidak valid.
 */
function buildStartedIso(studyDateDa, studyTimeTm) {
    if (!studyDateDa) return null;
    const dateStr = String(studyDateDa).replace(/[^0-9]/g, '');
    if (dateStr.length < 8) return null;

    const yyyy = dateStr.substring(0, 4);
    const mm   = dateStr.substring(4, 6);
    const dd   = dateStr.substring(6, 8);

    const monthIdx = parseInt(mm, 10) - 1;
    const dayInt   = parseInt(dd, 10);
    const yearInt  = parseInt(yyyy, 10);
    if (isNaN(yearInt) || isNaN(monthIdx) || isNaN(dayInt)) return null;
    if (monthIdx < 0 || monthIdx > 11 || dayInt < 1 || dayInt > 31) return null;

    const timeRaw = studyTimeTm ? String(studyTimeTm).replace(/[^0-9]/g, '') : '';
    const timePadded = (timeRaw + '000000').substring(0, 6);
    const hh = timePadded.substring(0, 2);
    const mi = timePadded.substring(2, 4);
    const ss = timePadded.substring(4, 6);

    // Bangun Date di UTC supaya .toISOString() output dengan suffix Z
    const d = new Date(Date.UTC(
        yearInt,
        monthIdx,
        dayInt,
        parseInt(hh, 10),
        parseInt(mi, 10),
        parseInt(ss, 10),
        0
    ));
    if (isNaN(d.getTime())) return null;
    return d.toISOString(); // "YYYY-MM-DDTHH:MM:SS.000Z"
}

/**
 * Normalisasi timestamp existing menjadi ISO UTC untuk perbandingan adil.
 * Mis: "2026-02-22T17:24:14+07:00" -> "2026-02-22T10:24:14.000Z"
 * Jika tidak valid, kembalikan string aslinya.
 */
function normalizeIso(value) {
    if (!value) return '';
    const d = new Date(value);
    if (isNaN(d.getTime())) return String(value);
    return d.toISOString();
}

/**
 * Keycloak token (copy pola recount_instances.js).
 */
async function getKeycloakToken() {
    try {
        const params = new URLSearchParams();
        params.append('grant_type', 'password');
        params.append('client_id', KC_CLIENT_ID);
        params.append('username', KC_USERNAME);
        params.append('password', KC_PASSWORD);
        params.append('scope', 'openid');
        params.append('client_secret', KC_CLIENT_SECRET);

        const response = await fetch(KC_TOKEN_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: params
        });

        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(`Gagal login Keycloak: ${response.statusText} - ${errorText}`);
        }
        const data = await response.json();
        return data.access_token;
    } catch (error) {
        log(`❌ ERROR getKeycloakToken: ${error.message}`);
        return null;
    }
}

/**
 * Ambil satu page imagingStudy dari Supabase.
 */
async function getSupabaseStudiesPage(offset, limit) {
    const url = `${SUPABASE_URL}/rest/v1/imagingStudy?select=id,started,identifier`;

    const response = await fetch(url, {
        headers: {
            'apikey': SUPABASE_KEY,
            'Authorization': `Bearer ${SUPABASE_KEY}`,
            'Accept': 'application/json',
            'Range': `${offset}-${offset + limit - 1}`,
            'Prefer': 'count=exact'
        }
    });

    if (!response.ok) {
        throw new Error(`Gagal mengambil data Supabase: ${response.statusText}`);
    }

    const contentRange = response.headers.get('content-range');
    let total = null;
    let hasMore = false;

    if (contentRange) {
        const parts = contentRange.split('/');
        if (parts.length === 2) {
            total = parseInt(parts[1]);
            hasMore = offset + limit < total;
        }
    }

    const data = await response.json();
    if (!contentRange && Array.isArray(data) && data.length === limit) {
        hasMore = true;
    }

    return { data, total, hasMore };
}

async function getAllSupabaseStudies() {
    let allStudies = [];
    let offset = 0;
    let totalProcessed = 0;

    while (true) {
        log(`Mengambil data studi (offset: ${offset}, limit: ${PAGE_SIZE})...`);
        const result = await getSupabaseStudiesPage(offset, PAGE_SIZE);

        if (!Array.isArray(result.data) || result.data.length === 0) {
            break;
        }

        allStudies = allStudies.concat(result.data);
        totalProcessed += result.data.length;

        log(`Berhasil mengambil ${result.data.length} studi (total: ${totalProcessed}${result.total ? `/${result.total}` : ''})`);

        if (result.data.length < PAGE_SIZE) {
            log(`Last page detected (got ${result.data.length} records, less than ${PAGE_SIZE})`);
            break;
        }
        if (result.total !== null && !result.hasMore) {
            log(`Reached end of data (total: ${result.total})`);
            break;
        }

        offset += PAGE_SIZE;
    }

    return allStudies;
}

/**
 * Query dcm4chee untuk StudyDate (0008,0020) dan StudyTime (0008,0030).
 * Return: { studyDate, studyTime } atau { studyDate: null, studyTime: null } jika tidak ada.
 * Return "error" jika network/parse gagal.
 */
async function getDcmStudyDateTime(studyUid, token) {
    const url = `${DCM_QIDO}/studies` +
        `?StudyInstanceUID=${encodeURIComponent(studyUid)}` +
        `&includedefaults=false&includefield=00080020,00080030`;

    try {
        const response = await fetch(url, {
            headers: {
                'Authorization': `Bearer ${token}`,
                'Accept': 'application/dicom+json'
            }
        });

        if (!response.ok) {
            log(`  [INFO] dcm4chee merespons ${response.status} untuk UID ${studyUid}.`);
            return { studyDate: null, studyTime: null };
        }

        const responseText = await response.text();
        if (!responseText || responseText.trim() === '') {
            log(`  [INFO] dcm4chee mengembalikan respons kosong untuk UID ${studyUid}.`);
            return { studyDate: null, studyTime: null };
        }

        let data;
        try {
            data = JSON.parse(responseText);
        } catch (jsonError) {
            log(`  [ERROR] Gagal parse JSON dari dcm4chee untuk ${studyUid}: ${jsonError.message}`);
            return 'error';
        }

        const studyDate = data?.[0]?.['00080020']?.Value?.[0] || null;
        const studyTime = data?.[0]?.['00080030']?.Value?.[0] || null;
        return { studyDate, studyTime };
    } catch (error) {
        log(`  [ERROR] Gagal fetch (network) untuk ${studyUid}: ${error.message}`);
        return 'error';
    }
}

async function updateSupabaseStarted(uidPk, newIso) {
    const url = `${SUPABASE_URL}/rest/v1/imagingStudy?id=eq.${encodeURIComponent(uidPk)}`;

    const response = await fetch(url, {
        method: 'PATCH',
        headers: {
            'apikey': SUPABASE_KEY,
            'Authorization': `Bearer ${SUPABASE_KEY}`,
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal'
        },
        body: JSON.stringify({ started: newIso })
    });

    return response.status;
}

async function runBackfillStarted() {
    if (DRY_RUN) {
        consoleUtils.title('BACKFILL ImagingStudy.started — MODE DRY RUN');
        consoleUtils.warn('TIDAK ADA DATA YANG AKAN DIUBAH');
    } else {
        consoleUtils.title('BACKFILL ImagingStudy.started — MODE EKSEKUSI');
        consoleUtils.warn('PERINGATAN! DATA AKAN DIUBAH!');
    }

    log('Mendapatkan Keycloak token...');
    const token = await getKeycloakToken();
    if (!token) {
        log('Gagal mendapatkan token, skrip berhenti.');
        return;
    }
    consoleUtils.success('Token dcm4chee didapatkan.');

    log(`Mengambil daftar studi dari Supabase (page size: ${PAGE_SIZE})...`);
    let studies;
    try {
        studies = await getAllSupabaseStudies();
    } catch (error) {
        log(`${error.message}. Cek SUPABASE_URL dan SUPABASE_KEY.`);
        return;
    }

    const countTotal = studies.length;
    let countMismatch = 0;
    let countUpdated = 0;
    let countAlreadyOk = 0;
    let countError = 0;
    let countNoDicomDate = 0;

    consoleUtils.info(`Ditemukan ${countTotal} studi. Memulai backfill started...`);

    for (let i = 0; i < studies.length; i++) {
        const study = studies[i];
        const uidPk = study.id;
        const existingStarted = study.started || '';

        const dcmQueryUid = findStudyInstanceUID(study.identifier);
        if (!dcmQueryUid) {
            log(`[SKIP] Gagal menemukan Study UID di identifier untuk PK ${uidPk}.`);
            countError++;
            continue;
        }

        consoleUtils.status(`(${i + 1}/${countTotal}) Cek PK: ${uidPk}`);
        log(`Querying dcm4chee with Study UID: ${dcmQueryUid}`);

        const dcm = await getDcmStudyDateTime(dcmQueryUid, token);
        if (dcm === 'error') {
            log('[SKIP] Gagal mengambil StudyDate/Time dari dcm4chee.');
            countError++;
            continue;
        }

        const { studyDate, studyTime } = dcm;
        if (!studyDate) {
            log(`[SKIP] StudyDate (0008,0020) kosong di dcm4chee untuk ${dcmQueryUid}.`);
            countNoDicomDate++;
            continue;
        }

        const newIso = buildStartedIso(studyDate, studyTime);
        if (!newIso) {
            log(`[SKIP] StudyDate/Time tidak dapat diparse: date=${studyDate}, time=${studyTime}`);
            countError++;
            continue;
        }

        const normalizedExisting = normalizeIso(existingStarted);
        log(`Supabase started: ${existingStarted || '(empty)'} (norm: ${normalizedExisting || '(empty)'})`);
        log(`DICOM started:    ${newIso}`);

        if (normalizedExisting === newIso) {
            consoleUtils.success('started sudah sesuai DICOM.');
            countAlreadyOk++;
            continue;
        }

        consoleUtils.warn(`Perlu update. Lama=${existingStarted || '(empty)'} -> Baru=${newIso}`);
        countMismatch++;

        if (DRY_RUN) {
            log('[DRY-RUN] Melewatkan update.');
        } else {
            log('[EXECUTE] Mengirim PATCH ke Supabase...');
            try {
                const httpStatus = await updateSupabaseStarted(uidPk, newIso);
                if (httpStatus === 200 || httpStatus === 204) {
                    consoleUtils.success(`Update berhasil (HTTP ${httpStatus}).`);
                    countUpdated++;
                } else {
                    log(`[ERROR] Update GAGAL (HTTP ${httpStatus}).`);
                    countError++;
                }
            } catch (err) {
                log(`[ERROR] PATCH exception: ${err.message}`);
                countError++;
            }
        }
    }

    consoleUtils.title('PROSES BACKFILL started SELESAI');
    consoleUtils.info(`Total Studi dicek      : ${countTotal}`);
    consoleUtils.info(`Sudah sesuai           : ${countAlreadyOk}`);
    consoleUtils.info(`Mismatch (perlu update): ${countMismatch}`);
    consoleUtils.info(`Berhasil di-update     : ${countUpdated}`);
    consoleUtils.info(`Skip (no DICOM date)   : ${countNoDicomDate}`);
    consoleUtils.info(`Gagal diproses         : ${countError}`);
    if (DRY_RUN && countMismatch > 0) {
        consoleUtils.warn('Ini adalah DRY RUN. Tidak ada data yang diubah.');
        consoleUtils.info('Untuk eksekusi, set DRY_RUN=false di file run.sh');
    }
}

module.exports = runBackfillStarted;
