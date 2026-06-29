// src/index.js (SUDAH DIPERBAIKI)

const env = require("./config/env");
const LocalAdapter = require("./adapters/localAdapter");
const DBAdapter = require("./adapters/dbAdapter");
const MirthAdapter = require("./adapters/mirthAdapter");
const deployYamlFiles = require("./usecases/deployYamlFiles");
const updateDatabase = require("./usecases/updateDatabase");
const updateMirthChannel = require("./usecases/updateMirthChannel");
const deployHelper = require("./usecases/deployHelper");
const deployDicomSend = require("./usecases/deployDicomSend");
const increaseSupabaseLimit = require("./usecases/increaseSupabaseLimit");
const deleteFhirByAccession = require("./cleaner/delete_fhir_by_accession");
const AskHelper = require("./utils/readline");
const consoleUtils = require("./utils/consoleUtils");

// Import cleaner
const recountInstances = require("./cleaner/recount_instances");
const backfillStarted = require("./cleaner/backfill_started");
const runPatientMerge = require("./cleaner/multiplePatient.js");
const cleanMwlStatus = require("./cleaner/clean_mwl_status");
const runPatientCleanupSQL = require("./usecases/runPatientCleanupSQL");

async function runRisIpConfiguration(ask) {
  consoleUtils.section("RIS IP Configuration");
  const local = new LocalAdapter(env);
  await local.configureRisIp(
    env.RIS_YAML_FILE,
    env.RIS_YAML_TEMPLATE_FILE,
    ask,
  );
  consoleUtils.success("RIS IP Configuration Completed.");
}

