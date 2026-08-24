-- Identifies studies in the dcm4chee `study` table with missing or wiped StudyDate/StudyTime.
-- Performs a full database scan across all studies in `study` table without timestamp constraints.
--
-- Sources the correct StudyDate/StudyTime from the FHIR `imagingStudy.started` timestamp,
-- matching by accession number or StudyInstanceUID.
--
-- READ-ONLY, modifies nothing.
WITH source_dates_by_acc AS (
  SELECT DISTINCT ON (elem->>'value')
    elem->>'value' AS accession_no,
    started
  FROM "imagingStudy",
       LATERAL jsonb_array_elements(identifier) AS elem
  WHERE elem->>'system' = 'http://hospital.smarthealth.org/accession'
    AND started IS NOT NULL
  ORDER BY elem->>'value', started DESC
),
source_dates_by_uid AS (
  SELECT DISTINCT ON (elem->>'value')
    elem->>'value' AS study_iuid,
    started
  FROM "imagingStudy",
       LATERAL jsonb_array_elements(identifier) AS elem
  WHERE (elem->>'system' LIKE '%/study-id' OR elem->>'system' = 'urn:dicom:uid')
    AND started IS NOT NULL
  ORDER BY elem->>'value', started DESC
)
SELECT
  s.accession_no,
  s.study_iuid,
  s.study_date  AS current_study_date,
  s.study_time  AS current_study_time,
  to_char(COALESCE(src_acc.started, src_uid.started), 'YYYYMMDD')            AS new_study_date,
  to_char(COALESCE(src_acc.started, src_uid.started), 'HH24MISS') || '.000'  AS new_study_time,
  COALESCE(src_acc.started, src_uid.started)                                  AS source_exam_datetime
FROM study s
LEFT JOIN source_dates_by_acc src_acc ON src_acc.accession_no = s.accession_no AND s.accession_no IS NOT NULL AND s.accession_no != ''
LEFT JOIN source_dates_by_uid src_uid ON src_uid.study_iuid = s.study_iuid AND s.study_iuid IS NOT NULL AND s.study_iuid != ''
WHERE s.study_date = '*'
   OR s.study_date IS NULL
   OR btrim(s.study_date) = ''
   OR s.study_time = '*'
   OR s.study_time IS NULL
   OR btrim(s.study_time) = ''
ORDER BY s.modified_time NULLS LAST;
