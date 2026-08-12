const path = require("path");
const { execSync } = require("child_process");
const consoleUtils = require("../utils/consoleUtils");

const SCRIPT_PATH = path.join(__dirname, "..", "..", "backfill-study-datetime-prod.sh");

// Runs FETCH -> DRY RUN, then applies immediately without the interactive
// "Type APPLY to proceed" prompt (--yes) since this path is only reached
// after the operator already confirmed the task via the menu checkbox.
// Running the script directly (not through this menu) still goes through
// the interactive confirm, unaffected by this. stdio: "inherit" passes the
// script's own dry-run output straight through to the operator's terminal.
async function runBackfillStudyDatetime() {
  try {
    execSync(`bash "${SCRIPT_PATH}" --yes`, { stdio: "inherit" });
  } catch (error) {
    consoleUtils.error(`Gagal menjalankan backfill-study-datetime-prod.sh: ${error.message}`);
    throw error;
  }
}

module.exports = runBackfillStudyDatetime;
