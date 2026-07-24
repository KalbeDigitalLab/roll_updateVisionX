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
const hardenSupabaseChart = require("./usecases/hardenSupabaseChart");
const triggerAnalyticsMaintenance = require("./usecases/triggerAnalyticsMaintenance");
const deleteFhirByAccession = require("./cleaner/delete_fhir_by_accession");
const AskHelper = require("./utils/readline");
const consoleUtils = require("./utils/consoleUtils");
const inquirer = require("inquirer");

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
  consoleUtils.title("Konfigurasi Proses Deployment");

  // inquirer's checkbox prompt takes over stdin's raw mode; the existing
  // readline-based AskHelper must release stdin first or its later
  // ask.ask() calls stop receiving input once inquirer is done with it.
  ask.close();

  // Wrapped in a loop so picking "back" inside either checkbox screen
  // restarts from the category prompt instead of the only escape being
  // Ctrl+C — previously only the category prompt itself had a way back.
  let category;
  let deploymentTasks = [];
  let cleanerTasks = [];

  while (true) {
    ({ category } = await inquirer.prompt([
      {
        type: "list",
        name: "category",
        message: "Pilih kategori proses:",
        choices: [
          { name: "Deployment", value: "deployment" },
          { name: "Tool Cleaner", value: "cleaner" },
          { name: "Keduanya (Deployment & Tool Cleaner)", value: "both" },
          new inquirer.Separator(),
          { name: "Kembali ke Menu Utama", value: "back" },
        ],
      },
    ]));

    if (category === "back") {
      return new AskHelper();
    }

    deploymentTasks = [];
    cleanerTasks = [];
    let wentBack = false;

    if (category === "deployment" || category === "both") {
      ({ deploymentTasks } = await inquirer.prompt([
        {
          type: "checkbox",
          name: "deploymentTasks",
          message:
            'Pilih proses Deployment (spasi pilih, "a" pilih semua, enter lanjut):',
          pageSize: 20,
          choices: [
            { name: "Update Image", value: "image" },
            { name: "RIS DICOM Proxy Env (ris.yaml)", value: "risDicomProxyEnv" },
            { name: "RIS ReadinessProbe (ris.yaml & ris-v1.yaml)", value: "risReadinessProbe" },
            { name: "dcm4chee Probes (startup/readiness/liveness)", value: "dcm4cheeProbes" },
            { name: "dcm4chee Postgres Env", value: "dcm4cheePostgresEnv" },
            { name: "Deploy Kubernetes Helper", value: "helper" },
            { name: "Deploy Dicom Send Proxy", value: "dicomSend" },
            { name: "Update Database", value: "db" },
            { name: "Update Mirth Channel", value: "mirth" },
            { name: "Increase Supabase Storage Limit", value: "supabaseLimit" },
            { name: "Harden Supabase Chart (Recreate + Probes)", value: "hardenSupabaseChart" },
            { name: "Trigger Analytics Log Cleanup + Vacuum Now", value: "triggerAnalyticsMaintenance" },
            new inquirer.Separator(),
            { name: "← Kembali ke Menu Kategori", value: "back" },
          ],
        },
      ]));

      // Only treat "back" as intentional when it's the sole selection —
      // pressing "a" (toggle all) checks every choice including "back"
      // itself, which must not discard a full select-all as a go-back.
      if (deploymentTasks.length === 1 && deploymentTasks[0] === "back") {
        wentBack = true;
      } else {
        deploymentTasks = deploymentTasks.filter((t) => t !== "back");
      }
    }

    if (!wentBack && (category === "cleaner" || category === "both")) {
      consoleUtils.info(
        "Langkah cleaner biasanya hanya diperlukan untuk instalasi lama, migrasi data, atau perbaikan data produksi.",
      );

      ({ cleanerTasks } = await inquirer.prompt([
        {
          type: "checkbox",
          name: "cleanerTasks",
          message:
            'Pilih Tool Cleaner (spasi pilih, "a" pilih semua, enter konfirmasi):',
          pageSize: 20,
          choices: [
            { name: "Cleaner: Recount Instances", value: "recount" },
            { name: "Cleaner: Backfill ImagingStudy.started dari DICOM", value: "backfillStarted" },
            { name: "Cleaner: Patient Merge LENGKAP (PACS & DB)", value: "patientMerge" },
            { name: "Cleaner: Clean MWL Status", value: "cleanMwlStatus" },
            { name: "Delete FHIR Resource by Accession", value: "deleteFhir" },
            new inquirer.Separator(),
            { name: "← Kembali ke Menu Kategori", value: "back" },
          ],
        },
      ]));

      if (cleanerTasks.length === 1 && cleanerTasks[0] === "back") {
        wentBack = true;
      } else {
        cleanerTasks = cleanerTasks.filter((t) => t !== "back");
      }
    }

    if (wentBack) {
      consoleUtils.info("Kembali ke menu kategori...");
      continue;
    }

    break;
  }

  const selectedTasks = [...deploymentTasks, ...cleanerTasks];

  const runSsh = selectedTasks.includes("image") ? "y" : "n";
  const runRisDicomProxyEnv = selectedTasks.includes("risDicomProxyEnv") ? "y" : "n";
  const runRisReadinessProbe = selectedTasks.includes("risReadinessProbe") ? "y" : "n";
  const runDcm4cheeProbes = selectedTasks.includes("dcm4cheeProbes") ? "y" : "n";
  const runDcm4cheePostgresEnv = selectedTasks.includes("dcm4cheePostgresEnv") ? "y" : "n";
  const runHelper = selectedTasks.includes("helper") ? "y" : "n";
  const runDicomSend = selectedTasks.includes("dicomSend") ? "y" : "n";
  const runDb = selectedTasks.includes("db") ? "y" : "n";
  const runMirth = selectedTasks.includes("mirth") ? "y" : "n";
  const runSupabaseLimit = selectedTasks.includes("supabaseLimit") ? "y" : "n";
  const runHardenSupabaseChart = selectedTasks.includes("hardenSupabaseChart") ? "y" : "n";
  const runTriggerAnalyticsMaintenance = selectedTasks.includes("triggerAnalyticsMaintenance") ? "y" : "n";
  const runRecount = selectedTasks.includes("recount") ? "y" : "n";
  const runBackfillStarted = selectedTasks.includes("backfillStarted") ? "y" : "n";
  const runMerge = selectedTasks.includes("patientMerge") ? "y" : "n";
  const runCleanMwlStatus = selectedTasks.includes("cleanMwlStatus") ? "y" : "n";
  const runDeleteFhir = selectedTasks.includes("deleteFhir") ? "y" : "n";

  consoleUtils.section("Proses Status");
  consoleUtils.info("Menjalankan proses sesuai opsi yang dipilih.");

  // Fresh readline interface for any y/n / text prompts still needed below
  // (image version, deploy confirmations, etc.) now that inquirer is done.
  ask = new AskHelper();

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

  if (runRisReadinessProbe.toLowerCase() === "y") {
    consoleUtils.section("RIS ReadinessProbe Update");
    const local = new LocalAdapter(env);
    await local.ensureRisReadinessProbe(env.RIS_YAML_FILE);
    await local.ensureRisReadinessProbe(env.RIS_V1_YAML_FILE);
    local.syncRisTemplateFromYaml(env.RIS_YAML_FILE, env.RIS_YAML_TEMPLATE_FILE);
    consoleUtils.success("RIS ReadinessProbe Update Completed.");
  } else {
    consoleUtils.skipped("Skipping RIS ReadinessProbe Update process.");
  }

  if (runDcm4cheeProbes.toLowerCase() === "y") {
    consoleUtils.section("Dcm4chee Probes Update");
    const local = new LocalAdapter(env);
    await local.ensureDcm4cheeProbes(env.DCM4CHEE_YAML_FILE);
    consoleUtils.success("Dcm4chee Probes Update Completed.");
  } else {
    consoleUtils.skipped("Skipping Dcm4chee Probes Update process.");
  }

  if (runDcm4cheePostgresEnv.toLowerCase() === "y") {
    consoleUtils.section("Dcm4chee Postgres Env Update");
    const local = new LocalAdapter(env);
    await local.ensureDcm4cheePostgresEnv(env.DCM4CHEE_YAML_FILE);
    consoleUtils.success("Dcm4chee Postgres Env Update Completed.");
  } else {
    consoleUtils.skipped("Skipping Dcm4chee Postgres Env Update process.");
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

  if (runHardenSupabaseChart.toLowerCase() === "y") {
    consoleUtils.section("Harden Supabase Chart (Recreate + Probes)");
    await hardenSupabaseChart(ask);
    consoleUtils.success("Harden Supabase Chart Process Completed.");
  } else {
    consoleUtils.skipped("Skipping Harden Supabase Chart process.");
  }

  if (runTriggerAnalyticsMaintenance.toLowerCase() === "y") {
    consoleUtils.section("Trigger Analytics Log Cleanup + Vacuum Now");
    const db = new DBAdapter(env);
    await db.connect();
    await triggerAnalyticsMaintenance(db);
    await db.disconnect();
    consoleUtils.success("Analytics Log Cleanup + Vacuum Completed.");
  } else {
    consoleUtils.skipped("Skipping Analytics Log Cleanup + Vacuum.");
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
  return ask;
}

async function main() {
  let ask = new AskHelper();

  try {
    let exit = false;
    while (!exit) {
      consoleUtils.title("VisionX Roll Updater");
      console.log("1. Lakukan Update");
      console.log("2. Konfigurasi IP (Deploy.sh)");
      console.log("3. Exit");

      const menuChoice = (await ask.ask("Pilih menu (1/2/3): ")).trim();

      if (menuChoice === "1") {
        ask = await runUpdateFlow(ask);
      } else if (menuChoice === "2") {
        await runRisIpConfiguration(ask);
      } else if (menuChoice === "3") {
        consoleUtils.info("Keluar dari program.");
        exit = true;
      } else {
        consoleUtils.warn(`Pilihan tidak valid: ${menuChoice}`);
      }
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
