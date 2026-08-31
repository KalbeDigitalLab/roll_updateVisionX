-- ============================================================
-- Migration: restore default report-page view hiding verified reports
--
-- v13 removed the "!= 'final'" exclusion from the report-page
-- doctor-scope branch so the explicit "Report Verified" process
-- filter would show verified reports. Since v19 made that branch
-- run additively (no longer gated behind ELSEIF), it also runs for
-- the default report view (no processStatusFilter selected), so a
-- dokter's own just-verified reports stopped disappearing from the
-- default "report not yet available" view.
--
-- Restore the exclusion, but only when no processStatusFilter is
-- present (default view). When a process filter is explicitly
-- selected (e.g. "Report Verified"), keep showing verified reports.
--
-- Anchor/replacement text is built via explicit E'\n' concatenation
-- (rather than literal embedded newlines in dollar-quoted strings)
-- so matching is immune to CRLF vs LF differences between how this
-- migration file is stored and how pg_get_functiondef renders the
-- live function body.
-- ============================================================
 
DO $migration$
DECLARE
  v_def text;
  v_updated text;
  v_anchor text;
  v_replacement text;
  v_marker text := $marker$WHEN v_filters->>'processStatusFilter' IS NULL$marker$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.fast_fetch_studies_paginated_filter_v6(jsonb,jsonb,integer,integer)'::regprocedure),
    E'\r\n',
    E'\n'
  );
 
  v_anchor :=
    $l1$            ')->>''image'')::text) = ''available''' ||$l1$ || E'\n' ||
    $l2$            '';$l2$;
 
  v_replacement :=
    $l1$            ')->>''image'')::text) = ''available''' ||$l1$ || E'\n' ||
    $l2$            CASE$l2$ || E'\n' ||
    $l3$              WHEN v_filters->>'processStatusFilter' IS NULL$l3$ || E'\n' ||
    $l4$                THEN ' AND COALESCE(LOWER(dr.status::text), '''') != ''final'''$l4$ || E'\n' ||
    $l5$              ELSE ''$l5$ || E'\n' ||
    $l6$            END;$l6$;
 
  IF strpos(v_def, v_marker) > 0 THEN
    RAISE NOTICE 'fast_fetch_studies_paginated_filter_v6 already restores default report-page view exclusion';
    RETURN;
  END IF;
 
  IF strpos(v_def, v_anchor) = 0 THEN
    RAISE EXCEPTION 'Unable to patch fast_fetch_studies_paginated_filter_v6 for default report-page view exclusion automatically';
  END IF;
 
  v_updated := replace(v_def, v_anchor, v_replacement);
 
  EXECUTE v_updated;
END
$migration$;
 