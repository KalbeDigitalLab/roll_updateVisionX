CREATE OR REPLACE FUNCTION public.search_locations_export(_since date DEFAULT NULL::date, _until date DEFAULT NULL::date)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
AS $function$BEGIN



  -- Return the query result

  RETURN QUERY

SELECT jsonb_build_object(

    'resourceType', 'Location',

    'id', id,

    'status', status,

    'name', name,

    'type', type,

    'extension',

      -- Conditionally build an array for the modality extension

      (CASE

        WHEN location_modality IS NOT NULL THEN

          jsonb_build_array(

            jsonb_build_object(

              'url', 'http://example.org/fhir/StructureDefinition/location-modality',

              'valueCodeableConcept', location_modality

            )

          )

        ELSE '[]'::jsonb

      END)

      -- Concatenate (||) it with the array for the ae_title extension

      ||

      (CASE

        WHEN ae_title IS NOT NULL THEN

          jsonb_build_array(

            jsonb_build_object(

              'url', 'http://example.org/fhir/StructureDefinition/ae-title',

              'valueString', ae_title

            )

          )

        ELSE '[]'::jsonb

      END)

  )

  FROM public."location_fhir"

  WHERE updated_at >= _since AND updated_at <= _until;

END;$function$
