CREATE OR REPLACE FUNCTION public.search_service_request_dynamic(search_field text, search_value text)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
AS $$
DECLARE
  field_exists BOOLEAN;
  query_text TEXT;
  result_count INTEGER;
BEGIN
  IF lower(search_field) != 'occurrence' THEN
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'serviceRequest'
        AND column_name = lower(search_field)
    ) INTO field_exists;

    IF NOT field_exists THEN
      RETURN QUERY SELECT NULL::jsonb;
      RETURN;
    END IF;
  END IF;

  query_text := '
    SELECT jsonb_build_object(
      ''resourceType'', ''ServiceRequest'',
      ''id'', sr.id,
      ''extension'', jsonb_build_array(
        jsonb_build_object(
          ''url'', ''http://example.org/fhir/StructureDefinition/modality'',
          ''valueCodeableConcept'', modality
        ),
        jsonb_build_object(
          ''url'', ''http://example.org/fhir/StructureDefinition/bookmarks'',
          ''extension'', bookmarks
        ),
        jsonb_build_object(
          ''url'', ''http://example.org/fhir/StructureDefinition/isExported'',
          ''valueBoolean'', "isExported"
        ),
        jsonb_build_object(
          ''url'', ''http://example.org/fhir/StructureDefinition/locationCode'',
          ''valueString'', "locationCode"
        ),
        jsonb_build_object(
          ''url'', ''http://example.org/fhir/StructureDefinition/hasStockOpname'',
          ''valueBoolean'', "hasStockOpname"
        )
      ),
      ''identifier'', sr.identifier,
      ''status'', sr.status,
      ''priority'', sr.priority,
      ''code'', sr.code,
      ''subject'', jsonb_build_object(
        ''reference'', ''Patient/'' || sr.subject::text,
        ''display'', sr."subject.display"
      ),
      ''occurrenceDateTime'', sr."occurrence.dateTime",
      ''requester'', jsonb_build_object(
        ''reference'', ''Practitioner/'' || sr.requester::text,
        ''display'', sr."requester.display"
      ),
      ''performer'', jsonb_build_array(
        jsonb_build_object(
          ''reference'', ''Practitioner/'' || sr.performer::text,
          ''display'', sr."performer.display"
        )
      ),
      ''reasonCode'', sr.reason,
      ''insurance'', jsonb_build_array(
        jsonb_build_object(''display'', sr.insurance::text)
      ),
      ''note'', jsonb_build_array(
        jsonb_build_object(''text'', sr.note::text)
      )
    ) as result
    FROM public."serviceRequest" sr
    WHERE ';

  IF lower(search_field) = 'identifier' THEN
    query_text := query_text || '
      identifier IS NOT NULL AND
      CASE
        WHEN jsonb_typeof(identifier) = ''array'' THEN
          EXISTS (SELECT 1 FROM jsonb_array_elements(identifier) AS elem WHERE elem->>''value'' = $1)
        ELSE identifier->>''value'' = $1
      END';
  ELSIF lower(search_field) = 'modality' THEN
    query_text := query_text || '
      modality IS NOT NULL AND
      CASE
        WHEN jsonb_typeof(modality) = ''array'' THEN
          EXISTS (SELECT 1 FROM jsonb_array_elements(modality) AS elem
                  WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(elem->''coding'') AS coding WHERE coding->>''code'' = $1))
        ELSE EXISTS (SELECT 1 FROM jsonb_array_elements(modality->''coding'') AS coding WHERE coding->>''code'' = $1)
      END';
  ELSIF lower(search_field) = 'code' THEN
    query_text := query_text || '
      code IS NOT NULL AND
      CASE
        WHEN jsonb_typeof(code) = ''array'' THEN
          EXISTS (SELECT 1 FROM jsonb_array_elements(code) AS elem
                  WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(elem->''coding'') AS coding WHERE coding->>''code'' = $1))
        ELSE EXISTS (SELECT 1 FROM jsonb_array_elements(code->''coding'') AS coding WHERE coding->>''code'' = $1)
      END';
  ELSIF lower(search_field) = 'reason' THEN
    query_text := query_text || '
      "reason" IS NOT NULL AND
      CASE
        WHEN jsonb_typeof("reason") = ''array'' THEN
          EXISTS (SELECT 1 FROM jsonb_array_elements("reason") AS elem
                  WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(elem->''coding'') AS coding WHERE coding->>''code'' = $1))
        ELSE EXISTS (SELECT 1 FROM jsonb_array_elements("reason"->''coding'') AS coding WHERE coding->>''code'' = $1)
      END';
  ELSIF lower(search_field) = 'insurance' THEN
    query_text := query_text || '
      insurance IS NOT NULL AND UPPER(insurance::text) = UPPER($1)';
  ELSIF lower(search_field) = 'occurrence' THEN
    query_text := query_text || '
      "occurrence.dateTime" IS NOT NULL AND DATE("occurrence.dateTime") = TO_DATE($1, ''YYYY-MM-DD'')';
  ELSE
    query_text := query_text || '
      ' || quote_ident(lower(search_field)) || '::text = $1';
  END IF;

  RETURN QUERY EXECUTE query_text USING search_value;

  GET DIAGNOSTICS result_count = ROW_COUNT;
  IF result_count = 0 THEN
    RETURN QUERY SELECT NULL::jsonb;
  END IF;
END;
$$;