async function runUpdateFlow(ask) {
  let runSsh, runDb, runMirth;
  let runRecount, runBackfillStarted, runMerge, runCleanMwlStatus;
  let runHelper, runDicomSend, runDeleteFhir;
  let runSupabaseLimit, runRisDicomProxyEnv;

  consoleUtils.title("Konfigurasi Proses Deployment");
  runSsh = await ask.ask("Jalankan proses Update Image? (y/n) ");
  runRisDicomProxyEnv = await ask.ask(
    "Tambahkan DICOM_PROXY_URL ke ris.yaml lalu redeploy? (y/n) ",
  );
  runHelper = await ask.ask("Jalankan deploy Kubernetes Helper? (y/n) ");
  runDicomSend = await ask.ask("Jalankan deploy Dicom Send Proxy? (y/n) ");
  runDb = await ask.ask("Jalankan proses Database? (y/n) ");
  runMirth = await ask.ask("Jalankan proses Mirth? (y/n) ");
  runSupabaseLimit = await ask.ask(
    "Jalankan Increase Supabase Storage Limit (values.yaml + helm upgrade)? (y/n) ",
  );

  consoleUtils.section("Tool Cleaner Bila Diperlukan");
  consoleUtils.info(
    "Langkah di bawah biasanya hanya diperlukan untuk instalasi lama, migrasi data, atau perbaikan data produksi.",
  );

  runRecount = await ask.ask(
    "Jalankan proses Cleaner (Recount Instances)? (y/n) ",
  );
  runBackfillStarted = await ask.ask(
    "Jalankan proses Cleaner (Backfill ImagingStudy.started dari DICOM)? (y/n) ",
  );
  runMerge = await ask.ask(
    "Jalankan proses Cleaner (Patient Merge LENGKAP - PACS & DB)? (y/n) ",
  );
  runCleanMwlStatus = await ask.ask("You want to Clean MWL Status? (y/n) ");
  runDeleteFhir = await ask.ask(
    "Jalankan tool Delete FHIR by Accession? (y/n) ",
  );

  consoleUtils.section("Proses Status");
  consoleUtils.info("Menjalankan proses sesuai opsi yang dipilih.");

  if (runSsh.toLowerCase() === "y") {
    consoleUtils.section("Update Image Process (No SSH)");
    const local = new LocalAdapter(env);
    await deployYamlFiles(local, env, ask);
    consoleUtils.success("Update Image Process Completed.");
  } else {
    consoleUtils.skipped("Skipping SSH process.");
  }

  if (runRisDicomProxyEnv.toLowerCase() === "y") {
    consoleUtils.section("RIS DICOM Proxy Env Update");
    const local = new LocalAdapter(env);
    await local.ensureRisDicomProxyEnv(env.RIS_YAML_FILE);
    await local.ensureRisDicomProxyEnv(env.RIS_V1_YAML_FILE);
    local.syncRisTemplateFromYaml(
      env.RIS_YAML_FILE,
      env.RIS_YAML_TEMPLATE_FILE,
    );
    consoleUtils.success("RIS DICOM Proxy Env Update Completed.");
  } else {
    consoleUtils.skipped("Skipping RIS DICOM Proxy Env Update process.");
  }

  if (runHelper.toLowerCase() === "y") {
    consoleUtils.section("Helper Process");
    const local = new LocalAdapter(env);
    await deployHelper(local, env);
    consoleUtils.success("Helper Process Completed.");
  } else {
    consoleUtils.skipped("Skipping Helper process.");
  }

  if (runDicomSend.toLowerCase() === "y") {
    consoleUtils.section("Dicom Send Process");
    const local = new LocalAdapter(env);
    await deployDicomSend(local, env);
    consoleUtils.success("Dicom Send Process Completed.");
  } else {
    consoleUtils.skipped("Skipping Dicom Send process.");
  }

  if (runDb.toLowerCase() === "y") {
    consoleUtils.section("Database Process");
    const db = new DBAdapter(env);
    await db.connect();
    await updateDatabase(db);
    await db.disconnect();
    consoleUtils.success("Database Process Completed.");
  } else {
    consoleUtils.skipped("Skipping Database process.");
  }

  if (runMirth.toLowerCase() === "y") {
    consoleUtils.section("Mirth Process");
    const mirth = new MirthAdapter(env);
    await updateMirthChannel(mirth);
    consoleUtils.success("Mirth Process Completed.");
  } else {
    consoleUtils.skipped("Skipping Mirth process.");
  }

  if (runSupabaseLimit.toLowerCase() === "y") {
    consoleUtils.section("Increase Supabase Storage Limit");
    await increaseSupabaseLimit();
    consoleUtils.success("Supabase Storage Limit Process Completed.");
  } else {
    consoleUtils.skipped("Skipping Supabase Storage Limit process.");
  }

  if (runRecount.toLowerCase() === "y") {
    consoleUtils.section("Cleaner Process (Recount)");
    await recountInstances();
    consoleUtils.success("Cleaner Process (Recount) Completed.");
  } else {
    consoleUtils.skipped("Skipping Cleaner (Recount) process.");
  }

  if (runBackfillStarted.toLowerCase() === "y") {
    consoleUtils.section("Cleaner Process (Backfill started)");
    await backfillStarted();
    consoleUtils.success("Cleaner Process (Backfill started) Completed.");
  } else {
    consoleUtils.skipped("Skipping Cleaner (Backfill started) process.");
  }

  if (runMerge.toLowerCase() === "y") {
    const DRY_RUN = (process.env.DRY_RUN || "false").toLowerCase() === "true";

    consoleUtils.section("1. Cleaner Process (PACS)");

    await runPatientMerge();
    consoleUtils.success("Cleaner Process (PACS) Completed.");

    consoleUtils.section("2. Cleaner Process (Database)");

    if (!DRY_RUN) {
      consoleUtils.warn(
        "DATA DATABASE (SUPABASE) AKAN DIUBAH PERMANEN DALAM 5 DETIK!",
      );
      consoleUtils.warn("Delaying for 5 seconds as safety measure...");
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }

    const db = new DBAdapter(env);
    try {
      consoleUtils.info("Menghubungkan ke database (Supabase)...");
      await db.connect();
      consoleUtils.success("Koneksi database berhasil.");

      await runPatientCleanupSQL(db, DRY_RUN);
    } catch (sqlError) {
      consoleUtils.error(
        `GAGAL saat menjalankan SQL cleanup: ${sqlError.message}`,
      );
    } finally {
      if (db) {
        await db.disconnect();
        consoleUtils.info("Koneksi database (Supabase) ditutup.");
      }
    }
    consoleUtils.success("Cleaner Process (Database) Completed.");
  } else {
    consoleUtils.skipped("Skipping Cleaner (Patient Merge) process.");
  }

  if (runCleanMwlStatus.toLowerCase() === "y") {
    consoleUtils.section("Cleaner Process (MWL Status)");
    await cleanMwlStatus();
    consoleUtils.success("Cleaner Process (MWL Status) Completed.");
  } else {
    consoleUtils.skipped("Skipping Cleaner (MWL Status) process.");
  }

  if (runDeleteFhir.toLowerCase() === "y") {
    consoleUtils.section("Delete FHIR Resource Process");
    await deleteFhirByAccession(ask);
  } else {
    consoleUtils.skipped("Skipping Delete FHIR by Accession process.");
  }

  consoleUtils.success("All requested deployments completed!");
}

async function main() {
  const ask = new AskHelper();

  try {
    consoleUtils.title("VisionX Roll Updater");
    console.log("1. Lakukan Update");
    console.log("2. Konfigurasi IP (Deploy.sh)");
    console.log("3. Exit");

    const menuChoice = (await ask.ask("Pilih menu (1/2/3): ")).trim();

    if (menuChoice === "1") {
      await runUpdateFlow(ask);
    } else if (menuChoice === "2") {
      await runRisIpConfiguration(ask);
    } else if (menuChoice === "3") {
      consoleUtils.info("Keluar dari program.");
    } else {
      consoleUtils.warn(`Pilihan tidak valid: ${menuChoice}`);
    }
  } catch (err) {
    consoleUtils.error(`Error saat eksekusi proses: ${err.message}`);
    process.exit(1);
  } finally {
    ask.close();
  }
}

main().catch((err) => {
  consoleUtils.error(`Fatal error: ${err.message}`);
  process.exit(1);
});
