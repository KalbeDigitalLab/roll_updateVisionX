const path = require("path");
const fs = require("fs");
const consoleUtils = require("../utils/consoleUtils");

/**
 * Update the `mirth-vision` Mirth Connect channel in place:
 *
 *   1. If the channel already exists, delete it (so the re-import is clean).
 *   2. Parse `updated-mirth.xml` — this is the "Channel + Code Template
 *      Libraries" export produced by Mirth Administrator, so it usually
 *      contains bundled libraries (e.g. moment.js) inside `<exportData>`.
 *   3. Import the code-template libraries FIRST, so that when the channel
 *      is re-imported its transformers can reference `moment()` etc.
 *   4. Import the channel (stripped of `<exportData>`).
 *   5. Deploy using the channel-ID set in `channel-mirth.xml`.
 *
 * This ordering matches what Mirth Administrator does on the wire when you
 * import a channel through the GUI and tick "include code template
 * libraries". The old version of this file skipped step 3, which is why
 * channels that used `moment()` (or any other imported global) blew up at
 * runtime with "moment is not defined".
 */
async function updateMirthChannel(mirthAdapter) {
  const channelName = "mirth-vision";
  const newXmlPath = path.join(
    __dirname,
    "../../scripts/mirth/updated-mirth.xml",
  );
  const deployXmlPath = path.join(
    __dirname,
    "../../scripts/mirth/channel-mirth.xml",
  );

  const channelId = await mirthAdapter.getChannelIdByName(channelName);
  if (channelId) {
    await mirthAdapter.deleteChannel(channelId);
    consoleUtils.success(`Deleted old channel: ${channelName}`);
  }

  const { channelXml, libraries } = await mirthAdapter.modifyChannelXml(
    newXmlPath,
  );

  if (libraries && libraries.length > 0) {
    await mirthAdapter.importCodeTemplateLibraries(libraries);
  } else {
    consoleUtils.info(
      "No bundled code-template libraries found in updated-mirth.xml.",
    );
  }

  await mirthAdapter.importChannel(channelXml);
  consoleUtils.success("Imported new channel");

  const deployXml = fs.readFileSync(deployXmlPath, "utf8");
  await mirthAdapter.deployChannels(deployXml);
  consoleUtils.success("Deployed channel");
}

module.exports = updateMirthChannel;
