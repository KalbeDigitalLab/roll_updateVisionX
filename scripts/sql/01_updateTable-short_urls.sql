CREATE TABLE IF NOT EXISTS public.short_urls (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  short_code TEXT UNIQUE NOT NULL,
  target_url TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_short_urls_code ON public.short_urls(short_code);
CREATE INDEX IF NOT EXISTS idx_short_urls_expires ON public.short_urls(expires_at);