-- Identifies studies in the dcm4chee `study` table with missing or wiped metadata
-- (StudyDate, StudyTime, AccessionNumber, StudyDescription, ReferringPhysician, ClinicalInfo)
-- caused by the synchronizeStudy() bug or missing modality attributes.
--
-- Sources the correct values by joining FHIR `"imagingStudy"` and `"serviceRequest"` tables in Postgres.
--
-- READ-ONLY, modifies nothing.
WITH fhir_imaging AS (
  SELECT DISTINCT ON (uid.elem->>'value')
    uid.elem->>'value' AS study_iuid,
    acc.elem->>'value' AS accession_no,
    imgs.started,
    based_on_sr.ref_id AS sr_id
  FROM "imagingStudy" imgs
  CROSS JOIN LATERAL (
    SELECT elem FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(imgs.identifier) = 'object' THEN jsonb_build_array(imgs.identifier)
        WHEN jsonb_typeof(imgs.identifier) = 'array'  THEN imgs.identifier
        ELSE '[]'::jsonb
      END
    ) AS elem
    WHERE elem->>'system' LIKE '%/study-id' OR elem->>'system' = 'urn:dicom:uid'
    LIMIT 1
  ) uid(elem)
  LEFT JOIN LATERAL (
    SELECT elem FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(imgs.identifier) = 'object' THEN jsonb_build_array(imgs.identifier)
        WHEN jsonb_typeof(imgs.identifier) = 'array'  THEN imgs.identifier
        ELSE '[]'::jsonb
      END
    ) AS elem
    WHERE elem->>'system' = 'http://hospital.smarthealth.org/accession'
    LIMIT 1
  ) acc(elem) ON true
  LEFT JOIN LATERAL (
    SELECT split_part(elem->>'reference', '/', 2) AS ref_id
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(imgs."basedOn") = 'object' THEN jsonb_build_array(imgs."basedOn")
        WHEN jsonb_typeof(imgs."basedOn") = 'array'  THEN imgs."basedOn"
        ELSE '[]'::jsonb
      END
    ) AS elem
    WHERE elem->>'reference' LIKE 'ServiceRequest/%'
    LIMIT 1
  ) based_on_sr(ref_id) ON true
  WHERE imgs.started IS NOT NULL
  ORDER BY uid.elem->>'value', imgs.started DESC
),
fhir_sr_by_acc AS (
  SELECT DISTINCT ON (acc.elem->>'value')
    acc.elem->>'value' AS accession_no,
    sr.id AS sr_id,
    COALESCE(sr.code->'coding'->0->>'display', sr.code->>'text', '') AS study_name,
    COALESCE(sr."requester.display", '') AS referring_doctor,
    COALESCE(sr.reason->'coding'->0->>'display', sr.reason->>'text', '') AS clinical
  FROM "serviceRequest" sr
  CROSS JOIN LATERAL (
    SELECT elem FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(sr.identifier) = 'object' THEN jsonb_build_array(sr.identifier)
        WHEN jsonb_typeof(sr.identifier) = 'array'  THEN sr.identifier
        ELSE '[]'::jsonb
      END
    ) AS elem
    WHERE elem->>'system' = 'http://hospital.smarthealth.org/accession'
    LIMIT 1
  ) acc(elem)
  ORDER BY acc.elem->>'value'
),
fhir_sr_by_id AS (
  SELECT
    sr.id AS sr_id,
    COALESCE(sr.code->'coding'->0->>'display', sr.code->>'text', '') AS study_name,
    COALESCE(sr."requester.display", '') AS referring_doctor,
    COALESCE(sr.reason->'coding'->0->>'display', sr.reason->>'text', '') AS clinical
  FROM "serviceRequest" sr
)
SELECT
  COALESCE(NULLIF(s.accession_no, '*'), img.accession_no, sr_acc.accession_no, '') AS accession_no,
  s.study_iuid,
  COALESCE(s.study_date, '')  AS current_study_date,
  COALESCE(s.study_time, '')  AS current_study_time,
  to_char(img.started, 'YYYYMMDD')            AS new_study_date,
  to_char(img.started, 'HH24MISS') || '.000'  AS new_study_time,
  COALESCE(img.accession_no, sr_acc.accession_no, '')                                 AS new_accession_no,
  COALESCE(NULLIF(sr_id.study_name, ''), NULLIF(sr_acc.study_name, ''), '')         AS new_study_desc,
  COALESCE(NULLIF(sr_id.referring_doctor, ''), NULLIF(sr_acc.referring_doctor, ''), '') AS new_ref_phys,
  COALESCE(NULLIF(sr_id.clinical, ''), NULLIF(sr_acc.clinical, ''), '')                 AS new_clinical,
  img.started                                                                          AS source_exam_datetime
FROM study s
LEFT JOIN fhir_imaging img ON img.study_iuid = s.study_iuid
LEFT JOIN fhir_sr_by_id sr_id ON sr_id.sr_id = img.sr_id
LEFT JOIN fhir_sr_by_acc sr_acc ON sr_acc.accession_no = COALESCE(NULLIF(s.accession_no, '*'), img.accession_no)
WHERE (
     s.study_date = '*'
  OR s.study_date IS NULL
  OR btrim(s.study_date) = ''
  OR s.study_time = '*'
  OR s.study_time IS NULL
  OR btrim(s.study_time) = ''
  OR s.accession_no = '*'
  OR s.accession_no IS NULL
  OR btrim(s.accession_no) = ''
)
AND img.started IS NOT NULL
ORDER BY s.modified_time NULLS LAST;
