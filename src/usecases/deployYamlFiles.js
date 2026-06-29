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
  ];

  for (const file of yamlFiles) {
    if (!file.remote) {
      consoleUtils.info("YAML entry missing filename in env — skipped.");
      continue;
    }
    consoleUtils.section(`Image file: ${file.remote}`);
    await adapter.updateAndApplyFile(file.remote, file.version, askHelper, {
      optional: file.optional,
    });

    if (file.remote === config.RIS_YAML_FILE) {
      adapter.syncRisTemplateFromYaml(
        config.RIS_YAML_FILE,
        config.RIS_YAML_TEMPLATE_FILE,
      );
    }
  }
}

module.exports = deployYamlFiles;
