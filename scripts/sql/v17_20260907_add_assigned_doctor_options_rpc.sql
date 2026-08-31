CREATE OR REPLACE FUNCTION public.get_assigned_doctors(
  p_name text DEFAULT NULL::text,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_report_filter jsonb DEFAULT NULL::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN (
    WITH filtered_reports AS (
      SELECT dr.*
      FROM public."diagnosticReport" dr
      WHERE
        p_report_filter IS NULL
        OR COALESCE((p_report_filter->>'p_is_report_page')::boolean, false) = false
        OR COALESCE(dr."isAllDoctor", false)
        OR dr.performer = (p_report_filter->>'p_performer_id')
    ),
    assigned_doctor_data AS (
      SELECT DISTINCT 'All Doctor' AS assigned_doctor_name
      FROM filtered_reports dr
      WHERE COALESCE(dr."isAllDoctor", false)

      UNION

      SELECT DISTINCT format_practitioner_name_sql(pr.name) AS assigned_doctor_name
      FROM filtered_reports dr
      JOIN public.practitioner pr ON dr.performer = pr.id
      WHERE dr.performer IS NOT NULL
        AND pr.name IS NOT NULL
        AND COALESCE(dr."isAllDoctor", false) = false
    ),
    filtered_data AS (
      SELECT assigned_doctor_name
      FROM assigned_doctor_data
      WHERE assigned_doctor_name IS NOT NULL
        AND assigned_doctor_name <> ''
        AND (
          p_name IS NULL
          OR p_name = ''
          OR LOWER(assigned_doctor_name) LIKE '%' || LOWER(p_name) || '%'
        )
    ),
    total_count AS (
      SELECT COUNT(*)::int AS total
      FROM filtered_data
    ),
    page_items AS (
      SELECT jsonb_build_object('display', assigned_doctor_name) AS assigned_doctor_item
      FROM filtered_data
      ORDER BY
        CASE WHEN assigned_doctor_name = 'All Doctor' THEN 0 ELSE 1 END,
        assigned_doctor_name
      LIMIT p_limit
      OFFSET p_offset
    )
    SELECT jsonb_build_object(
      'items', COALESCE((SELECT jsonb_agg(assigned_doctor_item) FROM page_items), '[]'::jsonb),
      'total', (SELECT total FROM total_count),
      'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
    )
  );
END;
$function$;
