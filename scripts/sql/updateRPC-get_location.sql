DROP FUNCTION IF EXISTS public.get_locations(
  text,
  text,
  integer,
  integer
);

CREATE OR REPLACE FUNCTION public.get_locations(p_name text DEFAULT NULL::text, p_limit integer DEFAULT 10, p_offset integer DEFAULT 0, p_modalities text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$BEGIN
  RETURN (
    WITH filtered AS (
      SELECT
        lf.id,
        lf.name,
        lf.status::text AS status,
        lf.ae_title,
        lf.location_modality
      FROM public."location_fhir" lf 
      WHERE
        lf.status = 'active' AND
        -- Filter by modalities array if provided
        (p_modalities IS NULL OR array_length(p_modalities, 1) IS NULL OR 
         EXISTS (
           SELECT 1 
           FROM unnest(p_modalities) AS mod
           WHERE lf.location_modality::text ILIKE concat('%', mod, '%')
         )) AND
        -- Filter by name if provided
        (p_name IS NULL OR p_name = '' OR 
         lower(lf.name) LIKE concat('%', lower(p_name), '%'))
    ),
    total_count AS (
      SELECT COUNT(*)::INT AS total FROM filtered
    ),
    page_items AS (
      SELECT
        jsonb_build_object(
          'resourceType', 'Location',
          'id',           id,
          'status',       status, 
          'name',         name,   
          'type',         'ward',
          'aeTitle',      ae_title,
          'modality',     location_modality
        ) AS location
      FROM filtered
      ORDER BY name NULLS LAST, id
      LIMIT p_limit
      OFFSET p_offset
    )
    SELECT jsonb_build_object(
      'items', COALESCE((SELECT jsonb_agg(location) FROM page_items), '[]'::jsonb),
      'total', (SELECT total FROM total_count),
      'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
    )
  );
END;$function$
