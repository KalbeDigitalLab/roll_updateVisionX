DROP FUNCTION IF EXISTS public.get_practitioners(
  text,
  text,
  integer,
  integer
);

CREATE OR REPLACE FUNCTION public.get_practitioners(
  p_name text DEFAULT NULL,
  p_role text DEFAULT NULL,
  p_active boolean DEFAULT NULL,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE sql
AS $$
WITH filtered AS (
  SELECT
    id,
    practitioner_role,
    optional_1, optional_2, optional_3, signature,
    active,
    name
  FROM public.practitioner
  WHERE
    ( p_name IS NULL OR p_name = ''
      OR lower(
           coalesce(name->0->'given'->>0,'')
         || ' '
         || coalesce(name->0->>'family','')
        ) LIKE concat('%', lower(p_name), '%')
    )
    AND
    ( p_role IS NULL OR p_role = ''
      OR lower(practitioner_role->>'display')
         LIKE concat('%', lower(p_role), '%')
    )
    AND
    ( p_active IS NULL
      OR active = p_active
    )
),
total_count AS (
  SELECT COUNT(*)::INT as total FROM filtered
),
page_items AS (
  SELECT
    jsonb_build_object(
      'resourceType','Practitioner',
      'id',           id,
      'extension',    jsonb_build_array(
                        jsonb_build_object(
                          'url','http://example.org/fhir/StructureDefinition/practitioner-role',
                          'valueCoding', practitioner_role
                        ),
                        jsonb_build_object(
                          'url','http://example.org/fhir/StructureDefinition/optional-1',
                          'valueString', optional_1
                        ),
                        jsonb_build_object(
                          'url','http://example.org/fhir/StructureDefinition/optional-2',
                          'valueString', optional_2
                        ),
                        jsonb_build_object(
                          'url','http://example.org/fhir/StructureDefinition/optional-3',
                          'valueString', optional_3
                        ),
                        jsonb_build_object(
                          'url','http://hospital.smarthealth.org/signature',
                          'valueString', signature
                        )
                      ),
      'active',       active,
      'name',         name
    ) AS practitioner
  FROM filtered
  ORDER BY id
  LIMIT p_limit
  OFFSET p_offset
)
SELECT jsonb_build_object(
  'items', COALESCE((SELECT jsonb_agg(practitioner) FROM page_items), '[]'::jsonb),
  'total', (SELECT total FROM total_count),
  'hasMore', (SELECT total FROM total_count) > (p_offset + p_limit)
);
$$;
