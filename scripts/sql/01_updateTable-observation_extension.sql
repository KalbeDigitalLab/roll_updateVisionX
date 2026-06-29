-- Phase 2: Add extension column to Observation (for dose, etc.)
-- Uses IF NOT EXISTS so the roll updater can be run multiple times safely.
ALTER TABLE public.observation
ADD COLUMN IF NOT EXISTS "extension" jsonb NULL;
