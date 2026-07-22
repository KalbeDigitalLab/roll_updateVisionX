const { execSync } = require("child_process");
const consoleUtils = require("../utils/consoleUtils");

/**
 * Applies the Supabase chart hardening (strategy: Recreate for db, plus
 * startup/readiness/liveness probes for 12 components) that was validated
 * on the staging VM and is committed in the chart repo at
 * SUPABASE_CHART_DIR. Unlike increaseSupabaseLimit.js (a pure values.yaml
 * patch, no downtime), this triggers a brief db pod restart via Recreate,
 * so it requires an explicit operator confirmation and fails loudly on any
 * problem rather than swallowing errors.
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

// Expected probe coverage across all 12 Supabase components, as confirmed
// on the staging VM: startupProbe is db-only (Recreate needs it most, since
// db is the one component with real startup work); livenessProbe covers 7
// components; readinessProbe covers 11 (all but db, which never got a
// readiness probe added).
const PROBE_EXPECTATIONS = {
  db: { startupProbe: true, livenessProbe: true, readinessProbe: false },
  studio: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  auth: { startupProbe: false, livenessProbe: false, readinessProbe: true },
  rest: { startupProbe: false, livenessProbe: false, readinessProbe: true },
  realtime: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  meta: { startupProbe: false, livenessProbe: false, readinessProbe: true },
  storage: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  imgproxy: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  kong: { startupProbe: false, livenessProbe: false, readinessProbe: true },
  analytics: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  vector: { startupProbe: false, livenessProbe: true, readinessProbe: true },
  functions: { startupProbe: false, livenessProbe: false, readinessProbe: true },
};

function checkProbeCoverage(rendered) {
  const mismatches = [];

  for (const [component, expected] of Object.entries(PROBE_EXPECTATIONS)) {
    const doc = findWorkloadDoc(rendered, `visionx-supabase-${component}`);
    if (!doc) {
      mismatches.push(`${component}: not found in rendered chart`);
      continue;
    }

    for (const probeName of ["startupProbe", "livenessProbe", "readinessProbe"]) {
      const present = hasProbe(doc, probeName);
      const shouldBePresent = expected[probeName];
      if (present !== shouldBePresent) {
        mismatches.push(
          `${component}: expected ${probeName} to be ${shouldBePresent ? "present" : "absent"}, but it is ${present ? "present" : "absent"}`,
        );
      }
    }
  }

  if (mismatches.length > 0) {
    throw new Error(
      `Pre-flight check failed: probe coverage does not match the validated 12-component breakdown:\n  - ${mismatches.join("\n  - ")}`,
    );
  }
}

async function hardenSupabaseChart(askHelper) {
  const chartDir = process.env.SUPABASE_CHART_DIR;
  if (!chartDir) {
    throw new Error("Missing required environment variable: SUPABASE_CHART_DIR");
  }

  consoleUtils.info(`Using Supabase chart at: ${chartDir}`);

  // The chart dir is typically owned by a deploy user (e.g. klbfadmin) while
  // this tool commonly runs as root — git refuses to touch a repo it
  // doesn't consider "safe" in that case. Register the exception up front
  // so every site doesn't have to hit the error once and fix it manually.
  execSync(`git config --global --add safe.directory ${chartDir}`, {
    cwd: chartDir,
    stdio: "inherit",
  });

  const dirtyStatus = execSync("git status --porcelain", {
    cwd: chartDir,
  }).toString();
  if (dirtyStatus.trim().length > 0) {
    throw new Error(
      `${chartDir} has uncommitted changes — commit, stash, or discard them manually before running this step:\n${dirtyStatus}`,
    );
  }

  try {
    consoleUtils.info("Fetching latest chart from origin...");
    execSync("git fetch origin", { cwd: chartDir, stdio: "inherit" });
    execSync("git pull --ff-only origin main", {
      cwd: chartDir,
      stdio: "inherit",
    });
  } catch (err) {
    throw new Error(`Failed to sync chart repo (git pull --ff-only): ${err.message}`);
  }

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
    "Pre-flight checks passed (db strategy/replicas, Realtime probes, full 12-component probe coverage).",
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
