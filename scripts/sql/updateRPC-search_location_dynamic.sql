CREATE OR REPLACE FUNCTION public.search_location_dynamic(search_field text, search_value text)
 RETURNS TABLE(result jsonb)
 LANGUAGE plpgsql
AS $function$DECLARE

  field_exists BOOLEAN;

  query_text TEXT;

  result_count INTEGER;

BEGIN

  -- Check if the field exists in the location_fhir table

  SELECT EXISTS (

    SELECT 1

    FROM information_schema.columns

    WHERE table_schema = 'public'

      AND table_name = 'location_fhir'

      AND column_name = lower(search_field)

  ) INTO field_exists;



  -- Return null if field does not exist (except for 'type')

  IF NOT field_exists AND lower(search_field) != 'type' THEN

    RETURN QUERY SELECT NULL::jsonb;

    RETURN;

  END IF;



  -- Build dynamic query

  query_text := '

    SELECT jsonb_build_object(

      ''resourceType'', ''Location'',

      ''id'', id,

      ''status'', status,

      ''name'', name,

      ''type'', type,

      ''extension'',

        (CASE

          WHEN location_modality IS NOT NULL THEN

            jsonb_build_array(

              jsonb_build_object(

                ''url'', ''http://example.org/fhir/StructureDefinition/location-modality'',

                ''valueCodeableConcept'', location_modality

              )

            )

          ELSE ''[]''::jsonb

        END)

        ||

        (CASE

          WHEN ae_title IS NOT NULL THEN

            jsonb_build_array(

              jsonb_build_object(

                ''url'', ''http://example.org/fhir/StructureDefinition/ae-title'',

                ''valueString'', ae_title

              )

            )

          ELSE ''[]''::jsonb

        END)

    )

    FROM public.location_fhir

    WHERE ';



  -- Handle JSONB type field

  IF lower(search_field) = 'type' THEN

    -- Search within type.coding[].code

    query_text := query_text || '

      type IS NOT NULL AND EXISTS (

        SELECT 1

        FROM jsonb_array_elements(type->''coding'') AS coding

        WHERE coding->>''code'' = $1

      )';

  ELSE

    -- For other fields, use ILIKE for case-insensitive search

    query_text := query_text || quote_ident(lower(search_field)) || '::text ILIKE ''%'' || $1 || ''%''';

  END IF;



  -- Log the query for debugging

  RAISE NOTICE 'Executing query: % with value: %', query_text, search_value;



  -- Execute dynamic query and check if any results were found

  RETURN QUERY EXECUTE query_text USING search_value;



  -- Check if no rows were returned

  GET DIAGNOSTICS result_count = ROW_COUNT;

  IF result_count = 0 THEN

    RETURN QUERY SELECT NULL::jsonb;

  END IF;

EXCEPTION

  WHEN OTHERS THEN

    -- Log error and return null

    RAISE NOTICE 'Error in search_location_dynamic: %', SQLERRM;

    RETURN QUERY SELECT NULL::jsonb;

END;$function$
