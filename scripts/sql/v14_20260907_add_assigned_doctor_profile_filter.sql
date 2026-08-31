ALTER TABLE public.profile_filter
ADD COLUMN IF NOT EXISTS assigned_doctor_filter text[];
