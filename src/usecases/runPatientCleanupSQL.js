const fs = require('fs');
const path = require('path');
const { Client } = require('pg');
const consoleUtils = require('../utils/consoleUtils');

const PROGRESS_BAR_LEN = 24;

function drawProgressBar(pct, batch, processed, total, isDryRun) {
  const filled = Math.round((PROGRESS_BAR_LEN * Math.min(100, pct)) / 100);
  const bar = '[' + '='.repeat(filled) + '>'.repeat(filled < PROGRESS_BAR_LEN ? 1 : 0) + ' '.repeat(PROGRESS_BAR_LEN - filled - (filled < PROGRESS_BAR_LEN ? 1 : 0)) + ']';
  const pctStr = `${Number(pct).toFixed(1)}%`;
  const detail = total != null ? ` batch ${batch} (${processed}/${total} pat_id)` : ` batch ${batch}`;
  const suffix = isDryRun ? ' [DRY RUN]' : '';
  process.stdout.write(`\r  ${bar} ${pctStr}${detail}${suffix}    `);
}

/**
 * Menjalankan skrip SQL pembersihan pasien dari file.
 * Progress ditampilkan via NOTIFY dari procedure (koneksi kedua LISTEN).
 * @param {DBAdapter} db - Instance DBAdapter yang sudah terhubung.
 */
async function runPatientCleanupSQL(db) {
  const DRY_RUN = (process.env.DRY_RUN || 'false').toLowerCase() === 'true';

  let sqlFileName;
  if (DRY_RUN) {
    sqlFileName = 'patient_merge_cleanup_DRYRUN.sql';
    consoleUtils.info("Memilih skrip SQL DRY RUN (ROLLBACK)...");
  } else {
    sqlFileName = 'patient_merge_cleanup.sql';
    consoleUtils.info("Memilih skrip SQL LIVE (COMMIT)...");
  }

  const sqlFilePath = path.join(__dirname, '..', 'cleaner', 'sql', sqlFileName);

  let sqlScript;
  try {
    sqlScript = fs.readFileSync(sqlFilePath, 'utf8');
    consoleUtils.success(`Berhasil memuat skrip SQL dari: ${sqlFileName}`);
  } catch (err) {
    consoleUtils.error(`GAGAL memuat file SQL: ${sqlFilePath}`, err.message);
    throw new Error(`File SQL tidak ditemukan: ${sqlFileName}`);
  }

  if (!sqlScript) {
    throw new Error("Skrip SQL kosong atau tidak berhasil dibaca.");
  }

  consoleUtils.info("Mulai eksekusi skrip SQL di Supabase...");
  const startTime = Date.now();

  let listenClient;
  try {
    listenClient = new Client(db.getConfig());
    await listenClient.connect();
    await listenClient.query('LISTEN cleanup_progress');
  } catch (listenErr) {
    consoleUtils.warn("Tidak bisa memulai listener progress, lanjut tanpa progress bar: " + listenErr.message);
  }

  const progressHandler = (msg) => {
    if (msg.channel !== 'cleanup_progress' || !msg.payload) return;
    try {
      const data = JSON.parse(msg.payload);
      const pct = data.pct != null ? data.pct : 0;
      const batch = data.batch != null ? data.batch : 0;
      const processed = data.processed != null ? data.processed : 0;
      const total = data.total != null ? data.total : null;
      const isDryRun = data.dry_run === true;
      if (data.done) {
        process.stdout.write("\r  " + " ".repeat(60) + "\r");
        return;
      }
      drawProgressBar(pct, batch, processed, total, isDryRun);
    } catch (_) {}
  };

  let fallbackInterval;
  if (listenClient) {
    listenClient.on('notification', progressHandler);
  } else {
    fallbackInterval = setInterval(() => {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
      consoleUtils.info(`[INFO] SQL masih berjalan... (${elapsed}s)`);
    }, 10000);
  }

  try {
    // Jalankan CREATE PROCEDURE dan CALL secara terpisah agar COMMIT di dalam procedure tidak bentrok (invalid transaction termination)
    const callStart = sqlScript.indexOf('CALL public.patient_merge_cleanup_batched');
    if (callStart !== -1) {
      const createPart = sqlScript.substring(0, callStart).trim();
      const callPart = sqlScript.substring(callStart).trim();
      if (createPart) {
        await db.query(createPart);
        consoleUtils.info("Procedure didefinisikan, menjalankan cleanup...");
      }
      await db.query(callPart);
    } else {
      await db.query(sqlScript);
    }

    if (listenClient) {
      process.stdout.write("\r  " + " ".repeat(60) + "\r");
    }
    if (fallbackInterval) clearInterval(fallbackInterval);

    const duration = ((Date.now() - startTime) / 1000).toFixed(2);

    if (DRY_RUN) {
      consoleUtils.success(`[DRY RUN] Skrip SQL selesai dalam ${duration}s dan di-ROLLBACK.`);
    } else {
      consoleUtils.success(`[LIVE] Skrip SQL selesai dalam ${duration}s dan di-COMMIT.`);
    }
  } catch (err) {
    if (listenClient) {
      process.stdout.write("\r  " + " ".repeat(60) + "\r");
    }
    if (fallbackInterval) clearInterval(fallbackInterval);
    const duration = ((Date.now() - startTime) / 1000).toFixed(2);
    consoleUtils.error(`GAGAL saat eksekusi SQL setelah ${duration}s: ${err.message}`);
    consoleUtils.error("Detail Error:", err);
    throw new Error(`Gagal menjalankan skrip SQL: ${err.message}`);
  } finally {
    if (fallbackInterval) clearInterval(fallbackInterval);
    if (listenClient) {
      listenClient.removeAllListeners('notification');
      await listenClient.end().catch(() => {});
    }
  }
}

module.exports = runPatientCleanupSQL;
