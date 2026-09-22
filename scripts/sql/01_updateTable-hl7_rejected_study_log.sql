-- (APRIL) Create hl7_rejected_study_log table and indexes (idempotent)
-- Backing table for the Mirth "Send Rejection Log" destination (mirth-vision-20260803.xml,
-- metaDataId 22). Every HL7 message that trips a conflict/validation rule in the forwarder
-- is written here instead of mutating clinical FHIR resources.
--
-- Column names match the JSON payload actually built in the Mirth transformer
-- ("Build rejection log payload" step) so PostgREST inserts succeed as-is:
--   status, severity, reject_code, reject_reason, accession_number,
--   updated_accession_number, study_instance_uid, patient_id, patient_name,
--   raw_hl7_message, source_channel, rejection_key, incoming_summary
-- The remaining columns (modality, message_control_id, sending_application,
-- sending_facility, existing_resources, resolved_*) are not currently populated
-- by the channel but are kept for future use / manual triage.

CREATE TABLE IF NOT EXISTS public.hl7_rejected_study_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  status TEXT NOT NULL DEFAULT 'open',
  severity TEXT NOT NULL DEFAULT 'warning',

  reject_code TEXT NOT NULL,
  reject_reason TEXT NOT NULL,

  accession_number TEXT,
  updated_accession_number TEXT,
  study_instance_uid TEXT,
  patient_id TEXT,
  patient_name TEXT,
  modality TEXT,

  message_control_id TEXT,
  sending_application TEXT,
  sending_facility TEXT,
  source_channel TEXT DEFAULT 'mirth-vision',

  existing_resources JSONB NOT NULL DEFAULT '{}'::jsonb,
  incoming_summary JSONB NOT NULL DEFAULT '{}'::jsonb,

  raw_hl7_message TEXT,
  rejection_key TEXT,

  resolved_at TIMESTAMPTZ,
  resolved_by TEXT,
  resolution_note TEXT
);

-- Safety net: if this table was already created by hand from the ADR's original DDL
-- (which used `raw_hl7` instead of `raw_hl7_message`), add the column the channel
-- actually sends so inserts don't start failing with a "column not found" error.
ALTER TABLE public.hl7_rejected_study_log
  ADD COLUMN IF NOT EXISTS raw_hl7_message TEXT;

ALTER TABLE public.hl7_rejected_study_log
  ADD COLUMN IF NOT EXISTS rejection_key TEXT;

CREATE INDEX IF NOT EXISTS idx_hl7_rejected_study_log_created_at
  ON public.hl7_rejected_study_log (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_hl7_rejected_study_log_status
  ON public.hl7_rejected_study_log (status);

CREATE INDEX IF NOT EXISTS idx_hl7_rejected_study_log_accession
  ON public.hl7_rejected_study_log (accession_number);

CREATE INDEX IF NOT EXISTS idx_hl7_rejected_study_log_study_uid
  ON public.hl7_rejected_study_log (study_instance_uid);

CREATE INDEX IF NOT EXISTS idx_hl7_rejected_study_log_reject_code
  ON public.hl7_rejected_study_log (reject_code);

-- Idempotency: the Mirth channel POSTs with ?on_conflict=rejection_key and
-- Prefer: resolution=merge-duplicates, which requires this unique index to exist.
CREATE UNIQUE INDEX IF NOT EXISTS idx_hl7_rejected_study_log_rejection_key
  ON public.hl7_rejected_study_log (rejection_key)
  WHERE rejection_key IS NOT NULL;
