-- Phase 2: Enable Critical flag on DiagnosticReport
-- Uses IF NOT EXISTS so the roll updater can be run multiple times safely.
ALTER TABLE "diagnosticReport"
ADD COLUMN IF NOT EXISTS "critical" BOOLEAN NOT NULL DEFAULT FALSE;
