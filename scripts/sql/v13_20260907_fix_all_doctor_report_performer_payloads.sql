DO $$
DECLARE
  v_def text;
  v_old_v6 text := $old$
              ''performer'', jsonb_build_array(
                jsonb_build_object(
                  ''reference'', ''Practitioner/'' || COALESCE(dr.performer::text, ''unknown''),
                  ''display'', COALESCE(format_practitioner_name_sql(dr_assigned_pract.name), '''')
                )
              ),
$old$;
  v_new_v6 text := $new$
              ''performer'', CASE
                WHEN COALESCE(dr."isAllDoctor", false) OR dr.performer IS NULL THEN ''[]''::jsonb
                ELSE jsonb_build_array(
                  jsonb_build_object(
                    ''reference'', ''Practitioner/'' || dr.performer::text,
                    ''display'', COALESCE(format_practitioner_name_sql(dr_assigned_pract.name), '''')
                  )
                )
              END,
$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.fast_fetch_studies_paginated_filter_v6(jsonb,jsonb,integer,integer)'::regprocedure),
    E'\r\n',
    E'\n'
  );

  IF strpos(v_def, v_old_v6) = 0 THEN
    RAISE EXCEPTION 'Expected v6 DiagnosticReport performer snippet was not found';
  END IF;

  EXECUTE replace(v_def, v_old_v6, v_new_v6);
END $$;
