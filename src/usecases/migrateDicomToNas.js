const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const consoleUtils = require("../utils/consoleUtils");

/**
 * Automates Step 2-5 of the "Elvasoft PACS Synology NAS Integration - DICOM
 * Only" runbook (visionX4/docs/nas/...): validates NFS connectivity to a
 * Synology NAS, rsyncs existing DICOM data off the dcm4chee-arc hostPath
 * onto the NAS, then switches the arc Deployment's /storage volume from
 * hostPath to an NFS-backed PVC and redeploys.
 *
 * Step 1 (enabling NFS + creating the "PACS" shared folder in Synology DSM)
 * and Step 6 (STOW-RS/OHIF upload verification) stay manual by design — the
 * preflight check in step 2 below is the automated gate that confirms Step 1
 * was actually done before anything destructive runs.
 *
 * Runs entirely via local shell exec (no SSH) — matches how roll-updater is
 * actually used: the operator SSHes/consoles into the single-node K3s VM,
 * `sudo su`s to root, then runs run.sh directly on that box.
 */

const TEST_MOUNT_POINT = "/mnt/test-nfs";
const RSYNC_MOUNT_POINT = "/mnt/nfs/pacs";

// Deliberately NOT read from config.local.env's DRY_RUN — run.sh sources that
// file with `set -a` on every launch, which silently overwrites any
// `DRY_RUN=true` passed on the command line, making it easy to think a run
// was a dry-run when it was not. This usecase asks explicitly instead, every
// time, decoupled from that global config value. Defaults to dry-run (safe)
// on an empty Enter.
let dryRunOverride = true;

function isDryRun() {
  return dryRunOverride;
}

async function askDryRunMode(askHelper) {
  const answer = (
    await askHelper.ask(
      "Jalankan sebagai DRY RUN (command hanya dicetak, TIDAK dieksekusi)? (Y/n, default Y): ",
    )
  )
    .trim()
    .toLowerCase();
  dryRunOverride = answer !== "n";
  return dryRunOverride;
}

async function runBuffered(localAdapter, cmd) {
  if (isDryRun()) {
    consoleUtils.info(`[DRY_RUN] ${cmd}`);
    return { stdout: "", stderr: "" };
  }
  return localAdapter.execCommand(cmd);
}

function runStreaming(cmd) {
  if (isDryRun()) {
    consoleUtils.info(`[DRY_RUN] ${cmd}`);
    return;
  }
  execSync(cmd, { stdio: "inherit", shell: "/bin/bash" });
}

async function promptWithDefault(askHelper, question, defaultValue) {
  const suffix = defaultValue ? ` (Enter = default: ${defaultValue})` : "";
  const answer = (await askHelper.ask(`${question}${suffix}: `)).trim();
  return answer || defaultValue || "";
}

// Tries the known-good default (namespace dcm4chee / Deployment arc, per
// visionx-vault's confirmed architecture) against the live cluster first —
// only falls back to asking if that specific lookup fails (kubectl
// unreachable, or this site genuinely uses different names).
async function detectOrAskArcTarget(askHelper) {
  const candidateNamespace = "dcm4chee";
  const candidateDeployment = "arc";

  try {
    execSync(`kubectl get deployment ${candidateDeployment} -n ${candidateNamespace} -o name`, {
      stdio: ["ignore", "pipe", "pipe"],
    });
    consoleUtils.success(
      `Terdeteksi Deployment dcm4chee-arc: ${candidateDeployment} (namespace ${candidateNamespace}).`,
    );
    return { namespace: candidateNamespace, deployment: candidateDeployment };
  } catch (err) {
    consoleUtils.warn(
      `Tidak bisa auto-detect Deployment ${candidateDeployment} di namespace ${candidateNamespace} ` +
        "(kubectl tidak reachable dari sini, atau namanya memang beda) — isi manual.",
    );
    const namespace = await promptWithDefault(askHelper, "Namespace dcm4chee-arc", candidateNamespace);
    const deployment = await promptWithDefault(askHelper, "Nama Deployment dcm4chee-arc", candidateDeployment);
    return { namespace, deployment };
  }
}

