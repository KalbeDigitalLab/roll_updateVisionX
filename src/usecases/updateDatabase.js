const path = require('path');
const consoleUtils = require('../utils/consoleUtils');

/**
 * `_analytics.log_events_<token>` table names embed a per-site UUID token,
 * and VACUUM cannot run inside a plpgsql function or the implicit
 * per-file transaction executeAllSqlInDir wraps each .sql file in — so
 * this can't be a static .sql file. It has to query the live tokens and
 * schedule the VACUUM cron job dynamically instead.
 */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function scheduleAnalyticsVacuum(dbAdapter) {
  const result = await dbAdapter.query('SELECT token FROM _analytics.sources');
  const allTokens = result.rows.map((r) => String(r.token));
  const tokens = allTokens.filter((token) => UUID_RE.test(token));

  if (tokens.length < allTokens.length) {
    consoleUtils.warn(
      `Skipping ${allTokens.length - tokens.length} _analytics.sources token(s) that don't look like a UUID (won't be VACUUMed).`,
    );
  }

  if (tokens.length === 0) {
    consoleUtils.info('No _analytics.sources found — skipping vacuum-analytics-logs cron setup.');
    return;
  }

  const vacuumStatements = tokens
    .map((token) => `VACUUM _analytics.log_events_${String(token).replace(/-/g, '_')};`)
    .join(' ');
  const scheduleSql = `SELECT cron.schedule('vacuum-analytics-logs', '15 3 * * *', '${vacuumStatements.replace(/'/g, "''")}')`;

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
