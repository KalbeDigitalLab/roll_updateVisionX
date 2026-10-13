const fs = require("fs");
const path = require("path");
const consoleUtils = require("../utils/consoleUtils");

/**
 * Walks through every YAML file known to the roll updater and, for each one,
 * asks the user whether to patch the image tag and whether to apply it.
 *
 * `ris-v1.yaml` (optional) is prompted FIRST so operators can roll the
 * legacy v1 build before the main `ris.yaml`. `ris.yaml` and `ris-v1.yaml`
 * are two common RIS deployments that usually need different tags (for
 * example plain `v1.3.9` for the v1 build and `v1.3.9-basepath` for the
 * default install). They are prompted separately and their tags are asked
 * independently inside `updateAndApplyFile`. `ris-v1.yaml` is marked
 * `optional: true` so installations that don't use it simply see a one-line
 * "skipping" notice instead of a prompt.
 */
async function deployYamlFiles(adapter, config, askHelper) {
  const yamlFiles = [
    {
      remote: config.RIS_V1_YAML_FILE,
      version: config.RIS_V1_IMAGE_VERSION,
      optional: true,
    },
    {
      remote: config.RIS_YAML_FILE,
      version: config.RIS_IMAGE_VERSION,
      optional: false,
    },
    {
      remote: config.BLUE_HALO_YAML_FILE,
      version: config.BLUE_HALO_IMAGE_VERSION,
      optional: false,
    },
    {
      remote: config.OHIF_YAML_FILE,
      version: config.OHIF_IMAGE_VERSION,
      optional: false,
    },
    {
      remote: config.ELVASOFT_DICOM_PROXY_YAML_FILE,
      version: config.ELVASOFT_DICOM_PROXY_IMAGE_VERSION,
      optional: true,
    },
    {
      remote: config.ELVASOFT_HELPER_YAML_FILE,
      version: config.ELVASOFT_HELPER_IMAGE_VERSION,
      optional: true,
    },
  ];

  for (const file of yamlFiles) {
    if (!file.remote) {
      consoleUtils.info("YAML entry missing filename in env — skipped.");
      continue;
    }
    consoleUtils.section(`Image file: ${file.remote}`);

    // Runs BEFORE the image prompt on purpose: it may apply the file, and that
    // must not happen after the operator picked a new tag and declined to deploy.
    if (
      file.remote === config.ELVASOFT_HELPER_YAML_FILE &&
      fs.existsSync(path.join(adapter.remoteBasePath, file.remote))
    ) {
      consoleUtils.warn(
        `Automatically checking/adding the events rule (get/list/watch) to the ClusterRole in ${file.remote}. The RIS log collector needs it to read pod events. Nothing is applied if the rule is already present.`,
      );
      await adapter.ensureHelperEventsRule(file.remote);
    }

    await adapter.updateAndApplyFile(file.remote, file.version, askHelper, {
      optional: file.optional,
    });

    if (file.remote === config.RIS_YAML_FILE || file.remote === config.RIS_V1_YAML_FILE) {
      consoleUtils.warn(
        `Automatically checking/adding readinessProbe in ${file.remote} (tcpSocket probe on the detected container port). Existing readinessProbe blocks are left untouched if already present.`,
      );
      await adapter.ensureRisReadinessProbe(file.remote);

      consoleUtils.warn(
        `Automatically applying resources (memory/cpu requests+limits) and NODE_OPTIONS=--max-old-space-size in ${file.remote} to cap runaway memory growth (see visionx-vault OOM incident notes). This may restart the pod if current usage exceeds the new limit.`,
      );
      await adapter.ensureRisResourceLimits(file.remote);
    }

    if (file.remote === config.RIS_YAML_FILE) {
      adapter.syncRisTemplateFromYaml(
        config.RIS_YAML_FILE,
        config.RIS_YAML_TEMPLATE_FILE,
      );
    }
  }
}

module.exports = deployYamlFiles;
