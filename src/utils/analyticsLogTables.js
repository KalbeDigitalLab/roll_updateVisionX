const consoleUtils = require('./consoleUtils');

/**
 * `_analytics.log_events_<token>` table names embed a per-site UUID token
 * (from `_analytics.sources.token`), so the table list can't be hardcoded
 * — every site has a different set. Shared by updateDatabase.js (which
 * schedules the recurring VACUUM cron job) and triggerAnalyticsMaintenance.js
 * (which runs it immediately) so both build the identical table list.
 */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function getAnalyticsLogTables(dbAdapter) {
  const result = await dbAdapter.query('SELECT token FROM _analytics.sources');
  const allTokens = result.rows.map((r) => String(r.token));
  const tokens = allTokens.filter((token) => UUID_RE.test(token));

  if (tokens.length < allTokens.length) {
    consoleUtils.warn(
      `Skipping ${allTokens.length - tokens.length} _analytics.sources token(s) that don't look like a UUID (won't be VACUUMed).`,
    );
  }

  const tableNames = tokens.map((token) => `_analytics.log_events_${token.replace(/-/g, '_')}`);
  return { tokens, tableNames };
}

module.exports = { getAnalyticsLogTables };
