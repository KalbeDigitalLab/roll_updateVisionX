-- Identifies studies in the dcm4chee `study` table with missing or wiped metadata
-- (StudyDate, StudyTime, AccessionNumber, StudyDescription, ReferringPhysician, ClinicalInfo)
-- caused by the synchronizeStudy() bug or missing modality attributes.
--
-- Sources the correct values by joining FHIR `"procedure"`, `"imagingStudy"`, `"serviceRequest"`,
-- and `audit_trail` in Postgres.
--
-- READ-ONLY, modifies nothing.
WITH fhir_proc AS (
  SELECT DISTINCT ON (uid.elem->>'value')
    uid.elem->>'value' AS study_iuid,
    COALESCE(NULLIF(acc.elem->>'value', ''), proc."basedOn", '') AS accession_no,
    proc."basedOn" AS sr_id
  FROM public.procedure proc
  CROSS JOIN LATERAL (
    SELECT elem FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(proc.identifier) = 'object' THEN jsonb_build_array(proc.identifier)
        WHEN jsonb_typeof(proc.identifier) = 'array'  THEN proc.identifier
        ELSE '[]'::jsonb
      END
    ) AS elem
    WHERE elem->>'system' LIKE '%/study-id' OR elem->>'system' = 'urn:dicom:uid'
    LIMIT 1
  ) uid(elem)
  LEFT JOIN LATERAL (
    SELECT elem FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(proc.identifier) = 'object' THEN jsonb_build_array(proc.identifier)
        WHEN jsonb_typeof(proc.identifier) = 'array'  THEN proc.identifier
        ELSE '[]'::jsonb
      END
    ) AS elem
    WHERE elem->>'system' = 'http://hospital.smarthealth.org/accession'
    LIMIT 1
  ) acc(elem) ON true
  WHERE uid.elem->>'value' IS NOT NULL
  ORDER BY uid.elem->>'value', proc.created_at DESC
),
fhir_imaging AS (
  SELECT DISTINCT ON (uid.elem->>'value')
    uid.elem->>'value' AS study_iuid,
    acc.elem->>'value' AS accession_no,
    imgs.started
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
      AND elem->>'value' NOT LIKE '%-unscheduled'
    LIMIT 1
  ) acc(elem) ON true
  WHERE imgs.started IS NOT NULL
  ORDER BY uid.elem->>'value', imgs.started DESC
),
audit_sync AS (
  SELECT DISTINCT ON (new_value)
    new_value   AS study_iuid,
    resource_id AS accession_no
  FROM audit_trail
  WHERE field_name = 'studyImageId'
    AND resource_type = 'Study'
    AND new_value IS NOT NULL
    AND new_value != ''
  ORDER BY new_value, created_at DESC
),
fhir_sr_by_acc AS (
  SELECT DISTINCT ON (accession_key)
    accession_key,
    COALESCE(sr.code->'coding'->0->>'display', sr.code->>'text', '') AS study_name,
    COALESCE(sr."requester.display", '') AS referring_doctor,
    COALESCE(sr.reason->'coding'->0->>'display', sr.reason->>'text', '') AS clinical
  FROM "serviceRequest" sr
  CROSS JOIN LATERAL (
    SELECT elem->>'value' AS accession_key
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(sr.identifier) = 'object' THEN jsonb_build_array(sr.identifier)
        WHEN jsonb_typeof(sr.identifier) = 'array'  THEN sr.identifier
        ELSE '[]'::jsonb
      END
    ) AS elem
    WHERE elem->>'system' = 'http://hospital.smarthealth.org/accession'
    UNION ALL
    SELECT sr.id AS accession_key
  ) keys
  WHERE accession_key IS NOT NULL AND accession_key != ''
  ORDER BY accession_key
)
SELECT
  COALESCE(NULLIF(s.accession_no, '*'), NULLIF(pr.accession_no, ''), NULLIF(img.accession_no, ''), NULLIF(aud.accession_no, ''), '') AS accession_no,
  s.study_iuid,
  COALESCE(s.study_date, '')  AS current_study_date,
  COALESCE(s.study_time, '')  AS current_study_time,
  to_char(img.started, 'YYYYMMDD')            AS new_study_date,
  to_char(img.started, 'HH24MISS') || '.000'  AS new_study_time,
  COALESCE(NULLIF(pr.accession_no, ''), NULLIF(img.accession_no, ''), NULLIF(aud.accession_no, ''), '') AS new_accession_no,
  COALESCE(NULLIF(sr_acc.study_name, ''), '')                                         AS new_study_desc,
  COALESCE(NULLIF(sr_acc.referring_doctor, ''), '')                                    AS new_ref_phys,
  COALESCE(NULLIF(sr_acc.clinical, ''), '')                                            AS new_clinical,
  img.started                                                                          AS source_exam_datetime
FROM study s
LEFT JOIN fhir_imaging img ON img.study_iuid = s.study_iuid
LEFT JOIN fhir_proc pr ON pr.study_iuid = s.study_iuid
LEFT JOIN audit_sync aud ON aud.study_iuid = s.study_iuid
LEFT JOIN fhir_sr_by_acc sr_acc ON sr_acc.accession_key = COALESCE(NULLIF(s.accession_no, '*'), NULLIF(pr.accession_no, ''), NULLIF(img.accession_no, ''), NULLIF(aud.accession_no, ''))
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
