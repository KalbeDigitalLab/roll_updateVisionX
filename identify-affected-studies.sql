-- Identifies studies in the dcm4chee `study` table with missing or wiped StudyDate, StudyTime, or AccessionNumber.
-- Performs a full database scan across all studies in `study` table without timestamp constraints.
--
-- Sources the correct StudyDate, StudyTime, AccessionNumber, and StudyDescription
-- from the FHIR `imagingStudy` table in Postgres.
--
-- READ-ONLY, modifies nothing.
WITH fhir_studies AS (
  SELECT DISTINCT ON (uid_elem->>'value')
    uid_elem->>'value' AS study_iuid,
    acc_elem->>'value' AS accession_no,
    started,
    description
  FROM "imagingStudy"
  CROSS JOIN LATERAL (
    SELECT elem FROM jsonb_array_elements(identifier) AS elem
    WHERE elem->>'system' LIKE '%/study-id' OR elem->>'system' = 'urn:dicom:uid'
    LIMIT 1
  ) uid(uid_elem)
  LEFT JOIN LATERAL (
    SELECT elem FROM jsonb_array_elements(identifier) AS elem
    WHERE elem->>'system' = 'http://hospital.smarthealth.org/accession'
    LIMIT 1
  ) acc(acc_elem) ON true
  WHERE started IS NOT NULL
  ORDER BY uid_elem->>'value', started DESC
),
fhir_by_acc AS (
  SELECT DISTINCT ON (acc_elem->>'value')
    acc_elem->>'value' AS accession_no,
    started,
    description
  FROM "imagingStudy"
  CROSS JOIN LATERAL (
    SELECT elem FROM jsonb_array_elements(identifier) AS elem
    WHERE elem->>'system' = 'http://hospital.smarthealth.org/accession'
    LIMIT 1
  ) acc(acc_elem)
  WHERE started IS NOT NULL
  ORDER BY acc_elem->>'value', started DESC
)
SELECT
  COALESCE(NULLIF(s.accession_no, '*'), fs.accession_no, fa.accession_no, '') AS accession_no,
  s.study_iuid,
  COALESCE(s.study_date, '')  AS current_study_date,
  COALESCE(s.study_time, '')  AS current_study_time,
  to_char(COALESCE(fs.started, fa.started), 'YYYYMMDD')            AS new_study_date,
  to_char(COALESCE(fs.started, fa.started), 'HH24MISS') || '.000'  AS new_study_time,
  COALESCE(fs.accession_no, fa.accession_no, '')                  AS new_accession_no,
  COALESCE(fs.description, fa.description, '')                    AS new_study_desc,
  COALESCE(fs.started, fa.started)                                 AS source_exam_datetime
FROM study s
LEFT JOIN fhir_studies fs ON fs.study_iuid = s.study_iuid
LEFT JOIN fhir_by_acc fa ON fa.accession_no = s.accession_no AND s.accession_no IS NOT NULL AND s.accession_no != '*'
WHERE s.study_date = '*'
   OR s.study_date IS NULL
   OR btrim(s.study_date) = ''
   OR s.study_time = '*'
   OR s.study_time IS NULL
   OR btrim(s.study_time) = ''
   OR s.accession_no = '*'
   OR s.accession_no IS NULL
   OR btrim(s.accession_no) = ''
ORDER BY s.modified_time NULLS LAST;