// Reads the LIVE Deployment spec to find whatever volume is actually mounted
// at /storage today — hostPath (matches the current production setup per
// visionx-vault) or an existing PVC — instead of guessing at fixed names.
// Returns null (never throws) if kubectl is unreachable or the deployment
// doesn't exist yet, so callers always have a safe manual-entry fallback.
function detectCurrentStorage(namespace, deployment) {
  try {
    const json = execSync(`kubectl get deployment ${deployment} -n ${namespace} -o json`, {
      stdio: ["ignore", "pipe", "pipe"],
    }).toString();
    const obj = JSON.parse(json);
    const containers = obj.spec.template.spec.containers || [];

    let mount = null;
    for (const c of containers) {
      mount = (c.volumeMounts || []).find((vm) => vm.mountPath === "/storage");
      if (mount) break;
    }
    if (!mount) return null;

    const volume = (obj.spec.template.spec.volumes || []).find((v) => v.name === mount.name);
    if (!volume) return null;

    if (volume.hostPath && volume.hostPath.path) {
      return { type: "hostPath", path: volume.hostPath.path };
    }

    if (volume.persistentVolumeClaim && volume.persistentVolumeClaim.claimName) {
      const pvcName = volume.persistentVolumeClaim.claimName;
      let pvName = "";
      try {
        pvName = execSync(`kubectl get pvc ${pvcName} -n ${namespace} -o jsonpath={.spec.volumeName}`, {
          stdio: ["ignore", "pipe", "pipe"],
        })
          .toString()
          .trim();
      } catch (_) {
        // PVC exists but PV lookup failed — leave blank, deploySwitch will
        // just skip the "kubectl delete pv" step for an empty name.
      }
      return { type: "pvc", pvcName, pvName };
    }

    return null;
  } catch (err) {
    return null;
  }
}

// Looks for exactly one "*arc*.yaml" file in LOCAL_BASE_PATH that isn't the
// NFS storage manifest this usecase itself writes. Ambiguous (0 or 2+
// matches) falls back to asking rather than guessing wrong.
function detectArcYamlFile(basePath) {
  try {
    if (!basePath || !fs.existsSync(basePath)) return null;
    const candidates = fs
      .readdirSync(basePath)
      .filter((f) => /arc/i.test(f) && /\.ya?ml$/i.test(f) && !/nfs-storage/i.test(f));
    if (candidates.length === 1) {
      consoleUtils.success(`Terdeteksi manifest arc: ${candidates[0]}`);
      return candidates[0];
    }
    return null;
  } catch (_) {
    return null;
  }
}

