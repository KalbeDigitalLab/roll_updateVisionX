DO $migration$
DECLARE
  v_def text;
  v_updated text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.fast_fetch_studies_paginated_filter_v6(jsonb,jsonb,integer,integer)'::regprocedure),
    E'\r\n',
    E'\n'
  );

  v_updated := v_def;

  IF strpos(v_updated, $$v_filters->>'assignedDoctor' IS NOT NULL OR$$) = 0 THEN
    v_updated := regexp_replace(
      v_updated,
      $$IF v_filters->>'readDoctor' IS NOT NULL OR\s+v_filters->>'status' IS NOT NULL OR$$,
      $$IF v_filters->>'readDoctor' IS NOT NULL OR
     v_filters->>'assignedDoctor' IS NOT NULL OR
     v_filters->>'status' IS NOT NULL OR$$
    );
  END IF;

  IF strpos(v_updated, $$IF v_filters->>'assignedDoctor' IS NOT NULL THEN
    v_needs_dr_assigned_pract := TRUE;
    v_needs_dr := TRUE;
  END IF;$$) = 0 THEN
    v_updated := regexp_replace(
      v_updated,
      $$IF v_filters->>'readDoctor' IS NOT NULL THEN\s+v_needs_dr_read_pract := TRUE;\s+v_needs_dr := TRUE;\s+END IF;$$,
      $$IF v_filters->>'readDoctor' IS NOT NULL THEN
    v_needs_dr_read_pract := TRUE;
    v_needs_dr := TRUE;
  END IF;

  IF v_filters->>'assignedDoctor' IS NOT NULL THEN
    v_needs_dr_assigned_pract := TRUE;
    v_needs_dr := TRUE;
  END IF;$$
    );
  END IF;

  IF strpos(v_updated, $$v_filters->'assignedDoctor'$$) = 0 THEN
    v_updated := regexp_replace(
      v_updated,
      $$IF v_filters->>'readDoctor' IS NOT NULL THEN\s+v_where_clause := v_where_clause \|\| ' AND ' \|\|\s+_ilike_predicate\('format_practitioner_name_sql\(dr_read_pract\.name\)', v_filters->'readDoctor', FALSE\);\s+END IF;$$,
      $$IF v_filters->>'readDoctor' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate('format_practitioner_name_sql(dr_read_pract.name)', v_filters->'readDoctor', FALSE);
    END IF;

    IF v_filters->>'assignedDoctor' IS NOT NULL THEN
      v_where_clause := v_where_clause || ' AND ' ||
        _ilike_predicate(
          'CASE WHEN COALESCE(dr."isAllDoctor", false) THEN ''All Doctor'' ELSE format_practitioner_name_sql(dr_assigned_pract.name) END',
          v_filters->'assignedDoctor',
          FALSE
        );
    END IF;$$
    );
  END IF;

  IF strpos(v_updated, $$END IF;

    IF v_filters->>'pageSpecificFilters' IS NOT NULL THEN$$) = 0 THEN
    v_updated := regexp_replace(
      v_updated,
      $$ELSEIF v_filters->>'pageSpecificFilters' IS NOT NULL THEN$$,
      $$END IF;

    IF v_filters->>'pageSpecificFilters' IS NOT NULL THEN$$
    );
  END IF;

  IF v_updated = v_def THEN
    IF strpos(v_def, $$v_filters->>'assignedDoctor' IS NOT NULL OR$$) > 0
       AND strpos(v_def, $$v_filters->'assignedDoctor'$$) > 0
       AND strpos(v_def, $$END IF;

    IF v_filters->>'pageSpecificFilters' IS NOT NULL THEN$$) > 0 THEN
      RAISE NOTICE 'fast_fetch_studies_paginated_filter_v6 already supports assignedDoctor filtering and additive report-page scope';
      RETURN;
    END IF;

    RAISE EXCEPTION 'Unable to patch fast_fetch_studies_paginated_filter_v6 for assignedDoctor filtering and additive report-page scope automatically';
  END IF;

  EXECUTE v_updated;
END
$migration$;
