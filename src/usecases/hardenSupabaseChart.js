const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const consoleUtils = require("../utils/consoleUtils");

/**
 * Applies the Supabase chart hardening (strategy: Recreate for db, plus
 * startup/readiness/liveness probes for 12 components) to the chart at
 * SUPABASE_CHART_DIR. Unlike increaseSupabaseLimit.js (a pure values.yaml
 * patch, no downtime), this triggers a brief db pod restart via Recreate,
 * so it requires an explicit operator confirmation and fails loudly on any
 * problem rather than swallowing errors.
 *
 * The chart at SUPABASE_CHART_DIR is hand-edited directly on each site's
 * VM (there's no shared internal fork to pull from — its git remote is
 * just the public supabase-community/supabase-kubernetes repo). This
 * usecase does no git operations at all — it applies whatever's on disk,
 * the same as the manual `helm upgrade` process already validated on the
 * staging VM did.
 *
 * Pre-flight checks specifically guard against the incident this hardening
 * itself must not reproduce: Realtime's readinessProbe hitting `httpGet
 * path: /` (the endpoint that caused the original analytics log-bloat
 * incident) instead of the tcpSocket probe its livenessProbe already uses.
 */

// Finds the Deployment/StatefulSet doc for a component by its metadata.name,
// not just a text substring — helm template also renders a Service and
// ConfigMap per component, and other components' Deployments commonly
// reference e.g. "visionx-supabase-db" in env vars (DB_HOST). A plain
// substring match can silently resolve to the wrong resource (one with no
// strategy/replicas/probes at all), making every check below throw a false
// failure. Restrict the name match to the doc's header (first ~20 lines,
// where kind/metadata.name live) so a name mentioned deep in someone else's
// env vars can't match.
function findWorkloadDoc(rendered, resourceName) {
  const docs = rendered.split(/^---$/m);
  return (
    docs.find((doc) => {
      const header = doc.split("\n").slice(0, 20).join("\n");
      const isWorkload = /^kind:\s*(Deployment|StatefulSet)\s*$/m.test(header);
      const nameMatches = new RegExp(`^\\s*name:\\s*${resourceName}\\s*$`, "m").test(header);
      return isWorkload && nameMatches;
    }) || null
  );
}

function hasProbe(doc, probeName) {
  return new RegExp(`^\\s*${probeName}:\\s*$`, "m").test(doc);
}

// All 12 Supabase components. Confirmed on the real VM that the actual
// hardened chart gives every component startupProbe + livenessProbe +
// readinessProbe — more complete than an earlier partial-coverage
// breakdown suggested. So the check below only enforces a minimum baseline
// (readinessProbe + livenessProbe present on all 12) and never fails for
// *extra* probes (e.g. a startupProbe that isn't strictly required) — more
// health-check coverage than the minimum is fine, only missing coverage
// is a real problem. db's strategy/replicas and Realtime's httpGet-path-/
// ban are already covered by their own dedicated checks above/below.
const ALL_COMPONENTS = [
  "db",
  "studio",
  "auth",
  "rest",
  "realtime",
  "meta",
  "storage",
  "imgproxy",
  "kong",
  "analytics",
  "vector",
  "functions",
];
const REQUIRED_PROBES = ["readinessProbe", "livenessProbe"];

// db must never rolling-update — that's the actual root cause fix (see
// supabase-db-wal-corruption-incident doc: overlapping old/new db pods
// during a RollingUpdate both wrote WAL to the same hostPath, corrupting
// the checkpoint record). Hardcoded directly rather than gated behind a
// values key, so it can't be silently missed by a values.yaml that wasn't
// fully updated on a given site (exactly what happened here — the manual
// hardening pass added probes but missed this).
function ensureDbRecreateStrategy(chartDir) {
  const deploymentPath = path.join(chartDir, "templates", "db", "deployment.yaml");
  if (!fs.existsSync(deploymentPath)) {
    consoleUtils.warn(`${deploymentPath} not found — skipping strategy: Recreate injection.`);
    return;
  }

  const content = fs.readFileSync(deploymentPath, "utf8");
  if (/strategy:\s*\n\s*type:\s*Recreate/.test(content)) {
    consoleUtils.info("db deployment already has strategy: Recreate.");
    return;
  }

  const lines = content.split(/\r?\n/);
  const selectorIndex = lines.findIndex((line) => /^ {2}selector:\s*$/.test(line));
  if (selectorIndex === -1) {
    throw new Error(
      `Could not find "  selector:" in ${deploymentPath} to anchor the strategy: Recreate injection — add it manually as a sibling of replicas:/selector:/template: under the Deployment's spec:.`,
    );
  }

  lines.splice(selectorIndex, 0, "  strategy:", "    type: Recreate");
  fs.writeFileSync(deploymentPath, lines.join("\n"), "utf8");
  consoleUtils.success(`Injected strategy: Recreate into ${deploymentPath}`);
}

