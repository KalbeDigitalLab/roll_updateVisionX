ALTER TABLE public.share_template
  ADD COLUMN IF NOT EXISTS storage_base_url text;
