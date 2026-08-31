const fs = require("fs");
const path = require("path");
const consoleUtils = require("../utils/consoleUtils");

/**
 * Automates the "Supabase Realtime Tenant Not Found" incident runbook:
 * self-hosted Realtime auths clients against `_realtime.tenants.external_id`,
 * matched to the Kubernetes deployment name. A fresh/reset environment can
 * end up with only the default `realtime-dev` tenant, so every client fails
 * with `[error] Auth error: tenant '<deployment>' not found`.
 *
 * Full incident writeup: visionx-vault
 * "02-Troubleshooting/Supabase Realtime Tenant Not Found.md".
 *
 * Flow:
 *   1. Check the Realtime pod's recent logs for the auth error — skip
 *      entirely if none found (nothing to fix).
 *   2. Run the idempotent tenant-seed SQL (scripts/sql/
 *      v21_20260818_fix_realtime_missing_tenant.sql).
 *   3. Restart the Realtime deployment — a raw SQL insert does not
 *      invalidate its in-memory tenant/connection state, confirmed live on
 *      `pacs` 2026-08-18 (insert alone left the error unchanged; only a pod
 *      restart picked up the new tenant).
 *   4. Re-check logs for the same external_id to confirm the error is gone.
 *      Inconclusive (not failed) if no client reconnected during the check
 *      window — logged as a warning, not an error.
 */
async function fixRealtimeMissingTenant(dbAdapter, localAdapter, env) {
  const deployment = env.REALTIME_DEPLOYMENT_NAME || "visionx-supabase-realtime";
  const namespace = env.REALTIME_NAMESPACE || "supabase";
  const authErrorPattern = /\[error\] Auth error: tenant/;
  const tenantLookupPattern = new RegExp(`external_id=${deployment}\\b`);

  consoleUtils.info(
    `Checking ${deployment} (namespace ${namespace}) logs for tenant auth errors...`,
  );

  let preLogs;
  try {
    const result = await localAdapter.execCommand(
      `kubectl logs deployment/${deployment} -n ${namespace} --tail=200`,
    );
    preLogs = result.stdout;
  } catch (err) {
    consoleUtils.error(`Could not read ${deployment} logs: ${err}`);
    throw err;
  }

  if (!authErrorPattern.test(preLogs)) {
    consoleUtils.success(
      `No "Auth error: tenant not found" in the last 200 log lines — ${deployment} looks healthy, skipping fix.`,
    );
    return;
  }

  consoleUtils.warn(
    `Found "Auth error: tenant not found" in ${deployment} logs — applying tenant-seed fix.`,
  );

  const sqlPath = path.join(
    __dirname,
    "../../scripts/sql/v21_20260818_fix_realtime_missing_tenant.sql",
  );
  const sql = fs.readFileSync(sqlPath, "utf8");
  await dbAdapter.query(sql);
  consoleUtils.success("Tenant seed SQL applied (or already present).");

  consoleUtils.info(
    `Restarting ${deployment} so it picks up the tenant (a raw SQL insert alone does not refresh its in-memory state)...`,
  );
  await localAdapter.execCommand(
    `kubectl rollout restart deployment/${deployment} -n ${namespace}`,
  );
  await localAdapter.execCommand(
    `kubectl rollout status deployment/${deployment} -n ${namespace} --timeout=120s`,
  );
  consoleUtils.success(`${deployment} restarted.`);

  consoleUtils.info(
    "Waiting for a client to reconnect, then re-checking logs...",
  );
  await new Promise((resolve) => setTimeout(resolve, 10000));

  const { stdout: postLogs } = await localAdapter.execCommand(
    `kubectl logs deployment/${deployment} -n ${namespace} --tail=100`,
  );

  const stillFailing = authErrorPattern.test(postLogs);
  const sawTenantLookup = tenantLookupPattern.test(postLogs);

  if (stillFailing) {
    consoleUtils.error(
      `Still seeing "Auth error: tenant not found" after fix + restart — needs manual investigation. See visionx-vault "Supabase Realtime Tenant Not Found.md" (§ Bug Terpisah sections cover known follow-on issues; this would be a new one).`,
    );
  } else if (sawTenantLookup) {
    consoleUtils.success(
      "No more tenant auth errors after restart — fix verified against a live reconnect.",
    );
  } else {
    consoleUtils.warn(
      "No auth error after restart, but no client reconnected during the 10s check window either — inconclusive. Re-check logs manually in a minute, or reload the frontend to trigger a reconnect.",
    );
  }
}

module.exports = fixRealtimeMissingTenant;
