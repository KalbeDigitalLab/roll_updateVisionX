const path = require('path');
const consoleUtils = require('../utils/consoleUtils');
const { getAnalyticsLogTables } = require('../utils/analyticsLogTables');

/**
 * `_analytics.log_events_<token>` table names embed a per-site UUID token,
 * and VACUUM cannot run inside a plpgsql function or the implicit
 * per-file transaction executeAllSqlInDir wraps each .sql file in — so
 * this can't be a static .sql file. It has to query the live tokens and
 * schedule the VACUUM cron job dynamically instead.
 */
async function scheduleAnalyticsVacuum(dbAdapter) {
  const { tokens, tableNames } = await getAnalyticsLogTables(dbAdapter);

  if (tokens.length === 0) {
    consoleUtils.info('No _analytics.sources found — skipping vacuum-analytics-logs cron setup.');
    return;
  }

  // A single VACUUM statement takes a comma-separated table list — must
  // stay one statement, not one `VACUUM x;` per table joined together.
  // pg_cron sends the whole command string to Postgres in one shot, and a
  // string containing multiple semicolon-separated statements gets wrapped
  // in an implicit transaction by Postgres itself; VACUUM refuses to run
  // inside a transaction block ("VACUUM cannot run inside a transaction
  // block"). This is the exact bug that broke this job on its first real
  // cron firing (2026-07-22 03:15 UTC) before this fix.
  const vacuumStatement = `VACUUM ${tableNames.join(', ')}`;
  const scheduleSql = `SELECT cron.schedule('vacuum-analytics-logs', '15 3 * * *', '${vacuumStatement.replace(/'/g, "''")}')`;

  await dbAdapter.query(scheduleSql);
  consoleUtils.success(`Scheduled vacuum-analytics-logs for ${tokens.length} table(s).`);
}

async function updateDatabase(dbAdapter) {
  const sqlDir = path.join(__dirname, '../../scripts/sql');
  await dbAdapter.executeAllSqlInDir(sqlDir);
  await scheduleAnalyticsVacuum(dbAdapter);
  consoleUtils.success('DB updated!');
}

module.exports = updateDatabase;
