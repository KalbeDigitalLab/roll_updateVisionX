-- (MEI) Add System Config for print
-- Creates a generic system-wide key/value config table.
-- Future system settings (watermark text, page margins, etc.) are additional
-- rows in this table, so no new tables or migrations are required.

CREATE TABLE IF NOT EXISTS public.system_config (
  key        TEXT         PRIMARY KEY,
  value      JSONB        NOT NULL,
  updated_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Seed the print layout default: show header only on the first page.
-- Valid headerMode values: 'first-page' | 'every-page' | 'none'
INSERT INTO public.system_config (key, value)
VALUES ('print_layout', '{"headerMode": "first-page"}')
ON CONFLICT (key) DO NOTHING;
