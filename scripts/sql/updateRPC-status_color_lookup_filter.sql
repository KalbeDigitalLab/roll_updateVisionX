DROP FUNCTION IF EXISTS
    get_wards(text, integer, integer),
    get_bookmarks(text, integer, integer),
    get_mrns(text, integer, integer),
    get_names(text, integer, integer),
    get_birthdate(text, integer, integer),
    get_modalities(text, integer, integer),
    get_study_names(text, integer, integer),
    get_clinical(text, integer, integer),
    get_comments(text, integer, integer),
    get_insurance(text, integer, integer),
    get_pic_doctor(text, integer, integer),
    get_referring_doctor(text, integer, integer),
    get_read_doctors(text, integer, integer),
    get_accession_numbers(text, integer, integer),
    get_radiographers(text, integer, integer),
    get_operators(text, integer, integer),
    get_dose_verificators(text, integer, integer);

-- ΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉ
-- All 16 lookup/autocomplete functions updated with p_report_filter parameter
-- 
-- When p_report_filter is passed as:
--   {"p_performer_id": "uuid", "p_is_report_page": true}
-- 
-- Each function scopes its results to only studies visible on the report page:
--   - Assigned to the performer OR marked "All Doctor"
--   - Order process = done
--   - Images = available  
--   - Report status != final
--
-- When p_report_filter is NULL (default), behavior is unchanged.
-- ΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉ


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 1. get_study_names
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_study_names(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    -- Report-scoped query
    RETURN (
      WITH study_name_data AS (
        SELECT DISTINCT
          sr.code->'coding'->0->>'display' AS study_name,
          sr.code->'coding'->0->>'code' AS study_code,
          sr.code->'coding'->0->>'system' AS study_system
        FROM public."serviceRequest" sr
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          sr.code->'coding'->0->>'display' IS NOT NULL
          AND (
            p_name IS NULL
            OR p_name = ''
            OR LOWER(sr.code->'coding'->0->>'display') LIKE '%' || LOWER(p_name) || '%'
          )
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM study_name_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'display', study_name,
          'code', study_code,
          'system', study_system
        ) AS study_item
        FROM study_name_data
        ORDER BY study_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(study_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    -- Original query (unchanged)
    RETURN (
      WITH study_name_data AS (
        SELECT DISTINCT
          sr.code->'coding'->0->>'display' AS study_name,
          sr.code->'coding'->0->>'code' AS study_code,
          sr.code->'coding'->0->>'system' AS study_system
        FROM public."serviceRequest" sr
        WHERE
          sr.code->'coding'->0->>'display' IS NOT NULL
          AND (
            p_name IS NULL
            OR p_name = ''
            OR LOWER(sr.code->'coding'->0->>'display') LIKE '%' || LOWER(p_name) || '%'
          )
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM study_name_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'display', study_name,
          'code', study_code,
          'system', study_system
        ) AS study_item
        FROM study_name_data
        ORDER BY study_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(study_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 2. get_referring_doctor
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_referring_doctor(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH referring_doctor_data AS (
        SELECT DISTINCT
          sr."requester.display" AS referring_doctor_name
        FROM public."serviceRequest" sr
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          sr."requester.display" IS NOT NULL
          AND sr."requester.display" != ''
          AND (
            p_name IS NULL
            OR p_name = ''
            OR LOWER(sr."requester.display") LIKE '%' || LOWER(p_name) || '%'
          )
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM referring_doctor_data
      ),
      page_items AS (
        SELECT jsonb_build_object('display', referring_doctor_name) AS referring_doctor_item
        FROM referring_doctor_data
        ORDER BY referring_doctor_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(referring_doctor_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH referring_doctor_data AS (
        SELECT DISTINCT
          sr."requester.display" AS referring_doctor_name
        FROM public."serviceRequest" sr
        WHERE
          sr."requester.display" IS NOT NULL
          AND sr."requester.display" != ''
          AND (
            p_name IS NULL
            OR p_name = ''
            OR LOWER(sr."requester.display") LIKE '%' || LOWER(p_name) || '%'
          )
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM referring_doctor_data
      ),
      page_items AS (
        SELECT jsonb_build_object('display', referring_doctor_name) AS referring_doctor_item
        FROM referring_doctor_data
        ORDER BY referring_doctor_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(referring_doctor_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 3. get_pic_doctor
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_pic_doctor(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH pic_doctor_data AS (
        SELECT DISTINCT
          sr."performer.display" AS pic_doctor_name
        FROM public."serviceRequest" sr
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          sr."performer.display" IS NOT NULL
          AND sr."performer.display" != ''
          AND (
            p_name IS NULL
            OR p_name = ''
            OR LOWER(sr."performer.display") LIKE '%' || LOWER(p_name) || '%'
          )
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM pic_doctor_data
      ),
      page_items AS (
        SELECT jsonb_build_object('display', pic_doctor_name) AS pic_doctor_item
        FROM pic_doctor_data
        ORDER BY pic_doctor_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(pic_doctor_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH pic_doctor_data AS (
        SELECT DISTINCT
          sr."performer.display" AS pic_doctor_name
        FROM public."serviceRequest" sr
        WHERE
          sr."performer.display" IS NOT NULL
          AND sr."performer.display" != ''
          AND (
            p_name IS NULL
            OR p_name = ''
            OR LOWER(sr."performer.display") LIKE '%' || LOWER(p_name) || '%'
          )
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM pic_doctor_data
      ),
      page_items AS (
        SELECT jsonb_build_object('display', pic_doctor_name) AS pic_doctor_item
        FROM pic_doctor_data
        ORDER BY pic_doctor_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(pic_doctor_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 4. get_modalities
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_modalities(
  p_name text,
  p_limit integer,
  p_offset integer,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH modality_data AS (
        SELECT DISTINCT
          sr.modality->'coding'->0->>'code' AS modality_code,
          sr.modality->'coding'->0->>'system' AS modality_system
        FROM public."serviceRequest" sr
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          (p_name IS NULL OR p_name = '' OR LOWER(sr.modality->'coding'->0->>'code') LIKE '%' || LOWER(p_name) || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM modality_data
      ),
      page_items AS (
        SELECT jsonb_build_object('code', modality_code, 'system', modality_system) AS modality_item
        FROM modality_data
        ORDER BY modality_code
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(modality_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH modality_data AS (
        SELECT DISTINCT
          sr.modality->'coding'->0->>'code' AS modality_code,
          sr.modality->'coding'->0->>'system' AS modality_system
        FROM public."serviceRequest" sr
        WHERE
          p_name IS NULL OR p_name = '' OR LOWER(sr.modality->'coding'->0->>'code') LIKE '%' || LOWER(p_name) || '%'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM modality_data
      ),
      page_items AS (
        SELECT jsonb_build_object('code', modality_code, 'system', modality_system) AS modality_item
        FROM modality_data
        ORDER BY modality_code
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(modality_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 5. get_insurance
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_insurance(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH insurance_data AS (
        SELECT DISTINCT
          sr.insurance::text AS insurance_display
        FROM public."serviceRequest" sr
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          sr.insurance IS NOT NULL
          AND sr.insurance::text != ''
          AND (p_name IS NULL OR p_name = '' OR LOWER(sr.insurance::text) LIKE '%' || LOWER(p_name) || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM insurance_data
      ),
      page_items AS (
        SELECT jsonb_build_object('display', insurance_display) AS insurance_item
        FROM insurance_data
        ORDER BY insurance_display
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(insurance_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH insurance_data AS (
        SELECT DISTINCT
          sr.insurance::text AS insurance_display
        FROM public."serviceRequest" sr
        WHERE
          sr.insurance IS NOT NULL
          AND sr.insurance::text != ''
          AND (p_name IS NULL OR p_name = '' OR LOWER(sr.insurance::text) LIKE '%' || LOWER(p_name) || '%')
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM insurance_data
      ),
      page_items AS (
        SELECT jsonb_build_object('display', insurance_display) AS insurance_item
        FROM insurance_data
        ORDER BY insurance_display
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(insurance_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 6. get_clinical
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_clinical(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH clinical_data AS (
        SELECT DISTINCT
          sr.reason->'coding'->0->>'display' AS clinical_display,
          sr.reason->'coding'->0->>'code' AS clinical_code,
          sr.reason->'coding'->0->>'system' AS clinical_system
        FROM public."serviceRequest" sr
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          sr.reason->'coding'->0->>'display' IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(sr.reason->'coding'->0->>'display') LIKE '%' || LOWER(p_name) || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM clinical_data
      ),
      page_items AS (
        SELECT jsonb_build_object('display', clinical_display, 'code', clinical_code, 'system', clinical_system) AS clinical_item
        FROM clinical_data
        ORDER BY clinical_display
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(clinical_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH clinical_data AS (
        SELECT DISTINCT
          sr.reason->'coding'->0->>'display' AS clinical_display,
          sr.reason->'coding'->0->>'code' AS clinical_code,
          sr.reason->'coding'->0->>'system' AS clinical_system
        FROM public."serviceRequest" sr
        WHERE
          sr.reason->'coding'->0->>'display' IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(sr.reason->'coding'->0->>'display') LIKE '%' || LOWER(p_name) || '%')
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM clinical_data
      ),
      page_items AS (
        SELECT jsonb_build_object('display', clinical_display, 'code', clinical_code, 'system', clinical_system) AS clinical_item
        FROM clinical_data
        ORDER BY clinical_display
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(clinical_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 7. get_comments
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_comments(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH comment_data AS (
        SELECT DISTINCT
          sr.note AS comment_text
        FROM public."serviceRequest" sr
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          sr.note IS NOT NULL AND sr.note != ''
          AND (p_name IS NULL OR p_name = '' OR LOWER(sr.note) LIKE '%' || LOWER(p_name) || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM comment_data
      ),
      page_items AS (
        SELECT jsonb_build_object('text', comment_text) AS comment_item
        FROM comment_data
        ORDER BY comment_text
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(comment_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH comment_data AS (
        SELECT DISTINCT
          sr.note AS comment_text
        FROM public."serviceRequest" sr
        WHERE
          sr.note IS NOT NULL AND sr.note != ''
          AND (p_name IS NULL OR p_name = '' OR LOWER(sr.note) LIKE '%' || LOWER(p_name) || '%')
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM comment_data
      ),
      page_items AS (
        SELECT jsonb_build_object('text', comment_text) AS comment_item
        FROM comment_data
        ORDER BY comment_text
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(comment_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 8. get_accession_numbers
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_accession_numbers(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH accession_data AS (
        SELECT DISTINCT
          (SELECT val->>'value'
           FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(sr.identifier) = 'object' THEN jsonb_build_array(sr.identifier)
                  WHEN jsonb_typeof(sr.identifier) = 'array' THEN sr.identifier
                  ELSE '[]'::jsonb END
           ) val
           WHERE val->>'system' = 'http://hospital.smarthealth.org/accession'
           LIMIT 1
          ) AS accession_number
        FROM public."serviceRequest" sr
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(sr.identifier) = 'object' THEN jsonb_build_array(sr.identifier)
                   WHEN jsonb_typeof(sr.identifier) = 'array' THEN sr.identifier
                   ELSE '[]'::jsonb END
            ) val
            WHERE val->>'system' = 'http://hospital.smarthealth.org/accession'
              AND val->>'value' IS NOT NULL
              AND (p_name IS NULL OR p_name = '' OR LOWER(val->>'value') LIKE '%' || LOWER(p_name) || '%')
          )
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM accession_data WHERE accession_number IS NOT NULL
      ),
      page_items AS (
        SELECT jsonb_build_object('value', accession_number, 'system', 'http://hospital.smarthealth.org/accession') AS accession_item
        FROM accession_data WHERE accession_number IS NOT NULL
        ORDER BY accession_number
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(accession_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH accession_data AS (
        SELECT DISTINCT
          (SELECT val->>'value'
           FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(sr.identifier) = 'object' THEN jsonb_build_array(sr.identifier)
                  WHEN jsonb_typeof(sr.identifier) = 'array' THEN sr.identifier
                  ELSE '[]'::jsonb END
           ) val
           WHERE val->>'system' = 'http://hospital.smarthealth.org/accession'
           LIMIT 1
          ) AS accession_number
        FROM public."serviceRequest" sr
        WHERE
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(sr.identifier) = 'object' THEN jsonb_build_array(sr.identifier)
                   WHEN jsonb_typeof(sr.identifier) = 'array' THEN sr.identifier
                   ELSE '[]'::jsonb END
            ) val
            WHERE val->>'system' = 'http://hospital.smarthealth.org/accession'
              AND val->>'value' IS NOT NULL
              AND (p_name IS NULL OR p_name = '' OR LOWER(val->>'value') LIKE '%' || LOWER(p_name) || '%')
          )
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM accession_data WHERE accession_number IS NOT NULL
      ),
      page_items AS (
        SELECT jsonb_build_object('value', accession_number, 'system', 'http://hospital.smarthealth.org/accession') AS accession_item
        FROM accession_data WHERE accession_number IS NOT NULL
        ORDER BY accession_number
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(accession_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 9. get_bookmarks
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_bookmarks(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH bookmark_data AS (
        SELECT DISTINCT
          tag.elem->>'valueString' AS bookmark_tag
        FROM public."serviceRequest" sr
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        CROSS JOIN LATERAL jsonb_array_elements(
          CASE WHEN jsonb_typeof(sr.bookmarks) = 'array' THEN sr.bookmarks ELSE '[]'::jsonb END
        ) AS tag(elem)
        WHERE
          tag.elem->>'url' = 'tag'
          AND (p_name IS NULL OR p_name = '' OR LOWER(tag.elem->>'valueString') LIKE '%' || LOWER(p_name) || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM bookmark_data
      ),
      page_items AS (
        SELECT jsonb_build_object('url', 'tag', 'valueString', bookmark_tag) AS bookmark_item
        FROM bookmark_data
        ORDER BY bookmark_tag
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(bookmark_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH bookmark_data AS (
        SELECT DISTINCT
          tag.elem->>'valueString' AS bookmark_tag
        FROM public."serviceRequest" sr,
             jsonb_array_elements(
               CASE WHEN jsonb_typeof(sr.bookmarks) = 'array' THEN sr.bookmarks ELSE '[]'::jsonb END
             ) AS tag(elem)
        WHERE
          tag.elem->>'url' = 'tag'
          AND (p_name IS NULL OR p_name = '' OR LOWER(tag.elem->>'valueString') LIKE '%' || LOWER(p_name) || '%')
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM bookmark_data
      ),
      page_items AS (
        SELECT jsonb_build_object('url', 'tag', 'valueString', bookmark_tag) AS bookmark_item
        FROM bookmark_data
        ORDER BY bookmark_tag
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(bookmark_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 10. get_names (Category B ΓÇö sr + patient_fhir)
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_names(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH patient_name_data AS (
        SELECT DISTINCT ON (full_name)
          pat.id AS patient_id,
          COALESCE(
            (SELECT name_parts->'given'->>0
             FROM jsonb_array_elements(pat.name) name_parts
             WHERE jsonb_typeof(name_parts->'given') = 'array'
             LIMIT 1), ''
          ) AS given_name,
          COALESCE(
            (SELECT name_parts->>'family'
             FROM jsonb_array_elements(pat.name) name_parts
             WHERE name_parts->>'family' IS NOT NULL
             LIMIT 1), ''
          ) AS family_name,
          TRIM(BOTH ' ' FROM
            COALESCE(
              (SELECT name_parts->'given'->>0
               FROM jsonb_array_elements(pat.name) name_parts
               WHERE jsonb_typeof(name_parts->'given') = 'array'
               LIMIT 1), ''
            ) || ' ' ||
            COALESCE(
              (SELECT name_parts->>'family'
               FROM jsonb_array_elements(pat.name) name_parts
               WHERE name_parts->>'family' IS NOT NULL
               LIMIT 1), ''
            )
          ) AS full_name,
          (SELECT val->>'value'
           FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(pat.identifier) = 'object' THEN jsonb_build_array(pat.identifier)
                  WHEN jsonb_typeof(pat.identifier) = 'array' THEN pat.identifier
                  ELSE '[]'::jsonb END
           ) val
           WHERE val->>'system' = 'http://hospital.smarthealth.org/mrn'
           LIMIT 1
          ) AS mrn,
          pat.gender,
          pat."birthDate"
        FROM public."serviceRequest" sr
        INNER JOIN public.patient_fhir pat ON sr.subject = pat.id
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = pat.id
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          pat.name IS NOT NULL
          AND jsonb_typeof(pat.name) = 'array'
          AND jsonb_array_length(pat.name) > 0
          AND (
            p_name IS NULL OR p_name = ''
            OR lower(COALESCE((SELECT name_parts->'given'->>0 FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(name_parts->'given') = 'array' LIMIT 1), '')) LIKE '%' || lower(p_name) || '%'
            OR lower(COALESCE((SELECT name_parts->>'family' FROM jsonb_array_elements(pat.name) name_parts WHERE name_parts->>'family' IS NOT NULL LIMIT 1), '')) LIKE '%' || lower(p_name) || '%'
            OR lower(TRIM(BOTH ' ' FROM COALESCE((SELECT name_parts->'given'->>0 FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(name_parts->'given') = 'array' LIMIT 1), '') || ' ' || COALESCE((SELECT name_parts->>'family' FROM jsonb_array_elements(pat.name) name_parts WHERE name_parts->>'family' IS NOT NULL LIMIT 1), ''))) LIKE '%' || lower(p_name) || '%'
          )
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      filtered AS (
        SELECT * FROM patient_name_data WHERE full_name IS NOT NULL AND TRIM(full_name) != ''
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM filtered
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Patient', 'id', patient_id,
          'identifier', jsonb_build_array(jsonb_build_object('system', 'http://hospital.smarthealth.org/mrn', 'value', COALESCE(mrn, ''))),
          'name', jsonb_build_array(jsonb_build_object('use', 'official', 'given', CASE WHEN given_name IS NOT NULL AND given_name != '' THEN jsonb_build_array(given_name) ELSE '[]'::jsonb END, 'family', COALESCE(family_name, ''))),
          'gender', gender,
          'birthDate', COALESCE(to_char("birthDate", 'YYYY-MM-DD'), '')
        ) AS name_item
        FROM filtered
        ORDER BY full_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(name_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    -- Original query (unchanged)
    RETURN (
      WITH patient_name_data AS (
        SELECT DISTINCT ON (full_name)
          pat.id AS patient_id,
          COALESCE((SELECT name_parts->'given'->>0 FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(name_parts->'given') = 'array' LIMIT 1), '') AS given_name,
          COALESCE((SELECT name_parts->>'family' FROM jsonb_array_elements(pat.name) name_parts WHERE name_parts->>'family' IS NOT NULL LIMIT 1), '') AS family_name,
          TRIM(BOTH ' ' FROM COALESCE((SELECT name_parts->'given'->>0 FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(name_parts->'given') = 'array' LIMIT 1), '') || ' ' || COALESCE((SELECT name_parts->>'family' FROM jsonb_array_elements(pat.name) name_parts WHERE name_parts->>'family' IS NOT NULL LIMIT 1), '')) AS full_name,
          (SELECT val->>'value' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = 'object' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = 'array' THEN pat.identifier ELSE '[]'::jsonb END) val WHERE val->>'system' = 'http://hospital.smarthealth.org/mrn' LIMIT 1) AS mrn,
          pat.gender, pat."birthDate"
        FROM public."serviceRequest" sr
        INNER JOIN public.patient_fhir pat ON sr.subject = pat.id
        WHERE
          pat.name IS NOT NULL AND jsonb_typeof(pat.name) = 'array' AND jsonb_array_length(pat.name) > 0
          AND (
            p_name IS NULL OR p_name = ''
            OR lower(COALESCE((SELECT name_parts->'given'->>0 FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(name_parts->'given') = 'array' LIMIT 1), '')) LIKE '%' || lower(p_name) || '%'
            OR lower(COALESCE((SELECT name_parts->>'family' FROM jsonb_array_elements(pat.name) name_parts WHERE name_parts->>'family' IS NOT NULL LIMIT 1), '')) LIKE '%' || lower(p_name) || '%'
            OR lower(TRIM(BOTH ' ' FROM COALESCE((SELECT name_parts->'given'->>0 FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(name_parts->'given') = 'array' LIMIT 1), '') || ' ' || COALESCE((SELECT name_parts->>'family' FROM jsonb_array_elements(pat.name) name_parts WHERE name_parts->>'family' IS NOT NULL LIMIT 1), ''))) LIKE '%' || lower(p_name) || '%'
          )
      ),
      filtered AS (
        SELECT * FROM patient_name_data WHERE full_name IS NOT NULL AND TRIM(full_name) != ''
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM filtered
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Patient', 'id', patient_id,
          'identifier', jsonb_build_array(jsonb_build_object('system', 'http://hospital.smarthealth.org/mrn', 'value', COALESCE(mrn, ''))),
          'name', jsonb_build_array(jsonb_build_object('use', 'official', 'given', CASE WHEN given_name IS NOT NULL AND given_name != '' THEN jsonb_build_array(given_name) ELSE '[]'::jsonb END, 'family', COALESCE(family_name, ''))),
          'gender', gender,
          'birthDate', COALESCE(to_char("birthDate", 'YYYY-MM-DD'), '')
        ) AS name_item
        FROM filtered
        ORDER BY full_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(name_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 11. get_mrns (Category B ΓÇö sr + patient_fhir)
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_mrns(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH mrn_data AS (
        SELECT DISTINCT ON (mrn_value)
          pat.*,
          (SELECT val->>'value' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = 'object' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = 'array' THEN pat.identifier ELSE '[]'::jsonb END) val WHERE val->>'system' = 'http://hospital.smarthealth.org/mrn' LIMIT 1) AS mrn_value,
          (SELECT string_agg(TRIM(BOTH ' ' FROM COALESCE(name_parts->'given'->>0, '') || ' ' || COALESCE(name_parts->>'family', '')), ', ') FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(pat.name) = 'array' AND jsonb_array_length(pat.name) > 0) AS patient_name
        FROM public."serviceRequest" sr
        INNER JOIN public.patient_fhir pat ON sr.subject = pat.id
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = pat.id
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(pat.identifier) = 'object' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = 'array' THEN pat.identifier ELSE '[]'::jsonb END
            ) val
            WHERE val->>'system' = 'http://hospital.smarthealth.org/mrn'
              AND val->>'value' IS NOT NULL
              AND (p_name IS NULL OR p_name = '' OR LOWER(val->>'value') LIKE '%' || LOWER(p_name) || '%')
          )
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      filtered AS (
        SELECT * FROM mrn_data WHERE mrn_value IS NOT NULL
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM filtered
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Patient', 'id', id,
          'identifier', COALESCE(CASE WHEN jsonb_typeof(identifier) = 'object' THEN jsonb_build_array(identifier) WHEN jsonb_typeof(identifier) = 'array' THEN identifier ELSE '[]'::jsonb END, '[]'::jsonb),
          'name', COALESCE(name, '[]'::jsonb),
          'gender', COALESCE(gender::text, 'unknown'),
          'birthDate', COALESCE(to_char("birthDate", 'YYYY-MM-DD'), ''),
          'mrn', mrn_value,
          'displayName', COALESCE(patient_name, '')
        ) AS patient_item
        FROM filtered
        ORDER BY mrn_value
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(patient_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH mrn_data AS (
        SELECT DISTINCT ON (mrn_value)
          pat.*,
          (SELECT val->>'value' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = 'object' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = 'array' THEN pat.identifier ELSE '[]'::jsonb END) val WHERE val->>'system' = 'http://hospital.smarthealth.org/mrn' LIMIT 1) AS mrn_value,
          (SELECT string_agg(TRIM(BOTH ' ' FROM COALESCE(name_parts->'given'->>0, '') || ' ' || COALESCE(name_parts->>'family', '')), ', ') FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(pat.name) = 'array' AND jsonb_array_length(pat.name) > 0) AS patient_name
        FROM public."serviceRequest" sr
        INNER JOIN public.patient_fhir pat ON sr.subject = pat.id
        WHERE
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = 'object' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = 'array' THEN pat.identifier ELSE '[]'::jsonb END) val
            WHERE val->>'system' = 'http://hospital.smarthealth.org/mrn'
              AND val->>'value' IS NOT NULL
              AND (p_name IS NULL OR p_name = '' OR LOWER(val->>'value') LIKE '%' || LOWER(p_name) || '%')
          )
      ),
      filtered AS (
        SELECT * FROM mrn_data WHERE mrn_value IS NOT NULL
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM filtered
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Patient', 'id', id,
          'identifier', COALESCE(CASE WHEN jsonb_typeof(identifier) = 'object' THEN jsonb_build_array(identifier) WHEN jsonb_typeof(identifier) = 'array' THEN identifier ELSE '[]'::jsonb END, '[]'::jsonb),
          'name', COALESCE(name, '[]'::jsonb),
          'gender', COALESCE(gender::text, 'unknown'),
          'birthDate', COALESCE(to_char("birthDate", 'YYYY-MM-DD'), ''),
          'mrn', mrn_value,
          'displayName', COALESCE(patient_name, '')
        ) AS patient_item
        FROM filtered
        ORDER BY mrn_value
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(patient_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 12. get_birthdate (Category B ΓÇö sr + patient_fhir)
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_birthdate(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH patient_birthdate_data AS (
        SELECT DISTINCT ON (pat."birthDate", pat.id)
          pat.id AS patient_id,
          COALESCE((SELECT name_parts->'given'->>0 FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(name_parts->'given') = 'array' LIMIT 1), '') AS given_name,
          COALESCE((SELECT name_parts->>'family' FROM jsonb_array_elements(pat.name) name_parts WHERE name_parts->>'family' IS NOT NULL LIMIT 1), '') AS family_name,
          (SELECT val->>'value' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = 'object' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = 'array' THEN pat.identifier ELSE '[]'::jsonb END) val WHERE val->>'system' = 'http://hospital.smarthealth.org/mrn' LIMIT 1) AS mrn,
          pat.gender, pat."birthDate"
        FROM public."serviceRequest" sr
        INNER JOIN public.patient_fhir pat ON sr.subject = pat.id
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = pat.id
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          pat."birthDate" IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR pat."birthDate"::text ILIKE '%' || p_name || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      filtered AS (
        SELECT * FROM patient_birthdate_data WHERE "birthDate" IS NOT NULL
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM filtered
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Patient', 'id', patient_id,
          'identifier', jsonb_build_array(jsonb_build_object('system', 'http://hospital.smarthealth.org/mrn', 'value', COALESCE(mrn, ''))),
          'name', jsonb_build_array(jsonb_build_object('use', 'official', 'given', CASE WHEN given_name IS NOT NULL AND given_name != '' THEN jsonb_build_array(given_name) ELSE '[]'::jsonb END, 'family', COALESCE(family_name, ''))),
          'gender', gender,
          'birthDate', to_char("birthDate", 'YYYY-MM-DD')
        ) AS patient_item
        FROM filtered
        ORDER BY "birthDate" DESC, patient_id
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(patient_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH patient_birthdate_data AS (
        SELECT DISTINCT ON (pat."birthDate", pat.id)
          pat.id AS patient_id,
          COALESCE((SELECT name_parts->'given'->>0 FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(name_parts->'given') = 'array' LIMIT 1), '') AS given_name,
          COALESCE((SELECT name_parts->>'family' FROM jsonb_array_elements(pat.name) name_parts WHERE name_parts->>'family' IS NOT NULL LIMIT 1), '') AS family_name,
          (SELECT val->>'value' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = 'object' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = 'array' THEN pat.identifier ELSE '[]'::jsonb END) val WHERE val->>'system' = 'http://hospital.smarthealth.org/mrn' LIMIT 1) AS mrn,
          pat.gender, pat."birthDate"
        FROM public."serviceRequest" sr
        INNER JOIN public.patient_fhir pat ON sr.subject = pat.id
        WHERE
          pat."birthDate" IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR pat."birthDate"::text ILIKE '%' || p_name || '%')
      ),
      filtered AS (
        SELECT * FROM patient_birthdate_data WHERE "birthDate" IS NOT NULL
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM filtered
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Patient', 'id', patient_id,
          'identifier', jsonb_build_array(jsonb_build_object('system', 'http://hospital.smarthealth.org/mrn', 'value', COALESCE(mrn, ''))),
          'name', jsonb_build_array(jsonb_build_object('use', 'official', 'given', CASE WHEN given_name IS NOT NULL AND given_name != '' THEN jsonb_build_array(given_name) ELSE '[]'::jsonb END, 'family', COALESCE(family_name, ''))),
          'gender', gender,
          'birthDate', to_char("birthDate", 'YYYY-MM-DD')
        ) AS patient_item
        FROM filtered
        ORDER BY "birthDate" DESC, patient_id
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(patient_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 13. get_read_doctors (Category C ΓÇö starts from diagnosticReport)
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_read_doctors(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH read_doctor_data AS (
        SELECT DISTINCT
          pr.id AS practitioner_id,
          format_practitioner_name_sql(pr.name) AS read_doctor_name,
          pr.name AS raw_name
        FROM public."diagnosticReport" dr
        JOIN public.practitioner pr ON dr."resultsInterpreter" = pr.id
        JOIN public."serviceRequest" sr ON dr."basedOn" = sr.id
        LEFT JOIN LATERAL (
          SELECT p.* FROM public.procedure p
          WHERE p."basedOn" = sr.id
          ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
          LIMIT 1
        ) proc ON true
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          dr."resultsInterpreter" IS NOT NULL
          AND pr.name IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(format_practitioner_name_sql(pr.name)) LIKE '%' || LOWER(p_name) || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM read_doctor_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'DiagnosticReport',
          'resultsInterpreter', jsonb_build_array(jsonb_build_object('reference', 'Practitioner/' || practitioner_id, 'display', read_doctor_name))
        ) AS read_doctor_item
        FROM read_doctor_data
        ORDER BY read_doctor_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(read_doctor_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH read_doctor_data AS (
        SELECT DISTINCT
          pr.id AS practitioner_id,
          format_practitioner_name_sql(pr.name) AS read_doctor_name,
          pr.name AS raw_name
        FROM public."diagnosticReport" dr
        JOIN public.practitioner pr ON dr."resultsInterpreter" = pr.id
        WHERE
          dr."resultsInterpreter" IS NOT NULL
          AND pr.name IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(format_practitioner_name_sql(pr.name)) LIKE '%' || LOWER(p_name) || '%')
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM read_doctor_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'DiagnosticReport',
          'resultsInterpreter', jsonb_build_array(jsonb_build_object('reference', 'Practitioner/' || practitioner_id, 'display', read_doctor_name))
        ) AS read_doctor_item
        FROM read_doctor_data
        ORDER BY read_doctor_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(read_doctor_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 14. get_radiographers (Category C ΓÇö starts from procedure)
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_radiographers(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH radiographer_data AS (
        SELECT DISTINCT
          pr.id AS practitioner_id,
          format_practitioner_name_sql(pr.name) AS radiographer_name,
          pr.name AS raw_name
        FROM public.procedure proc
        CROSS JOIN LATERAL (
          SELECT fn.value AS function_val, act.value AS actor_val, ordinality
          FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(value, ordinality)
          JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(value, ord2) ON fn.ordinality = act.ord2
          WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(fn.value->'coding') c WHERE c->>'code' = 'Radiografer')
        ) performers
        JOIN public.practitioner pr ON pr.id = split_part(performers.actor_val->>'reference', '/', 2)
        JOIN public."serviceRequest" sr ON proc."basedOn" = sr.id
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          pr.name IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(format_practitioner_name_sql(pr.name)) LIKE '%' || LOWER(p_name) || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM radiographer_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Procedure',
          'function', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/procedure-performer', 'code', 'Radiografer', 'display', 'Radiografer'))),
          'actor', jsonb_build_object('reference', 'Practitioner/' || practitioner_id, 'display', radiographer_name)
        ) AS radiographer_item
        FROM radiographer_data
        ORDER BY radiographer_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(radiographer_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH radiographer_data AS (
        SELECT DISTINCT
          pr.id AS practitioner_id,
          format_practitioner_name_sql(pr.name) AS radiographer_name,
          pr.name AS raw_name
        FROM public.procedure proc
        CROSS JOIN LATERAL (
          SELECT fn.value AS function_val, act.value AS actor_val, ordinality
          FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(value, ordinality)
          JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(value, ord2) ON fn.ordinality = act.ord2
          WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(fn.value->'coding') c WHERE c->>'code' = 'Radiografer')
        ) performers
        JOIN public.practitioner pr ON pr.id = split_part(performers.actor_val->>'reference', '/', 2)
        WHERE
          pr.name IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(format_practitioner_name_sql(pr.name)) LIKE '%' || LOWER(p_name) || '%')
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM radiographer_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Procedure',
          'function', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/procedure-performer', 'code', 'Radiografer', 'display', 'Radiografer'))),
          'actor', jsonb_build_object('reference', 'Practitioner/' || practitioner_id, 'display', radiographer_name)
        ) AS radiographer_item
        FROM radiographer_data
        ORDER BY radiographer_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(radiographer_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 15. get_operators (Category C ΓÇö starts from procedure)
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_operators(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH operator_data AS (
        SELECT DISTINCT
          pr.id AS practitioner_id,
          format_practitioner_name_sql(pr.name) AS operator_name,
          pr.name AS raw_name
        FROM public.procedure proc
        CROSS JOIN LATERAL (
          SELECT fn.value AS function_val, act.value AS actor_val, ordinality
          FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(value, ordinality)
          JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(value, ord2) ON fn.ordinality = act.ord2
          WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(fn.value->'coding') c WHERE c->>'code' = 'Operator')
        ) performers
        JOIN public.practitioner pr ON pr.id = split_part(performers.actor_val->>'reference', '/', 2)
        JOIN public."serviceRequest" sr ON proc."basedOn" = sr.id
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        WHERE
          pr.name IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(format_practitioner_name_sql(pr.name)) LIKE '%' || LOWER(p_name) || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM operator_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Procedure',
          'function', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/procedure-performer', 'code', 'Operator', 'display', 'Operator'))),
          'actor', jsonb_build_object('reference', 'Practitioner/' || practitioner_id, 'display', operator_name)
        ) AS operator_item
        FROM operator_data
        ORDER BY operator_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(operator_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH operator_data AS (
        SELECT DISTINCT
          pr.id AS practitioner_id,
          format_practitioner_name_sql(pr.name) AS operator_name,
          pr.name AS raw_name
        FROM public.procedure proc
        CROSS JOIN LATERAL (
          SELECT fn.value AS function_val, act.value AS actor_val, ordinality
          FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(value, ordinality)
          JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(value, ord2) ON fn.ordinality = act.ord2
          WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(fn.value->'coding') c WHERE c->>'code' = 'Operator')
        ) performers
        JOIN public.practitioner pr ON pr.id = split_part(performers.actor_val->>'reference', '/', 2)
        WHERE
          pr.name IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(format_practitioner_name_sql(pr.name)) LIKE '%' || LOWER(p_name) || '%')
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM operator_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Procedure',
          'function', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/procedure-performer', 'code', 'Operator', 'display', 'Operator'))),
          'actor', jsonb_build_object('reference', 'Practitioner/' || practitioner_id, 'display', operator_name)
        ) AS operator_item
        FROM operator_data
        ORDER BY operator_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(operator_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;


-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
-- 16. get_dose_verificators (Category C ΓÇö starts from observation)
-- ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
CREATE OR REPLACE FUNCTION public.get_dose_verificators(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_performer_id text;
  v_is_report_page boolean;
BEGIN
  v_performer_id := p_report_filter->>'p_performer_id';
  v_is_report_page := COALESCE((p_report_filter->>'p_is_report_page')::boolean, false);

  IF v_is_report_page AND v_performer_id IS NOT NULL AND v_performer_id != '' THEN
    RETURN (
      WITH dose_verificator_data AS (
        SELECT DISTINCT
          pr.id AS practitioner_id,
          format_practitioner_name_sql(pr.name) AS dose_verificator_name,
          pr.name AS raw_name
        FROM public.observation obs
        JOIN public.practitioner pr ON obs.performer = pr.id
        JOIN public.procedure proc ON obs."partOf" = proc.id
        JOIN public."serviceRequest" sr ON proc."basedOn" = sr.id
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public."imagingStudy" imgs ON EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(imgs.identifier, '[]'::jsonb)) img_ident,
               jsonb_array_elements(COALESCE(proc.identifier, '[]'::jsonb)) proc_ident
          WHERE img_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND proc_ident->>'system' = 'http://hospital.smarthealth.org/accession'
            AND img_ident->>'value' = proc_ident->>'value'
        ) AND imgs.subject = sr.subject
        WHERE
          obs.performer IS NOT NULL
          AND pr.name IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(format_practitioner_name_sql(pr.name)) LIKE '%' || LOWER(p_name) || '%')
          AND ((dr.performer = v_performer_id) OR COALESCE(dr."isAllDoctor", false))
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'order') = 'done'
          AND LOWER(determine_process_sql(sr.status::text, sr.modality->'coding'->0->>'code', proc.status::text, imgs.status::text, dr.status::text, obs.status::text)->>'image') = 'available'
          AND COALESCE(LOWER(dr.status::text), '') != 'final'
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM dose_verificator_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Observation',
          'performer', jsonb_build_array(jsonb_build_object('reference', 'Practitioner/' || practitioner_id, 'display', dose_verificator_name))
        ) AS dose_verificator_item
        FROM dose_verificator_data
        ORDER BY dose_verificator_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(dose_verificator_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  ELSE
    RETURN (
      WITH dose_verificator_data AS (
        SELECT DISTINCT
          pr.id AS practitioner_id,
          format_practitioner_name_sql(pr.name) AS dose_verificator_name,
          pr.name AS raw_name
        FROM public.observation obs
        JOIN public.practitioner pr ON obs.performer = pr.id
        WHERE
          obs.performer IS NOT NULL
          AND pr.name IS NOT NULL
          AND (p_name IS NULL OR p_name = '' OR LOWER(format_practitioner_name_sql(pr.name)) LIKE '%' || LOWER(p_name) || '%')
      ),
      total_count AS (
        SELECT COUNT(*)::INT AS total FROM dose_verificator_data
      ),
      page_items AS (
        SELECT jsonb_build_object(
          'resourceType', 'Observation',
          'performer', jsonb_build_array(jsonb_build_object('reference', 'Practitioner/' || practitioner_id, 'display', dose_verificator_name))
        ) AS dose_verificator_item
        FROM dose_verificator_data
        ORDER BY dose_verificator_name
        LIMIT p_limit OFFSET p_offset
      )
      SELECT jsonb_build_object(
        'items', COALESCE((SELECT jsonb_agg(dose_verificator_item) FROM page_items), '[]'::jsonb),
        'total', (SELECT total FROM total_count),
        'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
      )
    );
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fast_fetch_studies_paginated_filter_v5(p_column_filters jsonb DEFAULT '[]'::jsonb, p_sorting jsonb DEFAULT '[]'::jsonb, p_index integer DEFAULT 0, p_size integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  result          jsonb;
  v_offset        integer;
  v_total_count   bigint;

  v_filters       jsonb := '{}'::jsonb;
  filter_item     jsonb;
  sort_item       jsonb;

  v_order_by      text := '';
  v_where_clause  text := '';
  v_sql           text;

  -- Optimization flags: join only what we need in COUNT query
  v_needs_patient BOOLEAN := FALSE;
  v_needs_dr BOOLEAN := FALSE;
  v_needs_proc BOOLEAN := FALSE;
  v_needs_imgs BOOLEAN := FALSE;
  v_needs_obs BOOLEAN := FALSE;

  v_needs_proc_radiographers BOOLEAN := FALSE;
  v_needs_proc_operator BOOLEAN := FALSE;
  v_needs_dr_read_pract BOOLEAN := FALSE;
  v_needs_dr_assigned_pract BOOLEAN := FALSE;
  v_needs_obs_dose_verificator BOOLEAN := FALSE;

BEGIN
  /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ offset ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
  v_offset := p_index * p_size;

  /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ convert filters array -> object ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
  FOR filter_item IN SELECT * FROM jsonb_array_elements(p_column_filters) LOOP
    v_filters := v_filters || jsonb_build_object(filter_item->>'id', filter_item->'value');
  END LOOP;

  /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ Analyze which tables we need (COUNT query only) ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
  IF v_filters->>'mrn' IS NOT NULL OR
     v_filters->>'name' IS NOT NULL OR
     v_filters->>'birthDate' IS NOT NULL OR
     v_filters->>'age' IS NOT NULL OR
     v_filters->>'sex' IS NOT NULL OR
     v_filters->>'studyHistoryBasedOnMRN' IS NOT NULL OR
     v_filters->>'studyHistoryBasedOnAccession' IS NOT NULL THEN
    v_needs_patient := TRUE;
  END IF;

  IF v_filters->>'readDoctor' IS NOT NULL OR
     v_filters->>'status' IS NOT NULL OR
     v_filters->>'examRead' IS NOT NULL OR
     v_filters->>'reportKeywords' IS NOT NULL OR
     v_filters->>'processStatusFilter' IS NOT NULL OR
     v_filters->>'pageSpecificFilters' IS NOT NULL THEN
    v_needs_dr := TRUE;
  END IF;

  IF v_filters->>'radiographer' IS NOT NULL OR
     v_filters->>'operator' IS NOT NULL OR
     v_filters->>'examRegister' IS NOT NULL OR
     v_filters->>'status' IS NOT NULL OR
     v_filters->>'processStatusFilter' IS NOT NULL OR
     v_filters->>'pageSpecificFilters' IS NOT NULL THEN
    v_needs_proc := TRUE;
  END IF;

  IF v_filters->>'examImages' IS NOT NULL OR
     v_filters->>'status' IS NOT NULL OR
     v_filters->>'processStatusFilter' IS NOT NULL OR
     v_filters->>'pageSpecificFilters' IS NOT NULL THEN
    v_needs_imgs := TRUE;
  END IF;

  IF v_filters->>'doseVerificator' IS NOT NULL OR
     v_filters->>'status' IS NOT NULL OR
     v_filters->>'processStatusFilter' IS NOT NULL OR
     v_filters->>'pageSpecificFilters' IS NOT NULL THEN
    v_needs_obs := TRUE;
  END IF;

  IF v_filters->>'radiographer' IS NOT NULL THEN
    v_needs_proc_radiographers := TRUE;
    v_needs_proc := TRUE;
  END IF;

  IF v_filters->>'operator' IS NOT NULL THEN
    v_needs_proc_operator := TRUE;
    v_needs_proc := TRUE;
  END IF;

  IF v_filters->>'readDoctor' IS NOT NULL THEN
    v_needs_dr_read_pract := TRUE;
    v_needs_dr := TRUE;
  END IF;

  IF v_filters->>'doseVerificator' IS NOT NULL THEN
    v_needs_obs_dose_verificator := TRUE;
    v_needs_obs := TRUE;
  END IF;

  /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ Sorting requirements (also affects COUNT joins) ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
  IF jsonb_array_length(p_sorting) > 0 THEN
    v_order_by := ' ORDER BY ';
    FOR sort_item IN SELECT * FROM jsonb_array_elements(p_sorting) LOOP
      CASE sort_item->>'id'
        WHEN 'mrn', 'name', 'birthDate', 'age', 'sex' THEN
          v_needs_patient := TRUE;
        WHEN 'status' THEN
          v_needs_dr := TRUE;
          v_needs_proc := TRUE;
          v_needs_imgs := TRUE;
          v_needs_obs := TRUE;
        WHEN 'assignedDoctor' THEN
          v_needs_dr := TRUE;
          v_needs_dr_assigned_pract := TRUE;
        WHEN 'readDoctor' THEN
          v_needs_dr := TRUE;
          v_needs_dr_read_pract := TRUE;
        WHEN 'examRead' THEN
          v_needs_dr := TRUE;
        WHEN 'radiographer' THEN
          v_needs_proc := TRUE;
          v_needs_proc_radiographers := TRUE;
        WHEN 'operator' THEN
          v_needs_proc := TRUE;
          v_needs_proc_operator := TRUE;
        WHEN 'doseVerificator' THEN
          v_needs_obs := TRUE;
          v_needs_obs_dose_verificator := TRUE;
        WHEN 'examRegister' THEN
          v_needs_proc := TRUE;
        WHEN 'examImages', 'imageCount' THEN
          v_needs_imgs := TRUE;
        ELSE NULL;
      END CASE;

      IF v_order_by <> ' ORDER BY ' THEN
        v_order_by := v_order_by || ', ';
      END IF;

      v_order_by := v_order_by ||
        CASE sort_item->>'id'
          WHEN 'examination'     THEN 'sr."occurrence.dateTime"'
          WHEN 'cito'            THEN '(sr.priority::text = ''stat'')'
          WHEN 'mrn'             THEN '(SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' LIMIT 1)'
          WHEN 'name'            THEN '(SELECT string_agg(TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', '''')), '', '') FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(pat.name) = ''array'' AND jsonb_array_length(pat.name) > 0)'
          WHEN 'status'          THEN 'determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text)'
          WHEN 'modality'        THEN 'sr.modality->''coding''->0->>''code'''
          WHEN 'accessionNumber' THEN '(SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier) WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1)'
          WHEN 'studyName'       THEN 'sr.code->''coding''->0->>''display'''
          WHEN 'ward'            THEN 'sr."locationCode"'
          WHEN 'referringDoctor' THEN 'sr."requester.display"'
          WHEN 'assignedDoctor'  THEN 'CASE WHEN COALESCE(dr."isAllDoctor", false) THEN ''All Doctor'' ELSE format_practitioner_name_sql(dr_assigned_pract.name) END'
          WHEN 'picDoctor'       THEN 'sr."performer.display"'
          WHEN 'readDoctor'      THEN 'format_practitioner_name_sql(dr_read_pract.name)'
          WHEN 'radiographer'    THEN 'proc_radiographers.radiographer_names'
          WHEN 'operator'        THEN 'proc_operator.operator_name'
          WHEN 'doseVerificator' THEN 'format_practitioner_name_sql(obs_dose_verificator.name)'
          WHEN 'examRegister'    THEN 'proc."performedDateTime"'
          WHEN 'examRead'        THEN 'dr."effective.dateTime"'
          WHEN 'examImages'      THEN 'imgs.started'
          WHEN 'imageCount'      THEN 'imgs."numberOfInstances"'
          WHEN 'clinical'        THEN 'sr.reason->''coding''->0->>''display'''
          WHEN 'insurance'       THEN 'sr.insurance::text'
          WHEN 'birthDate'       THEN 'pat."birthDate"'
          WHEN 'age'             THEN 'calculate_age_sql(sr."occurrence.dateTime", pat."birthDate")'
          WHEN 'sex'             THEN 'CASE pat.gender::text WHEN ''female'' THEN ''F'' WHEN ''male'' THEN ''M'' ELSE ''O'' END'
          WHEN 'isExported'      THEN 'COALESCE((sr."isExported")::boolean, false)'
          ELSE 'sr."occurrence.dateTime"'
        END || ' ' ||
        CASE
          WHEN (sort_item->'desc')::text = 'true'  THEN 'DESC'
          WHEN (sort_item->'desc')::text = 'false' THEN 'ASC'
          ELSE 'DESC'
        END || ' NULLS LAST';
    END LOOP;
  ELSE
    v_order_by := ' ORDER BY sr."occurrence.dateTime" DESC NULLS LAST';
  END IF;

  /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ Build WHERE clause ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
  v_where_clause := '';

  IF v_filters != '{}'::jsonb THEN
    -- Bookmark filter
    IF v_filters->>'bookmark' IS NOT NULL THEN
      IF jsonb_typeof(v_filters->'bookmark') = 'array' THEN
        v_where_clause := v_where_clause ||
          ' AND EXISTS (' ||
          '   SELECT 1 FROM jsonb_array_elements(sr.bookmarks) elem' ||
          '   WHERE elem->>''url'' = ''tag''' ||
          '   AND EXISTS (' ||
          '     SELECT 1 FROM jsonb_array_elements_text(' || quote_literal((v_filters->'bookmark')::text) || '::jsonb) search_term' ||
          '     WHERE LOWER(elem->>''valueString'') ILIKE ''%'' || LOWER(search_term) || ''%''' ||
          '   )' ||
          ' )';
      ELSE
        v_where_clause := v_where_clause ||
          ' AND EXISTS (' ||
          '   SELECT 1 FROM jsonb_array_elements(sr.bookmarks) elem' ||
          '   WHERE elem->>''url'' = ''tag''' ||
          '   AND LOWER(elem->>''valueString'') ILIKE ''%'' || LOWER(' || quote_literal(v_filters->>'bookmark') || ') || ''%''' ||
          ' )';
      END IF;
    END IF;

    -- Ward
    IF v_filters->>'ward' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('sr."locationCode"', v_filters->'ward', FALSE);
    END IF;

    -- Study Name
    IF v_filters->>'studyName' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('(sr.code->''coding''->0->>''display'')', v_filters->'studyName', FALSE);
    END IF;

    -- Clinical
    IF v_filters->>'clinical' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('(sr.reason->''coding''->0->>''display'')', v_filters->'clinical', FALSE);
    END IF;

    -- Comment
    IF v_filters->>'comment' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('sr.note', v_filters->'comment', FALSE);
    END IF;

    -- Insurance
    IF v_filters->>'insurance' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('sr.insurance::text', v_filters->'insurance', FALSE);
    END IF;

    -- Pic Doctor
    IF v_filters->>'picDoctor' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('sr."performer.display"', v_filters->'picDoctor', FALSE);
    END IF;

    -- Referring Doctor
    IF v_filters->>'referringDoctor' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('sr."requester.display"', v_filters->'referringDoctor', FALSE);
    END IF;

    -- Read Doctor
    IF v_filters->>'readDoctor' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('format_practitioner_name_sql(dr_read_pract.name)', v_filters->'readDoctor', FALSE);
    END IF;

    -- Radiographer
    IF v_filters->>'radiographer' IS NOT NULL THEN
      v_where_clause := v_where_clause || '
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(proc."performer.function") f,
               jsonb_array_elements(f->''coding'') c
          WHERE c->>''code'' = ''Radiografer''
        )
        AND ' || _ilike_predicate('proc_radiographers.radiographer_names', v_filters->'radiographer', FALSE);
    END IF;

    -- Operator
    IF v_filters->>'operator' IS NOT NULL THEN
      v_where_clause := v_where_clause || '
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(proc."performer.function") f,
               jsonb_array_elements(f->''coding'') c
          WHERE c->>''code'' = ''Operator''
        )
        AND ' || _ilike_predicate('proc_operator.operator_name', v_filters->'operator', FALSE);
    END IF;

    -- Dose Verificator
    IF v_filters->>'doseVerificator' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('format_practitioner_name_sql(obs_dose_verificator.name)', v_filters->'doseVerificator', FALSE);
    END IF;

    -- Accession Number
    IF v_filters->>'accessionNumber' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate(
          '(SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier) WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1)',
          v_filters->'accessionNumber',
          FALSE
        );
    END IF;

    -- Age
    IF v_filters->>'age' IS NOT NULL THEN
      v_where_clause := v_where_clause ||
        ' AND calculate_age_sql(sr."occurrence.dateTime", pat."birthDate")::text ILIKE ''%'' || ' ||
        quote_literal(v_filters->>'age') || ' || ''%''';
    END IF;

    -- Birth Date
    IF v_filters->>'birthDate' IS NOT NULL THEN
      DECLARE
        v_birthdate_filter TEXT;
      BEGIN
        v_birthdate_filter := REPLACE(v_filters->>'birthDate', '''', '');

        IF LENGTH(v_birthdate_filter) = 4 THEN
          v_where_clause := v_where_clause ||
            ' AND EXTRACT(YEAR FROM pat."birthDate") = ' || (v_birthdate_filter::integer);
        ELSIF LENGTH(v_birthdate_filter) = 7 AND v_birthdate_filter LIKE '____-__' THEN
          v_where_clause := v_where_clause ||
            ' AND TO_CHAR(pat."birthDate", ''YYYY-MM'') = ' || quote_literal(v_birthdate_filter);
        ELSIF LENGTH(v_birthdate_filter) = 10 AND v_birthdate_filter LIKE '____-__-__' THEN
          v_where_clause := v_where_clause ||
            ' AND pat."birthDate" = ' || quote_literal(v_birthdate_filter) || '::date';
        ELSE
          v_where_clause := v_where_clause ||
            ' AND pat."birthDate"::text ILIKE ''%'' || ' || quote_literal(v_birthdate_filter) || ' || ''%''';
        END IF;
      END;
    END IF;

    -- MRN
    IF v_filters->>'mrn' IS NOT NULL THEN
      IF jsonb_typeof(v_filters->'mrn') = 'array' THEN
        v_where_clause := v_where_clause ||
          ' AND LOWER((SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' LIMIT 1))' ||
          ' = ANY(SELECT LOWER(jsonb_array_elements_text(' || quote_literal((v_filters->'mrn')::text) || '::jsonb)))';
      ELSE
        v_where_clause := v_where_clause ||
          ' AND (SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' LIMIT 1)' ||
          ' ILIKE ''%'' || ' || quote_literal(v_filters->>'mrn') || ' || ''%''';
      END IF;
    END IF;

    -- Name
    IF v_filters->>'name' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate(
          '(SELECT string_agg(TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', '''')), '', '') FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(pat.name) = ''array'' AND jsonb_array_length(pat.name) > 0)',
          v_filters->'name',
          FALSE
        );
    END IF;

    -- Status
    IF v_filters->>'status' IS NOT NULL THEN
      IF jsonb_typeof(v_filters->'status') = 'array' THEN
        v_where_clause := v_where_clause ||
          ' AND LOWER(determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text))' ||
          ' = ANY(SELECT LOWER(jsonb_array_elements_text(' || quote_literal((v_filters->'status')::text) || '::jsonb)))';
      ELSE
        v_where_clause := v_where_clause ||
          ' AND LOWER(determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text))' ||
          ' = LOWER(' || quote_literal(v_filters->>'status') || ')';
      END IF;
    END IF;

    -- Modality
    IF v_filters->>'modality' IS NOT NULL THEN
      IF jsonb_typeof(v_filters->'modality') = 'array' THEN
        v_where_clause := v_where_clause ||
          ' AND EXISTS (' ||
          '   SELECT 1 FROM jsonb_array_elements_text(' || quote_literal((v_filters->'modality')::text) || '::jsonb) search_term' ||
          '   WHERE UPPER(sr.modality->''coding''->0->>''code'') LIKE ''%'' || UPPER(search_term) || ''%''' ||
          ' )';
      ELSE
        v_where_clause := v_where_clause ||
          ' AND UPPER(sr.modality->''coding''->0->>''code'') LIKE ''%'' || UPPER(' || quote_literal(v_filters->>'modality') || ') || ''%''';
      END IF;
    END IF;

    -- CITO
    IF v_filters->>'cito' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND (sr.priority::text = ''stat'') = ' || (v_filters->>'cito')::boolean;
    END IF;

    -- Sex
    IF v_filters->>'sex' IS NOT NULL THEN
      IF jsonb_typeof(v_filters->'sex') = 'array' THEN
        v_where_clause := v_where_clause ||
          ' AND UPPER(CASE pat.gender::text WHEN ''female'' THEN ''F'' WHEN ''male'' THEN ''M'' ELSE ''O'' END)' ||
          ' = ANY(SELECT UPPER(jsonb_array_elements_text(' || quote_literal((v_filters->'sex')::text) || '::jsonb)))';
      ELSE
        v_where_clause := v_where_clause ||
          ' AND UPPER(CASE pat.gender::text WHEN ''female'' THEN ''F'' WHEN ''male'' THEN ''M'' ELSE ''O'' END)' ||
          ' = UPPER(' || quote_literal(v_filters->>'sex') || ')';
      END IF;
    END IF;

    -- Date ranges
    IF v_filters->>'examination' IS NOT NULL AND jsonb_typeof(v_filters->'examination') = 'object' AND (v_filters->'examination'->>'type') = 'dateRange' THEN
      IF v_filters->'examination'->>'start' IS NOT NULL THEN
        v_where_clause := v_where_clause || ' AND sr."occurrence.dateTime" >= ' || quote_literal(v_filters->'examination'->>'start') || '::timestamp';
      END IF;
      IF v_filters->'examination'->>'end' IS NOT NULL THEN
        v_where_clause := v_where_clause || ' AND sr."occurrence.dateTime" <= ' || quote_literal(v_filters->'examination'->>'end') || '::timestamp';
      END IF;
    END IF;

    IF v_filters->>'examRead' IS NOT NULL THEN
      IF jsonb_typeof(v_filters->'examRead') = 'object' AND (v_filters->'examRead'->>'type') = 'dateRange' THEN
        IF v_filters->'examRead'->>'start' IS NOT NULL THEN
          v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= ' || quote_literal(v_filters->'examRead'->>'start') || '::timestamp';
        END IF;
        IF v_filters->'examRead'->>'end' IS NOT NULL THEN
          v_where_clause := v_where_clause || ' AND dr."effective.dateTime" <= ' || quote_literal(v_filters->'examRead'->>'end') || '::timestamp';
        END IF;
      ELSIF jsonb_typeof(v_filters->'examRead') = 'string' THEN
        CASE v_filters->>'examRead'
          WHEN 'Today' THEN
            v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= CURRENT_DATE AND dr."effective.dateTime" < CURRENT_DATE + INTERVAL ''1 day''';
          WHEN 'Last 7 Days' THEN
            v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= CURRENT_DATE - INTERVAL ''7 days'' AND dr."effective.dateTime" < CURRENT_DATE + INTERVAL ''1 day''';
          WHEN 'Last 30 Days' THEN
            v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= CURRENT_DATE - INTERVAL ''30 days'' AND dr."effective.dateTime" < CURRENT_DATE + INTERVAL ''1 day''';
          WHEN 'This Month' THEN
            v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= DATE_TRUNC(''month'', CURRENT_DATE) AND dr."effective.dateTime" < DATE_TRUNC(''month'', CURRENT_DATE) + INTERVAL ''1 month''';
          WHEN 'Last Month' THEN
            v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= DATE_TRUNC(''month'', CURRENT_DATE - INTERVAL ''1 month'') AND dr."effective.dateTime" < DATE_TRUNC(''month'', CURRENT_DATE)';
          ELSE NULL;
        END CASE;
      END IF;
    END IF;

    IF v_filters->>'examRegister' IS NOT NULL THEN
      IF jsonb_typeof(v_filters->'examRegister') = 'object' AND (v_filters->'examRegister'->>'type') = 'dateRange' THEN
        IF v_filters->'examRegister'->>'start' IS NOT NULL THEN
          v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= ' || quote_literal(v_filters->'examRegister'->>'start') || '::timestamp';
        END IF;
        IF v_filters->'examRegister'->>'end' IS NOT NULL THEN
          v_where_clause := v_where_clause || ' AND proc."performedDateTime" <= ' || quote_literal(v_filters->'examRegister'->>'end') || '::timestamp';
        END IF;
      ELSIF jsonb_typeof(v_filters->'examRegister') = 'string' THEN
        CASE v_filters->>'examRegister'
          WHEN 'Today' THEN
            v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= CURRENT_DATE AND proc."performedDateTime" < CURRENT_DATE + INTERVAL ''1 day''';
          WHEN 'Last 7 Days' THEN
            v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= CURRENT_DATE - INTERVAL ''7 days'' AND proc."performedDateTime" < CURRENT_DATE + INTERVAL ''1 day''';
          WHEN 'Last 30 Days' THEN
            v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= CURRENT_DATE - INTERVAL ''30 days'' AND proc."performedDateTime" < CURRENT_DATE + INTERVAL ''1 day''';
          WHEN 'This Month' THEN
            v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= DATE_TRUNC(''month'', CURRENT_DATE) AND proc."performedDateTime" < DATE_TRUNC(''month'', CURRENT_DATE) + INTERVAL ''1 month''';
          WHEN 'Last Month' THEN
            v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= DATE_TRUNC(''month'', CURRENT_DATE - INTERVAL ''1 month'') AND proc."performedDateTime" < DATE_TRUNC(''month'', CURRENT_DATE)';
          ELSE NULL;
        END CASE;
      END IF;
    END IF;

    IF v_filters->>'examImages' IS NOT NULL THEN
      IF jsonb_typeof(v_filters->'examImages') = 'object' AND (v_filters->'examImages'->>'type') = 'dateRange' THEN
        IF v_filters->'examImages'->>'start' IS NOT NULL THEN
          v_where_clause := v_where_clause || ' AND imgs.started >= ' || quote_literal(v_filters->'examImages'->>'start') || '::timestamp';
        END IF;
        IF v_filters->'examImages'->>'end' IS NOT NULL THEN
          v_where_clause := v_where_clause || ' AND imgs.started <= ' || quote_literal(v_filters->'examImages'->>'end') || '::timestamp';
        END IF;
      ELSIF jsonb_typeof(v_filters->'examImages') = 'string' THEN
        CASE v_filters->>'examImages'
          WHEN 'Today' THEN
            v_where_clause := v_where_clause || ' AND imgs.started >= CURRENT_DATE AND imgs.started < CURRENT_DATE + INTERVAL ''1 day''';
          WHEN 'Last 7 Days' THEN
            v_where_clause := v_where_clause || ' AND imgs.started >= CURRENT_DATE - INTERVAL ''7 days'' AND imgs.started < CURRENT_DATE + INTERVAL ''1 day''';
          WHEN 'Last 30 Days' THEN
            v_where_clause := v_where_clause || ' AND imgs.started >= CURRENT_DATE - INTERVAL ''30 days'' AND imgs.started < CURRENT_DATE + INTERVAL ''1 day''';
          WHEN 'This Month' THEN
            v_where_clause := v_where_clause || ' AND imgs.started >= DATE_TRUNC(''month'', CURRENT_DATE) AND imgs.started < DATE_TRUNC(''month'', CURRENT_DATE) + INTERVAL ''1 month''';
          WHEN 'Last Month' THEN
            v_where_clause := v_where_clause || ' AND imgs.started >= DATE_TRUNC(''month'', CURRENT_DATE - INTERVAL ''1 month'') AND imgs.started < DATE_TRUNC(''month'', CURRENT_DATE)';
          ELSE NULL;
        END CASE;
      END IF;
    END IF;

    -- Process/Status Filter
    IF v_filters->>'processStatusFilter' IS NOT NULL THEN
      DECLARE
        v_process_filter JSONB;
        v_has_dose BOOLEAN;
        v_status_values JSONB;
        v_process_where TEXT := '';
      BEGIN
        v_process_filter := v_filters->'processStatusFilter';
        v_has_dose := COALESCE((v_process_filter->>'hasDose')::boolean, false);
        v_status_values := COALESCE(v_process_filter->'statusValues', '[]'::jsonb);

        IF v_has_dose OR jsonb_array_length(v_status_values) > 0 THEN
          v_process_where := ' AND (';

          IF v_has_dose THEN
            v_process_where := v_process_where || 'LOWER(obs.status::text) = ''final''';
          END IF;

          IF jsonb_array_length(v_status_values) > 0 THEN
            IF v_has_dose THEN
              v_process_where := v_process_where || ' OR ';
            END IF;

            v_process_where := v_process_where ||
              'LOWER(determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text))' ||
              ' = ANY(SELECT LOWER(jsonb_array_elements_text(' || quote_literal(v_status_values::text) || '::jsonb)))';
          END IF;

          v_process_where := v_process_where || ')';
          v_where_clause := v_where_clause || v_process_where;
        END IF;
      END;

    -- ΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉ
    -- * MODIFIED: pageSpecificFilters
    -- * Report page with performerId now ALWAYS applies doctor scoping
    -- * regardless of other column filters (name, bookmark, age, sex, etc.)
    -- * All other page types (worklist, dose, generic) keep the original
    -- * v_extra_count = 0 gate behavior.
    -- ΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉ
    ELSEIF v_filters->>'pageSpecificFilters' IS NOT NULL THEN
      DECLARE
        v_pf          JSONB := v_filters->'pageSpecificFilters';
        v_pid         TEXT   := v_pf->>'performerId';
        v_dose        BOOLEAN := COALESCE((v_pf->>'isDosePage')::BOOLEAN, FALSE);
        v_worklist    BOOLEAN := COALESCE((v_pf->>'isWorklistPage')::BOOLEAN, FALSE);
        v_report      BOOLEAN := COALESCE((v_pf->>'isReportPage')::BOOLEAN, FALSE);
        v_admin       BOOLEAN := COALESCE((v_pf->>'isSuperadmin')::BOOLEAN, FALSE);
        v_allproc     BOOLEAN := COALESCE((v_pf->>'hasAllProcessFilter')::BOOLEAN, FALSE);
        v_extra_count INTEGER;
      BEGIN
        SELECT COUNT(*)
          INTO v_extra_count
          FROM jsonb_each(v_filters) AS f(key, val)
         WHERE key NOT IN ('examination','pageSpecificFilters');

        -- [1] Report page with performerId: ALWAYS apply doctor scoping
        --     This runs regardless of v_extra_count, so users can combine
        --     report scoping with any column filter (name, bookmark, age, sex, etc.)
        IF NOT v_admin AND NOT v_allproc AND v_report AND v_pid IS NOT NULL AND v_pid <> '' THEN
          v_where_clause := v_where_clause ||
            ' AND ((dr.performer = ' || quote_literal(v_pid) || ')' ||
            ' OR COALESCE(dr."isAllDoctor", false))' ||
            ' AND LOWER((determine_process_sql(' ||
            'sr.status::text,' ||
            'sr.modality->''coding''->0->>''code'',' ||
            'proc.status::text, imgs.status::text,' ||
            'dr.status::text, obs.status::text' ||
            ')->>''order'')::text) = ''done''' ||
            ' AND LOWER((determine_process_sql(' ||
            'sr.status::text,' ||
            'sr.modality->''coding''->0->>''code'',' ||
            'proc.status::text, imgs.status::text,' ||
            'dr.status::text, obs.status::text' ||
            ')->>''image'')::text) = ''available''' ||
            ' AND COALESCE(LOWER(dr.status::text), '''') != ''final''';

        -- [2] Report page without performerId: ALWAYS apply process scoping
        --     (minus doctor assignment filter)
        ELSIF NOT v_admin AND NOT v_allproc AND v_report THEN
          v_where_clause := v_where_clause ||
            ' AND LOWER((determine_process_sql(' ||
            'sr.status::text,' ||
            'sr.modality->''coding''->0->>''code'',' ||
            'proc.status::text, imgs.status::text,' ||
            'dr.status::text, obs.status::text' ||
            ')->>''order'')::text) = ''done''' ||
            ' AND LOWER((determine_process_sql(' ||
            'sr.status::text,' ||
            'sr.modality->''coding''->0->>''code'',' ||
            'proc.status::text, imgs.status::text,' ||
            'dr.status::text, obs.status::text' ||
            ')->>''image'')::text) = ''available''' ||
            ' AND COALESCE(LOWER(dr.status::text), '''') != ''final''';

        -- [3] All other page types: preserve original v_extra_count = 0 gate
        ELSIF v_extra_count = 0 THEN
          IF NOT v_admin THEN
            IF NOT v_allproc THEN
              IF v_worklist THEN
                v_where_clause := v_where_clause ||
                  ' AND LOWER(determine_status_sql(' ||
                  'sr.status::text, dr.status::text, obs.status::text, ' ||
                  'proc.status::text, imgs.status::text' ||
                  ')) = ANY(ARRAY[''unscheduled'', ''appointed'', ''on-process''])';
              END IF;

              IF v_dose THEN
                v_where_clause := v_where_clause ||
                  ' AND LOWER((determine_process_sql(' ||
                  'sr.status::text,' ||
                  'sr.modality->''coding''->0->>''code'',' ||
                  'proc.status::text, imgs.status::text,' ||
                  'dr.status::text, obs.status::text' ||
                  ')->>''order'')::text) != ''cancel''' ||
                  ' AND LOWER((determine_process_sql(' ||
                  'sr.status::text,' ||
                  'sr.modality->''coding''->0->>''code'',' ||
                  'proc.status::text, imgs.status::text,' ||
                  'dr.status::text, obs.status::text' ||
                  ')->>''image'')::text) = ''available''' ||
                  ' AND COALESCE(LOWER(obs.status::text), '''') != ''final''' ||
                  ' AND NOT (UPPER(sr.modality->''coding''->0->>''code'') = ANY(ARRAY[''MR'', ''US'', ''ECG'']))';
              END IF;

              IF NOT v_report AND NOT v_worklist AND NOT v_dose THEN
                v_where_clause := v_where_clause ||
                  ' AND NOT (' ||
                  'LOWER((determine_process_sql(' ||
                  'sr.status::text,' ||
                  'sr.modality->''coding''->0->>''code'',' ||
                  'proc.status::text, imgs.status::text,' ||
                  'dr.status::text, obs.status::text' ||
                  ')->>''image'')::text) = ''unscheduled''' ||
                  ' OR LOWER((determine_process_sql(' ||
                  'sr.status::text,' ||
                  'sr.modality->''coding''->0->>''code'',' ||
                  'proc.status::text, imgs.status::text,' ||
                  'dr.status::text, obs.status::text' ||
                  ')->>''report'')::text) = ''verified''' ||
                  ' OR LOWER((determine_process_sql(' ||
                  'sr.status::text,' ||
                  'sr.modality->''coding''->0->>''code'',' ||
                  'proc.status::text, imgs.status::text,' ||
                  'dr.status::text, obs.status::text' ||
                  ')->''dose''->>''status'')::text) = ''verified''' ||
                  ')';
              END IF;
            END IF;
          END IF;
        END IF;
      END;
    END IF;

    -- Study history MRN
    IF v_filters->>'studyHistoryBasedOnMRN' IS NOT NULL THEN
      DECLARE
        v_history_filter JSONB;
        v_show_history BOOLEAN;
        v_history_mrn TEXT;
      BEGIN
        v_history_filter := v_filters->'studyHistoryBasedOnMRN';
        v_show_history := COALESCE((v_history_filter->>'showHistory')::boolean, false);
        v_history_mrn := v_history_filter->>'mrn';

        IF v_show_history AND v_history_mrn IS NOT NULL AND v_history_mrn <> '' THEN
          v_where_clause := v_where_clause ||
            ' AND LOWER((SELECT val->>''value'' ' ||
            'FROM jsonb_array_elements(' ||
              'CASE ' ||
                'WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) ' ||
                'WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ' ||
                'ELSE ''[]''::jsonb ' ||
              'END' ||
            ') val ' ||
            'WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' ' ||
            'LIMIT 1)) = LOWER(' || quote_literal(v_history_mrn) || ')';
        END IF;
      END;
    END IF;

    -- Study history accession
    IF v_filters->>'studyHistoryBasedOnAccession' IS NOT NULL THEN
      DECLARE
        v_history_filter JSONB;
        v_show_history BOOLEAN;
        v_history_accession TEXT;
      BEGIN
        v_history_filter := v_filters->'studyHistoryBasedOnAccession';
        v_show_history := COALESCE((v_history_filter->>'showHistory')::boolean, false);
        v_history_accession := v_history_filter->>'accessionNumber';

        IF v_show_history AND v_history_accession IS NOT NULL AND v_history_accession <> '' THEN
          v_where_clause := v_where_clause ||
            ' AND pat.id IN (' ||
            '   SELECT DISTINCT sr_inner.subject ' ||
            '   FROM public."serviceRequest" sr_inner ' ||
            '   WHERE LOWER((SELECT val->>''value'' ' ||
            '     FROM jsonb_array_elements(' ||
            '       CASE ' ||
            '         WHEN jsonb_typeof(sr_inner.identifier) = ''object'' THEN jsonb_build_array(sr_inner.identifier) ' ||
            '         WHEN jsonb_typeof(sr_inner.identifier) = ''array'' THEN sr_inner.identifier ' ||
            '         ELSE ''[]''::jsonb ' ||
            '       END' ||
            '     ) val ' ||
            '     WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' ' ||
            '     LIMIT 1)) = LOWER(' || quote_literal(v_history_accession) || ')' ||
            ' )';
        END IF;
      END;
    END IF;

    -- Report keywords
    IF v_filters->>'reportKeywords' IS NOT NULL THEN
      v_where_clause := v_where_clause ||
        ' AND ( ' ||
          _ilike_predicate('COALESCE(dr.findings, '''')', v_filters->'reportKeywords', FALSE) ||
        ' OR ' ||
          _ilike_predicate('COALESCE(dr.recommendations, '''')', v_filters->'reportKeywords', FALSE) ||
        ' OR ' ||
          _ilike_predicate('COALESCE(dr.conclusion, '''')', v_filters->'reportKeywords', FALSE) ||
        ' )';
    END IF;
  END IF;

  -- Always need read doctor for resultsInterpreter inside report
  v_needs_dr_read_pract := TRUE;
  v_needs_dr := TRUE;

  /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ OPTIMIZED total-count query ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
  v_sql := 'SELECT COUNT(*) FROM public."serviceRequest" sr';

  IF v_needs_patient THEN
    v_sql := v_sql || ' LEFT JOIN public.patient_fhir pat ON sr.subject = pat.id';
  END IF;

  IF v_needs_proc THEN
    v_sql := v_sql || ' LEFT JOIN LATERAL (
      SELECT p.*
      FROM public.procedure p
      WHERE p."basedOn" = sr.id
      ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
      LIMIT 1
    ) proc ON true';
  END IF;

  IF v_needs_proc_radiographers THEN
    v_sql := v_sql || ' LEFT JOIN LATERAL (
      SELECT string_agg(
        format_practitioner_name_sql(pr.name), '', ''
        ORDER BY format_practitioner_name_sql(pr.name)
      ) AS radiographer_names
      FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord)
      JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(val,ord2)
        ON ord = ord2
      JOIN public.practitioner pr
        ON pr.id = split_part(act.val->>''reference'',''/'',2)
      WHERE EXISTS (
        SELECT 1
        FROM jsonb_array_elements(fn.val->''coding'') c
        WHERE c->>''code'' = ''Radiografer''
      )
    ) proc_radiographers ON true';
  END IF;

  IF v_needs_proc_operator THEN
    v_sql := v_sql || ' LEFT JOIN LATERAL (
      SELECT format_practitioner_name_sql(pr.name) AS operator_name
      FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord)
      JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(val,ord2)
        ON ord = ord2
      JOIN public.practitioner pr
        ON pr.id = split_part(act.val->>''reference'',''/'',2)
      WHERE EXISTS (
        SELECT 1
        FROM jsonb_array_elements(fn.val->''coding'') c
        WHERE c->>''code'' = ''Operator''
      )
      LIMIT 1
    ) proc_operator ON true';
  END IF;

  IF v_needs_dr THEN
    v_sql := v_sql || ' LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id';
  END IF;

  IF v_needs_dr_read_pract THEN
    v_sql := v_sql || ' LEFT JOIN public.practitioner dr_read_pract ON dr."resultsInterpreter" = dr_read_pract.id';
  END IF;

  IF v_needs_dr_assigned_pract THEN
    v_sql := v_sql || ' LEFT JOIN public.practitioner dr_assigned_pract ON dr.performer = dr_assigned_pract.id';
  END IF;

  IF v_needs_imgs THEN
    v_sql := v_sql || ' LEFT JOIN public."imagingStudy" imgs ON
      EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(imgs.identifier, ''[]''::jsonb)) img_ident,
             jsonb_array_elements(COALESCE(proc.identifier, ''[]''::jsonb)) proc_ident
        WHERE img_ident->>''system'' = ''http://hospital.smarthealth.org/accession''
          AND proc_ident->>''system'' = ''http://hospital.smarthealth.org/accession''
          AND img_ident->>''value'' = proc_ident->>''value''
      )
      AND imgs.subject = ' || CASE WHEN v_needs_patient THEN 'pat.id' ELSE 'sr.subject' END;
  END IF;

  IF v_needs_obs THEN
    v_sql := v_sql || ' LEFT JOIN public.observation obs ON obs."partOf" = ' ||
      CASE WHEN v_needs_proc THEN 'proc.id' ELSE 'NULL' END;
  END IF;

  IF v_needs_obs_dose_verificator THEN
    v_sql := v_sql || ' LEFT JOIN public.practitioner obs_dose_verificator ON obs.performer = obs_dose_verificator.id';
  END IF;

  v_sql := v_sql || ' WHERE 1=1' || v_where_clause;

  EXECUTE v_sql INTO v_total_count;

  /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ Paginated data query ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
  v_sql := '
    SELECT jsonb_agg(study_data_rows.study_data)
    FROM (
      SELECT jsonb_build_object(
        ''accessionNumber'', sr_acc.accession,
        ''age'', calculate_age_sql(sr."occurrence.dateTime", pat."birthDate"),
        ''assignedDoctor'',
          CASE
            WHEN COALESCE(dr."isAllDoctor", false) THEN ''All Doctor''
            ELSE format_practitioner_name_sql(dr_assigned_pract.name)
          END,
        ''birthDate'', format_date_sql(pat."birthDate", true),
        ''bookmark'', COALESCE(
          (SELECT jsonb_agg(elem->>''valueString'')
           FROM jsonb_array_elements(sr.bookmarks) elem
           WHERE elem->>''url'' = ''tag''),
          ''[]''::jsonb
        ),
        ''cito'', to_jsonb(sr.priority::text = ''stat''),
        ''clinical'', (sr.reason->''coding''->0->>''display''),
        ''comment'', sr.note,
        ''diagnosticReportId'', dr.id,

        ''dose'', CASE
          WHEN obs.id IS NULL THEN ''null''::jsonb
          ELSE jsonb_build_object(
            ''resourceType'', ''Observation'',
            ''id'', obs.id,
            ''partOf'', jsonb_build_array(
              jsonb_build_object(
                ''reference'', ''Procedure/'' || proc.id,
                ''display'', proc_acc.accession
              )
            ),
            ''subject'', jsonb_build_object(''reference'', ''Patient/'' || pat.id),
            ''component'', jsonb_build_array(
              jsonb_build_object(
                ''code'', obs."component.code",
                ''valueQuantity'', obs."component.valueQuantity"
              )
            ),
            ''performer'', jsonb_build_array(
              jsonb_build_object(
                ''reference'', ''Practitioner/'' || COALESCE(obs.performer::text, ''unknown''),
                ''display'', COALESCE(format_practitioner_name_sql(obs_performer.name), '''')
              )
            ),
            ''status'', COALESCE(obs.status::text, ''unknown''),
            ''effectiveDateTime'', COALESCE(obs."effective.dateTime"::text, '''')
          )
        END,

        ''doseVerificator'', COALESCE(format_practitioner_name_sql(obs_dose_verificator.name), ''''),
        ''examImages'', format_date_sql(imgs.started, false),
        ''examRead'', COALESCE(format_date_sql(dr."effective.dateTime", false), ''''),
        ''examRegister'', format_date_sql(proc."performedDateTime", false),
        ''examination'', format_date_sql(sr."occurrence.dateTime", false),
        ''imageCount'', COALESCE(imgs."numberOfInstances", 0),
        ''imagingStudyId'', imgs.id,
        ''insurance'', COALESCE(sr.insurance::text, ''''),
        ''isExported'', COALESCE((sr."isExported")::boolean, false),
        ''modality'', (sr.modality->''coding''->0->>''code''),
        ''mrn'', pat_mrn.mrn,
        ''name'', pat_name.full_name,
        ''observationId'', obs.id,
        ''operator'', COALESCE(proc_operator.operator_name, ''''),
        ''patientId'', pat.id,
        ''picDoctor'', COALESCE(sr."performer.display", ''''),

        ''procedure'', CASE
          WHEN proc.id IS NULL THEN ''null''::jsonb
          ELSE jsonb_build_object(
            ''resourceType'',''Procedure'',
            ''id'', proc.id,
            ''identifier'', COALESCE(proc.identifier,''[]''::jsonb),
            ''basedOn'', jsonb_build_array(
              jsonb_build_object(
                ''reference'', ''ServiceRequest/'' || sr.id,
                ''display'', sr_acc.accession
              )
            ),
            ''status'', COALESCE(proc.status::text,''unknown''),
            ''performedDateTime'', COALESCE(proc."performedDateTime"::text,''''),
            ''performer'', CASE
              WHEN jsonb_array_length(proc."performer.function") = 0 THEN ''[]''::jsonb
              ELSE (
                SELECT jsonb_agg(
                  jsonb_build_object(
                    ''function'', fn.value,
                    ''actor'',   act.value
                  )
                )
                FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(value,ord)
                JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(value,ord2)
                  ON ord = ord2
              )
            END,
            ''location'', jsonb_build_object(
              ''reference'',''Location/''||COALESCE(proc.location::text,''unknown''),
              ''display'',   COALESCE(proc_location.name,'''')
            )
          )
        END,

        ''procedureId'', proc.id,
        ''process'', determine_process_sql(sr.status::text, (sr.modality->''coding''->0->>''code''), proc.status::text, imgs.status::text, dr.status::text, obs.status::text),
        ''radiographer'', COALESCE(proc_radiographers.radiographer_names, ''''),
        ''readDoctor'', COALESCE(format_practitioner_name_sql(dr_read_pract.name), ''''),
        ''referringDoctor'', COALESCE(sr."requester.display", ''''),

        -- Γ£à V4: report.extension includes /critical boolean
        ''report'', CASE
          WHEN dr.id IS NULL THEN ''null''::jsonb
          ELSE jsonb_strip_nulls(
            jsonb_build_object(
              ''resourceType'', ''DiagnosticReport'',
              ''id'', dr.id,
              ''effectiveDateTime'', COALESCE(dr."effective.dateTime"::text, NULL),
              ''conclusion'', NULLIF(dr.conclusion, ''''),
              ''status'', COALESCE(dr.status, ''unknown''),
              ''identifier'', jsonb_build_array(
                jsonb_build_object(
                  ''system'', ''http://example.org/fhir/StructureDefinition/supporting-info'',
                  ''value'', (
                    SELECT val->>''value''
                    FROM jsonb_array_elements(
                      CASE
                        WHEN jsonb_typeof(dr.identifier) = ''object'' THEN jsonb_build_array(dr.identifier)
                        WHEN jsonb_typeof(dr.identifier) = ''array'' THEN dr.identifier
                        ELSE ''[]''::jsonb
                      END
                    ) val
                    WHERE val->>''system'' = ''http://example.org/fhir/StructureDefinition/supporting-info''
                    LIMIT 1
                  )
                )
              ),
              ''basedOn'', jsonb_build_array(
                jsonb_build_object(
                  ''reference'', ''ServiceRequest/'' || sr.id,
                  ''display'', sr_acc.accession
                )
              ),
              ''performer'', jsonb_build_array(
                jsonb_build_object(
                  ''reference'', ''Practitioner/'' || COALESCE(dr.performer::text, ''unknown''),
                  ''display'', COALESCE(format_practitioner_name_sql(dr_assigned_pract.name), '''')
                )
              ),
              ''resultsInterpreter'', CASE
                WHEN dr."resultsInterpreter" IS NOT NULL THEN
                  jsonb_build_array(
                    jsonb_build_object(
                      ''reference'', ''Practitioner/'' || dr."resultsInterpreter"::text,
                      ''display'', COALESCE(format_practitioner_name_sql(dr_read_pract.name), '''')
                    )
                  )
                ELSE ''[]''::jsonb
              END,
              ''extension'', (
                SELECT COALESCE(jsonb_agg(x.ext), ''[]''::jsonb)
                FROM (
                  -- findings
                  SELECT jsonb_build_object(
                    ''url'', ''http://hospital.smarthealth.org/diagnosticreport/findings'',
                    ''valueString'', dr.findings
                  ) AS ext

                  UNION ALL

                  -- recommendation
                  SELECT jsonb_build_object(
                    ''url'', ''http://hospital.smarthealth.org/diagnosticreport/recommendation'',
                    ''valueString'', dr.recommendations
                  )

                  UNION ALL

                  -- isAllDoctor
                  SELECT jsonb_build_object(
                    ''url'', ''http://hospital.smarthealth.org/diagnosticreport/isAllDoctor'',
                    ''valueBoolean'', COALESCE(dr."isAllDoctor", false)
                  )

                  UNION ALL

                  -- Γ£à critical
                  SELECT jsonb_build_object(
                    ''url'', ''http://hospital.smarthealth.org/diagnosticreport/critical'',
                    ''valueBoolean'', COALESCE(dr.critical, false)
                  )
                ) x
              )
            )
          )
        END,

        ''serviceRequest'', jsonb_build_object(
          ''resourceType'', ''ServiceRequest'',
          ''id'', sr.id,
          ''extension'',
            CASE
              WHEN sr.modality IS NOT NULL OR sr.bookmarks IS NOT NULL OR sr."isExported" IS NOT NULL OR sr."locationCode" IS NOT NULL
              THEN (
                SELECT jsonb_agg(ext)
                FROM (
                  SELECT jsonb_build_object(
                    ''url'', ''http://example.org/fhir/StructureDefinition/modality'',
                    ''valueCodeableConcept'', sr.modality
                  ) AS ext
                  WHERE sr.modality IS NOT NULL
                  UNION ALL
                  SELECT jsonb_build_object(
                    ''url'', ''http://example.org/fhir/StructureDefinition/bookmarks''
                  ) ||
                  CASE
                    WHEN jsonb_array_length(COALESCE(sr.bookmarks, ''[]''::jsonb)) > 0
                    THEN jsonb_build_object(''extension'', sr.bookmarks)
                    ELSE ''{}''::jsonb
                  END AS ext
                  WHERE TRUE
                  UNION ALL
                  SELECT jsonb_build_object(
                    ''url'', ''http://example.org/fhir/StructureDefinition/locationCode'',
                    ''valueString'', sr."locationCode"
                  ) AS ext
                  WHERE sr."locationCode" IS NOT NULL AND sr."locationCode" <> ''''
                ) extensions
              )
              ELSE ''[]''::jsonb
            END,
          ''identifier'', COALESCE(
            (SELECT jsonb_agg(val)
             FROM jsonb_array_elements(
               CASE
                 WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier)
                 WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier
                 ELSE ''[]''::jsonb
               END
             ) val),
            ''[]''::jsonb
          ),
          ''status'', COALESCE(sr.status::text, ''unknown''),
          ''priority'', COALESCE(sr.priority::text, ''routine''),
          ''code'', COALESCE(sr.code, ''{}''::jsonb),
          ''subject'', jsonb_build_object(
            ''reference'', ''Patient/'' || pat.id,
            ''display'', COALESCE(
              (SELECT TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', ''''))
               FROM jsonb_array_elements(pat.name) name_parts
               WHERE jsonb_typeof(pat.name) = ''array''
               LIMIT 1),
              ''''
            )
          ),
          ''occurrenceDateTime'', COALESCE(to_char(sr."occurrence.dateTime", ''YYYY-MM-DD"T"HH24:MI:SS''), ''''),
          ''requester'', CASE
            WHEN sr."requester.display" IS NOT NULL AND sr."requester.display" <> ''''
            THEN jsonb_build_object(''display'', sr."requester.display")
            ELSE jsonb_build_object(''display'', '''')
          END,
          ''performer'', CASE
            WHEN sr."performer.display" IS NOT NULL AND sr."performer.display" <> ''''
            THEN jsonb_build_array(jsonb_build_object(''display'', sr."performer.display"))
            ELSE ''[]''::jsonb
          END,
          ''reasonCode'', CASE
            WHEN sr.reason IS NOT NULL THEN jsonb_build_array(sr.reason)
            ELSE ''[]''::jsonb
          END,
          ''insurance'', CASE
            WHEN sr.insurance IS NOT NULL AND sr.insurance::text <> ''''
            THEN jsonb_build_array(jsonb_build_object(''display'', sr.insurance::text))
            ELSE ''[]''::jsonb
          END,
          ''note'', CASE
            WHEN sr.note IS NOT NULL AND sr.note <> ''''
            THEN jsonb_build_array(jsonb_build_object(''text'', sr.note))
            ELSE ''[]''::jsonb
          END
        ),

        ''serviceRequestId'', sr.id,
        ''sex'', CASE pat.gender::text WHEN ''female'' THEN ''F'' WHEN ''male'' THEN ''M'' ELSE ''O'' END,
        ''status'', determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text),
        ''studyImageId'', imgs_studyid.study_id,

        ''studyImages'', CASE
          WHEN imgs.id IS NULL THEN ''null''::jsonb
          ELSE jsonb_build_object(
            ''resourceType'', ''ImagingStudy'',
            ''id'', imgs.id,
            ''identifier'', COALESCE(imgs.identifier, ''[]''::jsonb),
            ''status'', COALESCE(imgs.status::text, ''unknown''),
            ''modality'', jsonb_build_array(
              jsonb_build_object(
                ''code'', COALESCE((imgs.modality->>''code''), (sr.modality->''coding''->0->>''code''))
              )
            ),
            ''subject'', jsonb_build_object(''reference'', ''Patient/'' || pat.id),
            ''started'', COALESCE(imgs.started::text, ''''),
            ''numberOfInstances'', COALESCE(imgs."numberOfInstances", 0)
          )
        END,

        ''studyName'', (sr.code->''coding''->0->>''display''),
        ''ward'', COALESCE(sr."locationCode", '''')
      ) AS study_data
      FROM public."serviceRequest" sr

      LEFT JOIN public.patient_fhir pat ON sr.subject = pat.id

      LEFT JOIN LATERAL (
        SELECT val->>''value'' AS accession
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier)
            WHEN jsonb_typeof(sr.identifier) = ''array''  THEN sr.identifier
            ELSE ''[]''::jsonb
          END
        ) val
        WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession''
        LIMIT 1
      ) sr_acc ON true

      LEFT JOIN LATERAL (
        SELECT val->>''value'' AS mrn
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier)
            WHEN jsonb_typeof(pat.identifier) = ''array''  THEN pat.identifier
            ELSE ''[]''::jsonb
          END
        ) val
        WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn''
        LIMIT 1
      ) pat_mrn ON true

      LEFT JOIN LATERAL (
        SELECT string_agg(
          TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', '''')),
          '', ''
        ) AS full_name
        FROM jsonb_array_elements(pat.name) name_parts
        WHERE jsonb_typeof(pat.name) = ''array'' AND jsonb_array_length(pat.name) > 0
      ) pat_name ON true

      LEFT JOIN LATERAL (
        SELECT p.*
        FROM public.procedure p
        WHERE p."basedOn" = sr.id
        ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
        LIMIT 1
      ) proc ON true

      LEFT JOIN LATERAL (
        SELECT val->>''value'' AS accession
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(proc.identifier) = ''object'' THEN jsonb_build_array(proc.identifier)
            WHEN jsonb_typeof(proc.identifier) = ''array''  THEN proc.identifier
            ELSE ''[]''::jsonb
          END
        ) val
        WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession''
        LIMIT 1
      ) proc_acc ON true

      LEFT JOIN LATERAL (
        SELECT string_agg(format_practitioner_name_sql(pr.name), '', '' ORDER BY format_practitioner_name_sql(pr.name)) AS radiographer_names
        FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord)
        JOIN jsonb_array_elements(proc."performer.actor")    WITH ORDINALITY act(val,ord2)
          ON ord = ord2
        JOIN public.practitioner pr
          ON pr.id = split_part(act.val->>''reference'',''/'',2)
        WHERE EXISTS (
          SELECT 1
          FROM jsonb_array_elements(fn.val->''coding'') c
          WHERE c->>''code'' = ''Radiografer''
        )
      ) proc_radiographers ON true

      LEFT JOIN LATERAL (
        SELECT format_practitioner_name_sql(pr.name) AS operator_name
        FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord)
        JOIN jsonb_array_elements(proc."performer.actor")    WITH ORDINALITY act(val,ord2)
          ON ord = ord2
        JOIN public.practitioner pr
          ON pr.id = split_part(act.val->>''reference'',''/'',2)
        WHERE EXISTS (
          SELECT 1
          FROM jsonb_array_elements(fn.val->''coding'') c
          WHERE c->>''code'' = ''Operator''
        )
        LIMIT 1
      ) proc_operator ON true

      LEFT JOIN public.location_fhir proc_location ON proc.location = proc_location.id

      LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id

      LEFT JOIN LATERAL (
        SELECT val->>''value'' AS accession
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(dr.identifier) = ''object'' THEN jsonb_build_array(dr.identifier)
            WHEN jsonb_typeof(dr.identifier) = ''array''  THEN dr.identifier
            ELSE ''[]''::jsonb
          END
        ) val
        WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession''
        LIMIT 1
      ) dr_acc ON true

      LEFT JOIN public.practitioner dr_read_pract ON dr."resultsInterpreter" = dr_read_pract.id
      LEFT JOIN public.practitioner dr_assigned_pract ON dr.performer = dr_assigned_pract.id

      LEFT JOIN public."imagingStudy" imgs
        ON (
          SELECT v->>''value''
          FROM jsonb_array_elements(COALESCE(imgs.identifier, ''[]''::jsonb)) v
          WHERE v->>''system'' = ''http://hospital.smarthealth.org/accession''
          LIMIT 1
        ) = proc_acc.accession
        AND imgs.subject = pat.id

      LEFT JOIN LATERAL (
        SELECT val->>''value'' AS study_id
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(imgs.identifier) = ''object'' THEN jsonb_build_array(imgs.identifier)
            WHEN jsonb_typeof(imgs.identifier) = ''array''  THEN imgs.identifier
            ELSE ''[]''::jsonb
          END
        ) val
        WHERE val->>''system'' = ''http://hospital.smarthealth.org/study-id''
        LIMIT 1
      ) imgs_studyid ON true

      LEFT JOIN public.observation obs ON obs."partOf" = proc.id
      LEFT JOIN public.practitioner obs_performer ON obs.performer = obs_performer.id
      LEFT JOIN public.practitioner obs_dose_verificator ON obs.performer = obs_dose_verificator.id

      WHERE 1=1' || v_where_clause || '
      ' || v_order_by || '
      LIMIT ' || p_size || ' OFFSET ' || v_offset || '
    ) study_data_rows
  ';

  EXECUTE v_sql INTO result;

  IF result IS NULL THEN
    result := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'rows',       result,
    'totalCount', v_total_count
  );
END;
$function$
