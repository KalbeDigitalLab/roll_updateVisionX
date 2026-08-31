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
    IF strpos(v_def, $$END IF;

    IF v_filters->>'pageSpecificFilters' IS NOT NULL THEN$$) > 0 THEN
      RAISE NOTICE 'fast_fetch_studies_paginated_filter_v6 already enforces additive report-page scope';
      RETURN;
    END IF;

    RAISE EXCEPTION 'Unable to patch fast_fetch_studies_paginated_filter_v6 for additive report-page scope automatically';
  END IF;

  EXECUTE v_updated;
END
$migration$;