async function collectParams(env, askHelper) {
  consoleUtils.section("Konfigurasi Migrasi NAS");

  const nasIp = await promptWithDefault(
    askHelper,
    "NAS_IP (Synology, wajib diisi, contoh: 10.10.10.12)",
    "",
  );
  if (!nasIp) {
    throw new Error("NAS_IP wajib diisi — migrasi dibatalkan.");
  }

  // Tidak bisa di-auto-detect — di luar cluster, tidak ada API untuk ini.
  const sharePath = await promptWithDefault(askHelper, "Share path di NAS", "/volume1/PACS");

  const { namespace, deployment } = await detectOrAskArcTarget(askHelper);
  const storageInfo = detectCurrentStorage(namespace, deployment);

  let localDicomPath;
  let oldPvcName = "";
  let oldPvName = "";

  if (storageInfo && storageInfo.type === "hostPath") {
    consoleUtils.success(
      `Terdeteksi storage /storage saat ini: hostPath ${storageInfo.path} (bukan PVC — tidak ada PVC/PV lama untuk dihapus).`,
    );
    localDicomPath = await promptWithDefault(
      askHelper,
      "Path data DICOM lokal existing untuk di-rsync",
      path.join(storageInfo.path, "fs1").replace(/\\/g, "/") + "/",
    );
  } else if (storageInfo && storageInfo.type === "pvc") {
    consoleUtils.success(
      `Terdeteksi storage /storage saat ini: PVC ${storageInfo.pvcName}` +
        (storageInfo.pvName ? ` (PV ${storageInfo.pvName})` : "") +
        " — ini yang akan dihapus & diganti.",
    );
    oldPvcName = storageInfo.pvcName;
    oldPvName = storageInfo.pvName;
    localDicomPath = await promptWithDefault(
      askHelper,
      "Path data DICOM lokal existing untuk di-rsync",
      "/home/data/dcm4chee/arc/fs1/",
    );
  } else {
    consoleUtils.warn(
      "Tidak bisa auto-detect storage /storage saat ini (kubectl tidak reachable, atau deployment belum ada) — isi manual.",
    );
    localDicomPath = await promptWithDefault(
      askHelper,
      "Path data DICOM lokal existing (hostPath) untuk di-rsync",
      "/home/data/dcm4chee/arc/fs1/",
    );
    oldPvcName = await promptWithDefault(
      askHelper,
      "Nama PVC lama yang akan dihapus (kosongkan Enter jika tidak ada/tidak yakin)",
      "",
    );
    oldPvName = await promptWithDefault(
      askHelper,
      "Nama PV lama yang akan dihapus (kosongkan Enter jika tidak ada/tidak yakin)",
      "",
    );
  }

  // Nama resource NFS baru — belum ada apa pun untuk dideteksi, jadi pakai
  // default standar diam-diam kecuali operator eksplisit mau custom.
  let pvName = "arc-nfs-pv";
  let pvcName = "arc-nfs-pvc";
  let storageClass = "arc-nfs-storage";
  let storageSize = "1Ti";
  let nfsStorageYamlFile = "06-arc-nfs-storage.yaml";

  const wantCustomNames = (
    await askHelper.ask(
      `Pakai nama resource NFS baru default (PV=${pvName}, PVC=${pvcName}, StorageClass=${storageClass}, size=${storageSize})? (Y/n): `,
    )
  )
    .trim()
    .toLowerCase();

  if (wantCustomNames === "n") {
    pvName = await promptWithDefault(askHelper, "Nama PersistentVolume baru", pvName);
    pvcName = await promptWithDefault(askHelper, "Nama PersistentVolumeClaim baru", pvcName);
    storageClass = await promptWithDefault(askHelper, "Nama StorageClass", storageClass);
    storageSize = await promptWithDefault(askHelper, "Ukuran storage", storageSize);
    nfsStorageYamlFile = await promptWithDefault(askHelper, "Nama file manifest PV/PVC NFS baru", nfsStorageYamlFile);
  }

  const ohifLabelSelector = "app=ohif";

  let arcYamlFile = env.DCM4CHEE_YAML_FILE;
  if (!arcYamlFile) {
    arcYamlFile =
      detectArcYamlFile(env.LOCAL_BASE_PATH) ||
      (await promptWithDefault(
        askHelper,
        "Nama file manifest Deployment arc (relatif ke LOCAL_BASE_PATH)",
        "04-arc.yaml",
      ));
  } else {
    consoleUtils.info(`Menggunakan DCM4CHEE_YAML_FILE dari config: ${arcYamlFile}`);
  }

  return {
    nasIp,
    sharePath,
    namespace,
    deployment,
    localDicomPath,
    pvName,
    pvcName,
    storageClass,
    storageSize,
    oldPvcName,
    oldPvName,
    ohifLabelSelector,
    arcYamlFile,
    nfsStorageYamlFile,
  };
}

async function preflightNfsCheck(localAdapter, params) {
  consoleUtils.section("Step 1/6: Validasi konektivitas NFS ke NAS");
  const probeFile = `_probe.${Date.now()}`;
  const testCmd = [
    `mkdir -p ${TEST_MOUNT_POINT}`,
    `mount -t nfs4 ${params.nasIp}:${params.sharePath} ${TEST_MOUNT_POINT}`,
    `touch ${TEST_MOUNT_POINT}/${probeFile}`,
    `ls -la ${TEST_MOUNT_POINT}`,
  ].join(" && ");

  try {
    const { stdout } = await runBuffered(localAdapter, testCmd);
    if (stdout) consoleUtils.info(stdout.trim());
  } catch (err) {
    consoleUtils.error(
      `Gagal mount/tulis ke NFS share ${params.nasIp}:${params.sharePath}. ` +
        "Cek dulu Step 1 di dokumen (Enable NFS service, Shared Folder 'PACS', NFS Rules dengan privilege Read/Write, Squash: No mapping) sudah selesai di Synology DSM.",
    );
    await runBuffered(localAdapter, `umount ${TEST_MOUNT_POINT}; rmdir ${TEST_MOUNT_POINT}`).catch(() => {});
    throw new Error(`Preflight NFS check gagal: ${err}`);
  }

  await runBuffered(localAdapter, `umount ${TEST_MOUNT_POINT} && rmdir ${TEST_MOUNT_POINT}`);
  consoleUtils.success("NFS share bisa di-mount dan ditulis — Step 1 (setup DSM) sudah benar.");
}

