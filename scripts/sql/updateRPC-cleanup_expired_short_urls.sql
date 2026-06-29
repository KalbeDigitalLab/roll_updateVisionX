CREATE OR REPLACE FUNCTION cleanup_expired_short_urls()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  deleted_count INTEGER;
BEGIN
  DELETE FROM public.short_urls
  WHERE expires_at < NOW();
  
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  
  RAISE NOTICE 'Deleted % expired short URLs', deleted_count;
END;
$$;

SELECT cron.schedule(
  'cleanup-expired-short-urls',  -- job name
  '0 3 * * *',                   -- cron expression: daily at 3 AM UTC
  'SELECT cleanup_expired_short_urls()'
);

