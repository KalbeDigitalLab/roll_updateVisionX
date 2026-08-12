-- Identifies studies in the dcm4chee `study` table with wiped StudyDate/StudyTime
-- caused by the synchronizeStudy() bug (commit 82dc38a0).
--
-- Params are substituted by backfill-study-datetime-prod.sh (:bug_introduced_at /
-- :bug_fixed_at) - do not hardcode timestamps here, they vary per deployment.
--
-- READ-ONLY, modifies nothing.
WITH params AS (
  SELECT
    :'bug_introduced_at'::timestamptz AS bug_introduced_at,
    :'bug_fixed_at'::timestamptz      AS bug_fixed_at
),
sync_events AS (
  SELECT DISTINCT resource_id AS accession_no
  FROM audit_log, params
  WHERE action = 'Synchronize Study'
    AND resource_type = 'Study'
    AND created_at >= params.bug_introduced_at
    AND created_at <  params.bug_fixed_at
    -- target accessions only (source/"unscheduled" rows share the same action+timestamp
    -- pair but aren't real dcm4chee studies to fix) - the join against `study` below
    -- naturally filters those out since only real target accessions match study.accession_no
),
source_dates AS (
  SELECT
    elem->>'value' AS accession_no,
    started
  FROM "imagingStudy",
       LATERAL jsonb_array_elements(identifier) AS elem
  WHERE elem->>'system' = 'http://hospital.smarthealth.org/accession'
)
SELECT
  s.accession_no,
  s.study_iuid,
  s.study_date  AS current_study_date,
  s.study_time  AS current_study_time,
  to_char(src.started, 'YYYYMMDD')            AS new_study_date,
  to_char(src.started, 'HH24MISS') || '.000'  AS new_study_time,
  src.started   AS source_exam_datetime
FROM study s
JOIN sync_events se ON se.accession_no = s.accession_no
LEFT JOIN source_dates src ON src.accession_no = s.accession_no
WHERE s.study_date = '*'
   OR s.study_date IS NULL
   OR s.study_time = '*'
   OR s.study_time IS NULL
ORDER BY s.modified_time;
