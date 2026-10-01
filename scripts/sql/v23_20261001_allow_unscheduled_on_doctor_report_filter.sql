-- Let doctors filter the report page to unscheduled studies. An unscheduled
-- study may have no DiagnosticReport yet, so it cannot satisfy the usual
-- performer or Done/Available checks. Keep the existing checks for other rows.
DO $migration$
DECLARE
  v_def text;
  v_updated text;
  v_anchor text := $$        IF NOT v_admin AND NOT v_allproc AND v_report AND v_pid IS NOT NULL AND v_pid <> '' THEN$$;
  v_new_branch text := $branch$        IF NOT v_admin AND NOT v_allproc AND v_report
           AND EXISTS (
             SELECT 1
             FROM jsonb_array_elements_text(
               COALESCE(v_filters->'processStatusFilter'->'statusValues', '[]'::jsonb)
             ) AS status_value
             WHERE lower(status_value) = 'unscheduled'
           ) THEN
          -- Unscheduled studies are available to every doctor, even before
          -- a DiagnosticReport exists. Other selected statuses retain the
          -- existing doctor and Ready-to-Report restrictions.
          v_where_clause := v_where_clause ||
            ' AND (' ||
            'LOWER(determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text)) = ''unscheduled''' ||
            ' OR (' ||
            CASE
              WHEN v_pid IS NOT NULL AND v_pid <> '' THEN
                '((dr.performer = ' || quote_literal(v_pid) || ')' ||
                ' OR (dr."resultsInterpreter" = ' || quote_literal(v_pid) || ')' ||
                ' OR COALESCE(dr."isAllDoctor", false)) AND '
              ELSE ''
            END ||
            'LOWER((determine_process_sql(' ||
            'sr.status::text, sr.modality->''coding''->0->>''code'',' ||
            'proc.status::text, imgs.status::text, dr.status::text, obs.status::text' ||
            ')->>''order'')::text) = ''done''' ||
            ' AND LOWER((determine_process_sql(' ||
            'sr.status::text, sr.modality->''coding''->0->>''code'',' ||
            'proc.status::text, imgs.status::text, dr.status::text, obs.status::text' ||
            ')->>''image'')::text) = ''available''' ||
            '))';

        ELSIF NOT v_admin AND NOT v_allproc AND v_report AND v_pid IS NOT NULL AND v_pid <> '' THEN$branch$;
BEGIN
  v_def := pg_get_functiondef('public.fast_fetch_studies_paginated_filter_v6(jsonb,jsonb,integer,integer)'::regprocedure);

  IF strpos(v_def, v_anchor) = 0 OR
     strpos(v_def, $$OR (dr."resultsInterpreter" = ' || quote_literal(v_pid) || ')'$$) = 0 THEN
    RAISE EXCEPTION 'Unexpected fast_fetch_studies_paginated_filter_v6 definition; review migration before applying';
  END IF;

  v_updated := replace(v_def, v_anchor, v_new_branch);
  IF v_updated = v_def THEN
    RAISE EXCEPTION 'Unable to add unscheduled report-page scope';
  END IF;

  EXECUTE v_updated;
END
$migration$;