// Realtime's readinessProbe/livenessProbe templates are already correctly
// wired via `{{- with .Values.realtime.readinessProbe }}` (confirmed on
// the real VM: templates/realtime/deployment.yaml:127-130), so the fix
// belongs in values.example.yaml — the file actually passed via -f to
// every helm command in this usecase — not the template itself.
// readinessProbe: httpGet path:/ port:4000 next to livenessProbe:
// tcpSocket port:4000 is a unique fingerprint: no other component in
// values.example.yaml pairs those two probe shapes on port 4000.
function ensureRealtimeReadinessProbe(chartDir) {
  const valuesPath = path.join(chartDir, "values.example.yaml");
  if (!fs.existsSync(valuesPath)) {
    consoleUtils.warn(`${valuesPath} not found — skipping Realtime readinessProbe fix.`);
    return;
  }

  const content = fs.readFileSync(valuesPath, "utf8");
  const lines = content.split(/\r?\n/);

  const readinessIndex = lines.findIndex((line, i) => {
    if (!/^ {2}readinessProbe:\s*$/.test(line)) return false;
    if (lines[i + 1] !== "    httpGet:") return false;
    if (lines[i + 2] !== "      path: /") return false;
    if (lines[i + 3] !== "      port: 4000") return false;
    const window = lines.slice(i, i + 15).join("\n");
    return /livenessProbe:\s*\n\s*tcpSocket:\s*\n\s*port:\s*4000/.test(window);
  });

  if (readinessIndex === -1) {
    consoleUtils.info(
      "Realtime readinessProbe: httpGet path:/ port:4000 pattern not found in values.example.yaml (already fixed, or in an unexpected shape — the pre-flight check below will catch it either way).",
    );
    return;
  }

  lines.splice(readinessIndex + 1, 3, "    tcpSocket:", "      port: 4000");
  fs.writeFileSync(valuesPath, lines.join("\n"), "utf8");
  consoleUtils.success(`Fixed Realtime readinessProbe to use tcpSocket in ${valuesPath}`);
}

function checkProbeCoverage(rendered) {
  const missing = [];

  for (const component of ALL_COMPONENTS) {
    const doc = findWorkloadDoc(rendered, `visionx-supabase-${component}`);
    if (!doc) {
      missing.push(`${component}: not found in rendered chart`);
      continue;
    }

    for (const probeName of REQUIRED_PROBES) {
      if (!hasProbe(doc, probeName)) {
        missing.push(`${component}: missing ${probeName}`);
      }
    }
  }

  if (missing.length > 0) {
    throw new Error(
      `Pre-flight check failed: some components are missing required probes:\n  - ${missing.join("\n  - ")}`,
    );
  }
}

async function hardenSupabaseChart(askHelper) {
  const chartDir = process.env.SUPABASE_CHART_DIR;
  if (!chartDir) {
    throw new Error("Missing required environment variable: SUPABASE_CHART_DIR");
  }

  consoleUtils.info(`Using Supabase chart at: ${chartDir}`);

  ensureDbRecreateStrategy(chartDir);
  ensureRealtimeReadinessProbe(chartDir);

  consoleUtils.info("Running helm lint...");
  execSync("helm lint .", { cwd: chartDir, stdio: "inherit" });

  consoleUtils.info("Rendering chart with helm template...");
  const rendered = execSync(
    "helm template visionx . -f values.example.yaml -n supabase",
    { cwd: chartDir },
  ).toString();

  const dbDoc = findWorkloadDoc(rendered, "visionx-supabase-db");
  if (!dbDoc) {
    throw new Error("Pre-flight check failed: could not find visionx-supabase-db in rendered chart.");
  }
  if (!/strategy:\s*\n?\s*type:\s*Recreate/.test(dbDoc)) {
    throw new Error("Pre-flight check failed: db deployment is not using strategy: Recreate.");
  }
  if (!/replicas:\s*1\b/.test(dbDoc)) {
    throw new Error("Pre-flight check failed: db deployment does not have replicas: 1.");
  }

  const realtimeDoc = findWorkloadDoc(rendered, "visionx-supabase-realtime");
  if (!realtimeDoc) {
    throw new Error("Pre-flight check failed: could not find visionx-supabase-realtime in rendered chart.");
  }
  if (/readinessProbe:[\s\S]*?httpGet:\s*\n\s*path:\s*\/(?!\S)/.test(realtimeDoc)) {
    throw new Error(
      "Pre-flight check failed: Realtime readinessProbe still points at httpGet path: / — this is the exact endpoint that caused the analytics log-bloat incident. Fix the chart repo before retrying.",
    );
  }
  if (!/readinessProbe:[\s\S]*?tcpSocket:\s*\n\s*port:\s*4000/.test(realtimeDoc)) {
    throw new Error("Pre-flight check failed: Realtime readinessProbe is not using tcpSocket on port 4000.");
  }
  if (!/livenessProbe:[\s\S]*?tcpSocket:\s*\n\s*port:\s*4000/.test(realtimeDoc)) {
    throw new Error("Pre-flight check failed: Realtime livenessProbe is not using tcpSocket on port 4000.");
  }

  checkProbeCoverage(rendered);

  consoleUtils.success(
    "Pre-flight checks passed (db strategy/replicas, Realtime probes, minimum probe coverage across all 12 components).",
  );

  consoleUtils.info("Running kubectl apply --dry-run=server against rendered chart...");
  execSync("kubectl apply --dry-run=server -f -", {
    cwd: chartDir,
    input: rendered,
    stdio: ["pipe", "inherit", "inherit"],
  });

  consoleUtils.warn(
    "This will run `helm upgrade` with strategy: Recreate for the db component, causing a brief db pod restart/downtime.",
  );
  const answer = await askHelper.ask("Proceed with helm upgrade? (y/n) ");
  if (answer.toLowerCase() !== "y") {
    consoleUtils.skipped("Helm upgrade cancelled by operator.");
    return;
  }

  try {
    consoleUtils.info(
      `Running helm upgrade visionx . -f values.example.yaml -n supabase --atomic --wait --timeout 20m (cwd=${chartDir})...`,
    );
    execSync(
      "helm upgrade visionx . -f values.example.yaml -n supabase --atomic --wait --timeout 20m",
      { cwd: chartDir, stdio: "inherit" },
    );
    consoleUtils.success("helm upgrade completed.");
  } catch (err) {
    consoleUtils.error(`helm upgrade failed: ${err.message}`);
    throw err;
  }
}

module.exports = hardenSupabaseChart;
