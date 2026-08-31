-- ============================================================
-- Migration: include read doctors in report-page scope
--
-- Report-page filtering is additive with process filters, but the
-- doctor scope only checked diagnosticReport.performer. Verified
-- reports store the verifying/read doctor in resultsInterpreter, so
-- a doctor who verified a report could lose the row when filtering
-- for Report Verified if they were not also the assigned performer.
-- ============================================================

DO $migration$
DECLARE
  v_def text;
  v_updated text;
  v_old_scope text := $old$' AND ((dr.performer = ' || quote_literal(v_pid) || ')' ||
            ' OR COALESCE(dr."isAllDoctor", false))' ||$old$;
  v_new_scope text := $new$' AND ((dr.performer = ' || quote_literal(v_pid) || ')' ||
            ' OR (dr."resultsInterpreter" = ' || quote_literal(v_pid) || ')' ||
            ' OR COALESCE(dr."isAllDoctor", false))' ||$new$;
  v_old_scope_tail text := $old$' OR COALESCE(dr."isAllDoctor", false))' ||$old$;
  v_new_scope_tail text := $new$' OR (dr."resultsInterpreter" = ' || quote_literal(v_pid) || ')' ||
            ' OR COALESCE(dr."isAllDoctor", false))' ||$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.fast_fetch_studies_paginated_filter_v6(jsonb,jsonb,integer,integer)'::regprocedure),
    E'\r\n',
    E'\n'
  );

  v_updated := v_def;

  -- Keep this migration robust if the additive page-scope patch has not run yet.
  IF strpos(v_updated, $$END IF;

    IF v_filters->>'pageSpecificFilters' IS NOT NULL THEN$$) = 0 THEN
    v_updated := replace(
      v_updated,
      $$ELSEIF v_filters->>'pageSpecificFilters' IS NOT NULL THEN$$,
      $$END IF;

    IF v_filters->>'pageSpecificFilters' IS NOT NULL THEN$$
    );
  END IF;

  IF strpos(v_updated, $$OR (dr."resultsInterpreter" = ' || quote_literal(v_pid) || ')'$$) = 0 THEN
    v_updated := replace(v_updated, v_old_scope, v_new_scope);
  END IF;

  -- Deployed function definitions can differ in whitespace after earlier
  -- patch migrations. Fall back to replacing the stable scope tail.
  IF strpos(v_updated, $$OR (dr."resultsInterpreter" = ' || quote_literal(v_pid) || ')'$$) = 0 THEN
    v_updated := replace(v_updated, v_old_scope_tail, v_new_scope_tail);
  END IF;

  IF strpos(v_updated, $$OR (dr."resultsInterpreter" = ' || quote_literal(v_pid) || ')'$$) = 0 THEN
    v_updated := regexp_replace(
      v_updated,
      $regex$'\s+OR\s+COALESCE\(dr\."isAllDoctor",\s*false\)\)'\s*\|\|$regex$,
      v_new_scope_tail
    );
  END IF;

  -- Preserve the verified-report fix if this runs against an older function body.
  v_updated := replace(
    v_updated,
    $find$            ' AND COALESCE(LOWER(dr.status::text), '''') != ''final''';$find$,
    $replace$            '';$replace$
  );

  IF strpos(v_updated, $$OR (dr."resultsInterpreter" = ' || quote_literal(v_pid) || ')'$$) = 0 THEN
    RAISE EXCEPTION 'Unable to patch fast_fetch_studies_paginated_filter_v6 for read-doctor report-page scope automatically';
  END IF;

  IF v_updated = v_def THEN
    RAISE NOTICE 'fast_fetch_studies_paginated_filter_v6 already includes read doctors in report-page scope';
    RETURN;
  END IF;

  EXECUTE v_updated;
END
$migration$;