async function rsyncExistingData(localAdapter, params, askHelper) {
  consoleUtils.section("Step 2/6: Mount NAS & rsync data DICOM existing");

  const doRsync = (
    await askHelper.ask(
      "Lakukan rsync data DICOM existing ke NAS sekarang? (Y/n — jawab 'n' kalau data sudah/akan " +
        "dipindahkan sendiri, mis. oleh pihak rumah sakit saat ganti NAS): ",
    )
  )
    .trim()
    .toLowerCase();

  if (doRsync === "n") {
    consoleUtils.skipped(
      "Rsync dilewati atas pilihan operator — pastikan data DICOM sudah/akan ada di NAS sebelum lanjut switch storage.",
    );
    return false;
  }

  if (!isDryRun() && !fs.existsSync(params.localDicomPath)) {
    consoleUtils.warn(
      `${params.localDicomPath} tidak ditemukan di VM ini — tidak ada data existing untuk di-rsync, lanjut tanpa migrasi data.`,
    );
    return false;
  }

  await runBuffered(localAdapter, `mkdir -p ${RSYNC_MOUNT_POINT}`);
  await runBuffered(localAdapter, `mount -t nfs4 ${params.nasIp}:${params.sharePath} ${RSYNC_MOUNT_POINT}`);

  const source = params.localDicomPath.replace(/\/*$/, "/");
  const dest = `${RSYNC_MOUNT_POINT}/fs1/`;
  consoleUtils.info(`Menyalin data dari ${source} ke ${dest} (rsync -avh --progress)...`);

  try {
    runStreaming(`rsync -avh --progress ${source} ${dest}`);
  } catch (err) {
    consoleUtils.error(
      `rsync gagal: ${err.message}. Migrasi dihentikan sebelum PVC di-switch — data lama TIDAK boleh dianggap sudah pindah.`,
    );
    await runBuffered(localAdapter, `umount ${RSYNC_MOUNT_POINT}`).catch(() => {});
    throw err;
  }

  const { stdout } = await runBuffered(localAdapter, `df -h ${RSYNC_MOUNT_POINT} && ls -la ${RSYNC_MOUNT_POINT}`);
  if (stdout) consoleUtils.info(stdout.trim());

  await runBuffered(localAdapter, `umount ${RSYNC_MOUNT_POINT}`);
  consoleUtils.success("Rsync data DICOM ke NAS selesai, mount sementara dilepas.");
  return true;
}

// Only ever offered when rsync actually ran THIS run (not skipped, not a
// no-op from a missing source dir) — otherwise there is no basis for
// believing the data is safely on the NAS. Uses a typed "hapus" confirmation
// instead of the plain y/n used everywhere else in this flow: unlike every
// other step here (manifests are backed up, PVC/PV deletion never touches
// data already copied, scale down/up is reversible), this is the one
// genuinely irreversible action against patient DICOM data.
async function cleanupLocalDicom(localAdapter, params, askHelper) {
  consoleUtils.section("Cleanup Data DICOM Lokal (opsional)");
  consoleUtils.warn(
    `Ini akan MENGHAPUS PERMANEN folder lokal ${params.localDicomPath} dari VM ini untuk membebaskan disk. ` +
      "Pastikan Step 6 (upload test + retrieval via OHIF dari NAS) sudah Anda verifikasi berhasil dulu sebelum " +
      "menghapus — data DICOM pasien di sini tidak bisa dikembalikan lagi kalau ternyata belum aman di NAS.",
  );

  const answer = (
    await askHelper.ask(
      `Ketik persis "hapus" untuk menghapus ${params.localDicomPath} sekarang, atau Enter untuk lewati (hapus manual nanti): `,
    )
  ).trim();

  if (answer !== "hapus") {
    consoleUtils.skipped(
      `Cleanup dilewati — ${params.localDicomPath} TIDAK dihapus, masih ada di VM ini sampai dihapus manual.`,
    );
    return;
  }

  await runBuffered(localAdapter, `rm -rf ${params.localDicomPath}`);
  consoleUtils.success(`${params.localDicomPath} berhasil dihapus dari VM ini.`);
}

function buildNfsStorageManifest(params) {
  return `apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${params.pvName}
  labels:
    type: nfs
    app: arc-dicom
spec:
  storageClassName: ${params.storageClass}
  capacity:
    storage: ${params.storageSize}
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: ${params.nasIp}
    path: ${params.sharePath}
    readOnly: false
  mountOptions:
    - nfsvers=4.1
    - rsize=1048576
    - wsize=1048576
    - hard
    - intr
    - timeo=600
    - retrans=2
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${params.pvcName}
  namespace: ${params.namespace}
spec:
  storageClassName: ${params.storageClass}
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: ${params.storageSize}
`;
}

function writeNfsStorageManifest(env, params) {
  const basePath = env.LOCAL_BASE_PATH;
  if (!fs.existsSync(basePath)) {
    fs.mkdirSync(basePath, { recursive: true });
  }
  const yamlPath = path.join(basePath, params.nfsStorageYamlFile);
  fs.writeFileSync(yamlPath, buildNfsStorageManifest(params), "utf8");
  consoleUtils.success(`Generated ${params.nfsStorageYamlFile} di ${yamlPath}`);
  return yamlPath;
}

const FALLBACK_ARC_IMAGE = "kalbedevops.azurecr.io/dcm4chee/dcm4chee-arc-psql:0.0.15";

function extractCurrentImage(localAdapter, existingYamlPath) {
  if (!fs.existsSync(existingYamlPath)) return FALLBACK_ARC_IMAGE;
  const lines = fs.readFileSync(existingYamlPath, "utf8").split(/\r?\n/);
  const found = localAdapter._findFirstImageLine(lines);
  if (!found) return FALLBACK_ARC_IMAGE;
  const match = found.content.match(/image\s*:\s*(\S+)/);
  return match ? match[1] : FALLBACK_ARC_IMAGE;
}

function buildArcManifest(env, params, imageTag) {
  const postgresHost = env.DCM4CHEE_POSTGRES_HOST || "visionx-supabase-db.supabase";
  const postgresDb = env.SUPABASE_DATABASE || "postgres";
  const postgresUser = env.SUPABASE_USER || "postgres";
  const postgresPassword = env.SUPABASE_PASSWORD || "";

  return `# PV for logs
apiVersion: v1
kind: PersistentVolume
metadata:
  name: log-pv
spec:
  storageClassName: log-storage
  capacity:
    storage: 200Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /home/data/logs
---
# PVC for logs
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: log-claim
  namespace: ${params.namespace}
spec:
  storageClassName: log-storage
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 200Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${params.deployment}
  namespace: ${params.namespace}
  labels:
    app: ${params.deployment}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${params.deployment}
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: ${params.deployment}
    spec:
      containers:
        - name: ${params.deployment}
          image: ${imageTag}
          env:
            - name: POSTGRES_HOST
              value: ${postgresHost}
            - name: POSTGRES_DB
              value: ${postgresDb}
            - name: POSTGRES_USER
              value: ${postgresUser}
            - name: POSTGRES_PASSWORD
              value: ${postgresPassword}
            - name: WILDFLY_CHOWN
              value: /storage
            - name: TZ
              value: Asia/Jakarta
            - name: LANG
              value: "en_US.UTF-8"
            - name: LC_ALL
              value: "en_US.UTF-8"
            - name: POSTGRES_DB_CHARSET
              value: "utf8"
          resources:
            requests:
              memory: "1Gi"
              cpu: "500m"
            limits:
              memory: "2Gi"
              cpu: "1000m"
          ports:
            - containerPort: 8080
              protocol: TCP
            - containerPort: 8443
              protocol: TCP
            - containerPort: 9990
              protocol: TCP
            - containerPort: 9993
              protocol: TCP
            - containerPort: 11112
              protocol: TCP
            - containerPort: 2762
              protocol: TCP
            - containerPort: 2575
              protocol: TCP
            - containerPort: 12575
              protocol: TCP
          volumeMounts:
            - name: arc-nfs-storage
              mountPath: /storage
            - name: log-storage
              mountPath: /opt/wildfly/standalone/log
      imagePullSecrets:
        - name: regcred
      restartPolicy: Always
      volumes:
        - name: arc-nfs-storage
          persistentVolumeClaim:
            claimName: ${params.pvcName}
        - name: log-storage
          persistentVolumeClaim:
            claimName: log-claim
---
apiVersion: v1
kind: Service
metadata:
  name: ${params.deployment}
  namespace: ${params.namespace}
  labels:
    app: ${params.deployment}
spec:
  type: NodePort
  selector:
    app: ${params.deployment}
  ports:
    - name: http
      port: 18080
      targetPort: 8080
      nodePort: 30003
    - name: https
      port: 18443
      targetPort: 8443
    - name: admin-console
      port: 9990
      targetPort: 9990
    - name: admin-management
      port: 9993
      targetPort: 9993
    - name: dicom-tls
      port: 11112
      targetPort: 11112
      nodePort: 30006
    - name: dicom
      port: 2762
      targetPort: 2762
    - name: hl7
      port: 2575
      targetPort: 2575
    - name: hl7-secure
      port: 12575
      targetPort: 12575
`;
}

function writeArcManifest(localAdapter, env, params) {
  const basePath = env.LOCAL_BASE_PATH;
  const yamlPath = path.join(basePath, params.arcYamlFile);

  const imageTag = extractCurrentImage(localAdapter, yamlPath);

  if (fs.existsSync(yamlPath)) {
    const backupPath = `${yamlPath}.bak-${Date.now()}`;
    fs.copyFileSync(yamlPath, backupPath);
    consoleUtils.info(`Backup manifest lama disimpan di ${backupPath}`);
  }

  fs.writeFileSync(yamlPath, buildArcManifest(env, params, imageTag), "utf8");
  consoleUtils.success(`Generated ${params.arcYamlFile} (image: ${imageTag}) di ${yamlPath}`);
  return yamlPath;
}

async function deploySwitch(localAdapter, params, nfsYamlPath, arcYamlPath, askHelper) {
  consoleUtils.section("Step 4/6: Switch storage dcm4chee-arc ke NFS");
  consoleUtils.warn(
    isDryRun()
      ? "DRY_RUN aktif — langkah berikut HANYA akan dicetak, tidak dieksekusi ke cluster."
      : "DRY_RUN TIDAK aktif — langkah berikut akan BENAR-BENAR dieksekusi ke cluster.",
  );
  const oldStorageNote = params.oldPvcName
    ? `hapus PVC/PV lama (${params.oldPvcName}${params.oldPvName ? `/${params.oldPvName}` : ""}), `
    : "";
  consoleUtils.warn(
    `Proses ini akan men-downtime-kan PACS sebentar: scale down ${params.deployment}, ${oldStorageNote}` +
      "apply storage NFS baru, lalu scale up kembali.",
  );
  const confirm = await askHelper.ask("Lanjutkan? (y/n) ");
  if (confirm.toLowerCase() !== "y") {
    consoleUtils.skipped(
      `Switch storage dibatalkan. Manifest sudah digenerate di ${nfsYamlPath} dan ${arcYamlPath} — jalankan menu ini lagi atau apply manual kapan siap.`,
    );
    return false;
  }

  await runBuffered(localAdapter, `kubectl -n ${params.namespace} scale deployment ${params.deployment} --replicas=0`);

  if (params.oldPvcName) {
    await runBuffered(
      localAdapter,
      `kubectl -n ${params.namespace} delete pvc ${params.oldPvcName} --ignore-not-found=true`,
    );
  } else {
    consoleUtils.info("Tidak ada PVC lama terdeteksi/diisi — lewati kubectl delete pvc.");
  }

  if (params.oldPvName) {
    await runBuffered(localAdapter, `kubectl delete pv ${params.oldPvName} --ignore-not-found=true`);
  } else {
    consoleUtils.info("Tidak ada PV lama terdeteksi/diisi — lewati kubectl delete pv.");
  }

  await runBuffered(localAdapter, `kubectl apply -f ${nfsYamlPath}`);
  await runBuffered(localAdapter, `kubectl apply -f ${arcYamlPath}`);

  await runBuffered(localAdapter, `kubectl -n ${params.namespace} scale deployment ${params.deployment} --replicas=1`);
  await runBuffered(
    localAdapter,
    `kubectl -n ${params.namespace} rollout status deployment/${params.deployment} --timeout=180s`,
  );

  consoleUtils.success(`${params.deployment} berhasil di-deploy ulang dengan storage NFS.`);
  return true;
}

async function verifyStorage(localAdapter, params) {
  consoleUtils.section("Step 5/6: Verifikasi mount & permission /storage");

  const { stdout: lsOut } = await runBuffered(
    localAdapter,
    `kubectl -n ${params.namespace} exec deployment/${params.deployment} -- ls -la /storage`,
  );
  if (lsOut) consoleUtils.info(lsOut.trim());

  const { stdout: dfOut } = await runBuffered(
    localAdapter,
    `kubectl -n ${params.namespace} exec deployment/${params.deployment} -- df -h /storage`,
  );
  if (dfOut) consoleUtils.info(dfOut.trim());

  await runBuffered(
    localAdapter,
    `kubectl -n ${params.namespace} exec deployment/${params.deployment} -- chown -R wildfly:wildfly /storage`,
  );
  await runBuffered(
    localAdapter,
    `kubectl -n ${params.namespace} exec deployment/${params.deployment} -- chmod -R 777 /storage`,
  );
  consoleUtils.success("Ownership & permission /storage sudah disesuaikan.");
}

async function reloadOhif(localAdapter, params, askHelper) {
  consoleUtils.section("Step 6/6: Reload OHIF");
  const answer = await askHelper.ask(
    `Restart pod OHIF sekarang supaya baca ulang storage baru? ` +
      `(kubectl -n ${params.namespace} delete pod -l ${params.ohifLabelSelector}) (y/n) `,
  );
  if (answer.toLowerCase() !== "y") {
    consoleUtils.info("Dilewati — reload OHIF manual: jalankan k9s → target pod OHIF → hapus pod (ctrl+D).");
    return;
  }
  await runBuffered(
    localAdapter,
    `kubectl -n ${params.namespace} delete pod -l ${params.ohifLabelSelector} --ignore-not-found=true`,
  );
  consoleUtils.success("Pod OHIF direstart, deployment akan otomatis membuat pod baru.");
}

function printManualChecklist(params) {
  consoleUtils.section("Checklist manual (tidak dieksekusi otomatis)");
  consoleUtils.info(
    [
      "1. Step 1 (Synology DSM): pastikan NFS service, Shared Folder 'PACS', dan NFS Rules sudah dikonfigurasi manual sebelum menjalankan proses ini.",
      "2. Step 6 (Upload & Verify):",
      "   - Upload 1 file DICOM via DCM4CHEE UI Uploader (STOW-RS) atau kirim dari modality.",
      `   - Cek file muncul di Synology DSM > File Station > ${params.sharePath}.`,
      "   - Buka studi tsb via OHIF untuk memastikan retrieval OK.",
      `   - Pantau performa: kubectl top pods -n ${params.namespace}, nfsstat -m.`,
    ].join("\n"),
  );
}

async function migrateDicomToNas(localAdapter, env, askHelper) {
  consoleUtils.title("Migrate DICOM Storage to NAS (NFS)");

  if (!env.LOCAL_BASE_PATH) {
    throw new Error("Missing required environment variable: LOCAL_BASE_PATH");
  }

  if (typeof process.getuid === "function" && process.getuid() !== 0) {
    consoleUtils.warn(
      "Proses ini tidak berjalan sebagai root — command mount/umount/rsync di bawah bisa gagal karena permission. Jalankan roll-updater setelah `sudo su` jika belum.",
    );
  }

  await askDryRunMode(askHelper);
  if (isDryRun()) {
    consoleUtils.warn("DRY_RUN aktif — semua command hanya akan ditampilkan, tidak dieksekusi ke cluster/NAS.");
  } else {
    consoleUtils.warn("DRY_RUN NONAKTIF — command di bawah akan BENAR-BENAR dieksekusi ke cluster/NAS.");
  }

  const params = await collectParams(env, askHelper);

  await preflightNfsCheck(localAdapter, params);
  const rsyncPerformed = await rsyncExistingData(localAdapter, params, askHelper);

  const nfsYamlPath = writeNfsStorageManifest(env, params);
  const arcYamlPath = writeArcManifest(localAdapter, env, params);

  const deployed = await deploySwitch(localAdapter, params, nfsYamlPath, arcYamlPath, askHelper);
  if (!deployed) {
    return;
  }

  await verifyStorage(localAdapter, params);
  await reloadOhif(localAdapter, params, askHelper);
  printManualChecklist(params);

  if (rsyncPerformed) {
    await cleanupLocalDicom(localAdapter, params, askHelper);
  } else {
    consoleUtils.info(
      `Rsync tidak dijalankan di run ini — lewati opsi cleanup, ${params.localDicomPath} TIDAK disentuh sama sekali.`,
    );
  }

  consoleUtils.success("Migrasi DICOM storage ke NAS selesai.");
}

module.exports = migrateDicomToNas;
