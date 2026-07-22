CREATE OR REPLACE FUNCTION _analytics.cleanup_old_logs() RETURNS void AS $$
DECLARE
  r RECORD;
  tbl TEXT;
BEGIN
  FOR r IN SELECT token FROM _analytics.sources LOOP
    tbl := format('_analytics.log_events_%s', replace(r.token::text, '-', '_'));
    EXECUTE format('DELETE FROM %s WHERE timestamp < now() - interval ''30 days''', tbl);
  END LOOP;
END;
$$ LANGUAGE plpgsql;

SELECT cron.schedule('cleanup-analytics-logs', '0 3 * * *', 'SELECT _analytics.cleanup_old_logs()');
