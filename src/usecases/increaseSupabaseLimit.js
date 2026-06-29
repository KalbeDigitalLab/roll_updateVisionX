const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const consoleUtils = require("../utils/consoleUtils");

/**
 * Increase Supabase Storage upload limits, as described in the
 * "Increase supabase limit" section of the Roll Updater docx (Table 37).
 *
 * The docx instructs the operator to:
 *   1. Edit `.../supabase-kubernetes/charts/supabase/values.yaml`
 *   2. Comment out the existing `FILE_SIZE_LIMIT: "52428800"` and replace it with
 *         FILE_SIZE_LIMIT:                "5368709120"
 *         UPLOAD_FILE_SIZE_LIMIT:         "5368709120"
 *         UPLOAD_FILE_SIZE_LIMIT_STANDARD:"5368709120"
 *   3. Run `helm upgrade visionx -f values.example.yaml . -n supabase`
 *
 * This module performs all three steps fully automatically and idempotently,
 * because the previous interactive prompts (asking for a byte count and
 * whether to run helm) were confusing operators enough that the step got
 * skipped in practice. Once the operator answers "y" to the top-level
 * "Increase Supabase Storage Limit" question, this module now:
 *   - Uses the docx default of 5368709120 (5 GiB) without asking.
 *   - Accepts values.yaml in flat or nested key format.
 *   - Backs the file up once as `values.yaml.bak-<timestamp>`.
 *   - Only writes changes if something actually needs updating.
 *   - Runs `helm upgrade visionx -f values.example.yaml . -n supabase`
 *     immediately after a successful rewrite (or if the file was already
 *     up to date).
 */

const DEFAULT_LIMIT = "5368709120"; // 5 GiB, per the docx
const LIMIT_KEYS = [
  "FILE_SIZE_LIMIT",
  "UPLOAD_FILE_SIZE_LIMIT",
  "UPLOAD_FILE_SIZE_LIMIT_STANDARD",
];

/**
 * Idempotent + self-healing YAML patcher.
 *
 * Strategy: find EVERY existing line that matches any of the LIMIT_KEYS
 * (commented or not), pick a single "canonical" indent, delete all those
 * lines, and re-insert one clean block of three keys at the position of
 * the first match. This avoids the previous bug where running the patcher
 * a second time could leave behind a half-uncommented line at column 0
 * plus a properly-indented duplicate, producing invalid YAML like:
 *
 *     FILE_SIZE_LIMIT: "5368709120"            <- stray, column 0
 *         FILE_SIZE_LIMIT: "5368709120"
 *         UPLOAD_FILE_SIZE_LIMIT: "5368709120"
 *         UPLOAD_FILE_SIZE_LIMIT_STANDARD: "5368709120"
 *
 * which made `helm upgrade` fail with
 * "error converting YAML to JSON: yaml: line N: did not find expected key".
 */
function patchValuesYaml(yamlText, targetValue) {
  const lines = yamlText.split(/\r?\n/);
  const matches = []; // { idx, indent, key, isCommented, value }

  for (let i = 0; i < lines.length; i++) {
    for (const key of LIMIT_KEYS) {
      const re = new RegExp(`^(\\s*)(#\\s*)?${key}\\s*:\\s*(.*)$`);
      const m = lines[i].match(re);
      if (m) {
        matches.push({
          idx: i,
          indent: m[1],
          key,
          isCommented: Boolean(m[2]),
          value: m[3].trim(),
        });
        break; // at most one key per line
      }
    }
  }

  // Decide canonical indent: prefer an uncommented match with non-empty
  // indent (that is the well-formed line in a nested YAML scope). Fall
  // back to first uncommented, then first commented, then 4 spaces.
  const wellFormed = matches.find((m) => !m.isCommented && m.indent.length > 0);
  const anyUncommented = matches.find((m) => !m.isCommented);
  const indent = wellFormed
    ? wellFormed.indent
    : anyUncommented
      ? anyUncommented.indent
      : matches[0]
        ? matches[0].indent || "    "
        : "    ";

  const desiredBlock = LIMIT_KEYS.map(
    (k) => `${indent}${k}: "${targetValue}"`,
  );

  // Already perfect? Each key must appear exactly once, uncommented, with
  // the desired value, at the canonical indent.
  if (matches.length === LIMIT_KEYS.length) {
    const allOk = LIMIT_KEYS.every((k) => {
      const m = matches.find((x) => x.key === k);
      return (
        m &&
        !m.isCommented &&
        m.indent === indent &&
        m.value === `"${targetValue}"`
      );
    });
    if (allOk) {
      return { text: yamlText, changes: 0 };
    }
  }

  if (matches.length === 0) {
    // No matches anywhere — append at end with a default indent. This is
    // a last-resort path; in a real Supabase chart the keys live nested
    // under storage.environment, so the upstream chart almost always ships
    // a commented `# FILE_SIZE_LIMIT: "52428800"` we can latch onto.
    if (lines[lines.length - 1] !== "") lines.push("");
    lines.push(...desiredBlock);
    return { text: lines.join("\n"), changes: desiredBlock.length };
  }

  // Delete every matching line (reverse order to keep earlier indices
  // valid), then insert the clean block at the position of the first
  // original match.
  const insertAt = Math.min(...matches.map((m) => m.idx));
  const sortedDesc = matches
    .map((m) => m.idx)
    .sort((a, b) => b - a);
  for (const i of sortedDesc) lines.splice(i, 1);
  lines.splice(insertAt, 0, ...desiredBlock);

  return { text: lines.join("\n"), changes: desiredBlock.length };
}

async function increaseSupabaseLimit() {
  const chartDir = process.env.SUPABASE_CHART_DIR;
  if (!chartDir) {
    throw new Error("Missing required environment variable: SUPABASE_CHART_DIR");
  }

  const valuesPath = path.join(chartDir, "values.yaml");

  consoleUtils.info(`Looking for values.yaml at: ${valuesPath}`);

  if (!fs.existsSync(valuesPath)) {
    consoleUtils.error(
      `values.yaml not found. Set SUPABASE_CHART_DIR in run.sh if the chart lives elsewhere.`,
    );
    return;
  }

  const targetValue = DEFAULT_LIMIT;
  consoleUtils.info(
    `Menggunakan target storage limit: ${targetValue} bytes (5 GiB) — otomatis, tidak ditanyakan.`,
  );

  const original = fs.readFileSync(valuesPath, "utf8");
  const { text, changes } = patchValuesYaml(original, targetValue);

  if (changes === 0) {
    consoleUtils.info(
      `values.yaml already has ${LIMIT_KEYS.join(", ")} = ${targetValue}.`,
    );
  } else {
    const backupPath = `${valuesPath}.bak-${Date.now()}`;
    fs.writeFileSync(backupPath, original, "utf8");
    fs.writeFileSync(valuesPath, text, "utf8");
    consoleUtils.success(
      `Updated ${changes} line(s) in values.yaml. Backup saved to ${backupPath}.`,
    );
  }

  try {
    consoleUtils.info(
      `Running helm upgrade visionx -f values.example.yaml . -n supabase (cwd=${chartDir})...`,
    );
    execSync(
      "helm upgrade visionx -f values.example.yaml . -n supabase",
      { cwd: chartDir, stdio: "inherit" },
    );
    consoleUtils.success("helm upgrade completed.");
  } catch (err) {
    consoleUtils.error(`helm upgrade failed: ${err.message}`);
  }
}

module.exports = increaseSupabaseLimit;
module.exports.patchValuesYaml = patchValuesYaml; // exported for tests
