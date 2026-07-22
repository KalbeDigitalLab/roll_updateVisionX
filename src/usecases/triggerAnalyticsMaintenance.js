const consoleUtils = require('../utils/consoleUtils');
const { getAnalyticsLogTables } = require('../utils/analyticsLogTables');

/**
 * Runs the analytics log DELETE + VACUUM right now, instead of waiting for
 * their 03:00/03:15 cron schedule (see v20_...analytics_log_cleanup.sql
 * and updateDatabase.js's scheduleAnalyticsVacuum). Kept as its own
 * on-demand step, separate from "Update Database" (runs on every RPC
 * migration, shouldn't also VACUUM 9 tables every time) and separate from
 * "Harden Supabase Chart" (Helm/probes, unrelated to DB maintenance).
 *
 * The VACUUM is sent as its own single query() call, deliberately not
 * combined with the DELETE call above it — bundling them into one
 * multi-statement string would hit the same "VACUUM cannot run inside a
 * transaction block" error the recurring cron job had.
 */
async function triggerAnalyticsMaintenance(dbAdapter) {
  consoleUtils.info('Running _analytics.cleanup_old_logs() now...');
  await dbAdapter.query('SELECT _analytics.cleanup_old_logs()');
  consoleUtils.success('Analytics log cleanup (DELETE) completed.');

  const { tokens, tableNames } = await getAnalyticsLogTables(dbAdapter);
  if (tokens.length === 0) {
    consoleUtils.info('No _analytics.sources found — skipping VACUUM.');
    return;
  }

  consoleUtils.info(`Running VACUUM on ${tokens.length} analytics log table(s) now...`);
  await dbAdapter.query(`VACUUM ${tableNames.join(', ')}`);
  consoleUtils.success('Analytics log VACUUM completed.');
}

module.exports = triggerAnalyticsMaintenance;
