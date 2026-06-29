-- (MEI) Realtime Refresh
-- Enable Supabase Realtime for study table source resources.
--
-- StudyTableContainer subscribes to these tables and refetches the
-- paginated study RPC when another user changes study state.
--
-- Safe to run multiple times.

DO $$
DECLARE
  realtime_table_name text;
BEGIN
  FOREACH realtime_table_name IN ARRAY ARRAY[
    'serviceRequest',
    'observation',
    'imagingStudy',
    'diagnosticReport'
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = realtime_table_name
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', realtime_table_name);
    END IF;
  END LOOP;
END
$$;

-- Keep UPDATE/DELETE payloads complete for realtime consumers and debugging.
ALTER TABLE public."serviceRequest" REPLICA IDENTITY FULL;
ALTER TABLE public.observation REPLICA IDENTITY FULL;
ALTER TABLE public."imagingStudy" REPLICA IDENTITY FULL;
ALTER TABLE public."diagnosticReport" REPLICA IDENTITY FULL;

-- Realtime honors RLS. Authenticated browser subscribers must be able to
-- SELECT these rows, otherwise the channel can subscribe but receive no
-- postgres_changes payloads.
ALTER TABLE public."serviceRequest" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.observation ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."imagingStudy" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."diagnosticReport" ENABLE ROW LEVEL SECURITY;
