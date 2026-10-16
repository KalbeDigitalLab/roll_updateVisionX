-- ============================================================
-- Migration: sync report-page scope into column filter option RPCs
--
-- The report page's column-header search dropdowns (MRN, name, ...)
-- load their options from get_* RPCs that carry their own copy of the
-- report-page doctor scope. v13/v19/v20/v21 only updated the study
-- table RPC (fast_fetch_studies_paginated_filter_v6), so those copies
-- drifted and a row visible in the table could not be found by its
-- MRN/name in the dropdown:
--   1. they always excluded verified (final) reports, while the table
--      only hides them in the default view (v21) and shows them once a
--      process filter such as Report Verified is selected;
--   2. they only matched dr.performer, not the read doctor
--      dr."resultsInterpreter" (v20);
--   3. they kept the doctor scope when "All Process" is selected,
--      where the table drops it (hasAllProcessFilter).
--
-- The app now sends p_has_process_filter / p_has_all_process_filter in
-- p_report_filter (FetchColumnOptions.ts buildReportFilter). These
-- function bodies only exist in the database, so each one is patched in
-- place like v19-v21 patch fast_fetch_studies_paginated_filter_v6.
-- Any report-scoped body that does not match the expected shape aborts
-- the whole migration, so nothing is partially applied.
-- ============================================================

DO $migration$
DECLARE
  v_fn text;
  v_proc regprocedure;
  v_def text;
  v_updated text;
  v_hides_final boolean;
  v_unpatched text[] := ARRAY[]::text[];
  v_functions text[] := ARRAY[
    'get_bookmarks', 'get_mrns', 'get_names', 'get_birthdate', 'get_modalities',
    'get_study_names', 'get_clinical', 'get_comments', 'get_insurance', 'get_pic_doctor',
    'get_referring_doctor', 'get_read_doctors', 'get_assigned_doctors',
    'get_accession_numbers', 'get_radiographers', 'get_operators', 'get_dose_verificators'
  ];
BEGIN
  FOREACH v_fn IN ARRAY v_functions LOOP
    v_proc := to_regprocedure('public.' || v_fn || '(text,integer,integer,jsonb)');

    IF v_proc IS NULL THEN
      RAISE NOTICE '%(text,integer,integer,jsonb) not found, skipping', v_fn;
      CONTINUE;
    END IF;

    v_def := replace(pg_get_functiondef(v_proc), E'\r\n', E'\n');

    IF strpos(v_def, 'p_is_report_page') = 0 THEN
      RAISE NOTICE '% has no report-page scope, skipping', v_fn;
      CONTINUE;
    END IF;

    v_updated := v_def;
    v_hides_final := v_def ~ $re$AND\s+COALESCE\(LOWER\(dr\.status::text\),\s*''\)\s*(!=|<>)\s*'final'$re$;

    -- 1. Read doctor (v20): match resultsInterpreter alongside performer.
    v_updated := regexp_replace(
      v_updated,
      $re$dr\.performer\s*=\s*(v_performer_id|\(p_report_filter->>'p_performer_id'\))(?!\s+OR\s+dr\."resultsInterpreter")$re$,
      $rep$(dr.performer = \1 OR dr."resultsInterpreter" = \1)$rep$,
      'g'
    );

    -- 2. Verified reports (v21): hide them only in the default view.
    v_updated := regexp_replace(
      v_updated,
      $re$AND\s+COALESCE\(LOWER\(dr\.status::text\),\s*''\)\s*(!=|<>)\s*'final'$re$,
      $rep$AND (COALESCE((p_report_filter->>'p_has_process_filter')::boolean, false) OR COALESCE(LOWER(dr.status::text), '') != 'final')$rep$,
      'g'
    );

    -- 3. All Process (hasAllProcessFilter): drop the doctor scope.
    v_updated := regexp_replace(
      v_updated,
      $re$IF\s+v_is_report_page\s+AND(?!\s+NOT\s+COALESCE\(\(p_report_filter->>'p_has_all_process_filter'\))$re$,
      $rep$IF v_is_report_page AND NOT COALESCE((p_report_filter->>'p_has_all_process_filter')::boolean, false) AND$rep$,
      'g'
    );
    -- get_assigned_doctors (v17) builds its scope as an OR list instead.
    v_updated := regexp_replace(
      v_updated,
      $re$(OR\s+COALESCE\(\(p_report_filter->>'p_is_report_page'\)::boolean,\s*false\)\s*=\s*false)(?!\s+OR\s+COALESCE\(\(p_report_filter->>'p_has_all_process_filter'\))$re$,
      $rep$\1
        OR COALESCE((p_report_filter->>'p_has_all_process_filter')::boolean, false)$rep$,
      'g'
    );

    IF strpos(v_updated, 'OR dr."resultsInterpreter" = ') = 0
       OR strpos(v_updated, 'p_has_all_process_filter') = 0
       OR (v_hides_final AND strpos(v_updated, 'p_has_process_filter') = 0) THEN
      v_unpatched := v_unpatched || v_fn;
      CONTINUE;
    END IF;

    IF v_updated = v_def THEN
      RAISE NOTICE '% already matches the study table report-page scope', v_fn;
      CONTINUE;
    END IF;

    EXECUTE v_updated;
    RAISE NOTICE '% patched', v_fn;
  END LOOP;

  IF array_length(v_unpatched, 1) > 0 THEN
    RAISE EXCEPTION 'Unexpected report-page scope in %; review these function bodies before applying',
      array_to_string(v_unpatched, ', ');
  END IF;
END
$migration$;
