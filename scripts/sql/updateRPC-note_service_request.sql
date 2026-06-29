CREATE OR REPLACE FUNCTION public.search_service_request()
 RETURNS SETOF jsonb
 LANGUAGE sql
 STABLE
AS $$
SELECT jsonb_build_object(
    'resourceType', 'ServiceRequest',
    'id', id,
    'extension', jsonb_build_array(
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/modality',
        'valueCodeableConcept', modality
      ),
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/bookmarks',
        'extension', bookmarks
      ),
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/isExported',
        'valueBoolean', "isExported"
      ),
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/locationCode',
        'valueString', "locationCode"
      )
    ),
    'identifier', identifier,
    'status', status,
    'priority', priority,
    'code', code,
    'subject', jsonb_build_object(
      'reference', 'Patient/' || subject,
      'display', "subject.display"
    ),
    'occurrenceDateTime', "occurrence.dateTime",
    'requester', jsonb_build_object(
      'reference', 'Practitioner/' || requester,
      'display',"requester.display"
    ),
    'performer', jsonb_build_array(jsonb_build_object(
      'reference', 'Practitioner/' || performer,
      'display', "performer.display"
    )),
    'reasonCode', reason,
    'insurance', jsonb_build_array(jsonb_build_object('display', insurance)),
    'note', jsonb_build_array(jsonb_build_object('text', note))
  )
  FROM public."serviceRequest";
$$;


CREATE OR REPLACE FUNCTION public.search_service_request_by_id(request_id text)
 RETURNS SETOF jsonb
 LANGUAGE sql
AS $$
SELECT jsonb_build_object(
    'resourceType', 'ServiceRequest',
    'id', id,
    'extension', jsonb_build_array(
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/modality',
        'valueCodeableConcept', modality
      ),
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/bookmarks',
        'extension', bookmarks
      ),
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/isExported',
        'valueBoolean', "isExported"
      ),
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/locationCode',
        'valueString', "locationCode"
      )
    ),
    'identifier', identifier,
    'status', status,
    'priority', priority,
    'code', code,
    'subject', jsonb_build_object(
      'reference', 'Patient/' || subject,
      'display', "subject.display"
    ),
    'occurrenceDateTime', "occurrence.dateTime",
    'requester', jsonb_build_object(
      'reference', 'Practitioner/' || requester,
      'display', "requester.display"
    ),
    'performer', jsonb_build_array(jsonb_build_object(
      'reference', 'Practitioner/' || performer,
      'display', "performer.display"
    )),
    'reasonCode', reason,
    'insurance', jsonb_build_array(jsonb_build_object('display', insurance)),
    'note', jsonb_build_array(jsonb_build_object('text', note))
)
FROM public."serviceRequest"
WHERE id = request_id;
$$;

CREATE OR REPLACE FUNCTION public.search_service_request_dynamic(search_field text, search_value text)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
AS $$
DECLARE
  field_exists BOOLEAN;
  query_text TEXT;
  result_count INTEGER;
BEGIN
  -- Check if the field exists in the serviceRequest table or is 'occurrence'
  IF lower(search_field) != 'occurrence' THEN
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'serviceRequest'
        AND column_name = lower(search_field)
    ) INTO field_exists;

    -- Return null if field does not exist
    IF NOT field_exists THEN
      RETURN QUERY SELECT NULL::jsonb;
      RETURN;
    END IF;
  END IF;

  -- Build dynamic query
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
        jsonb_build_object(
          ''display'', sr.insurance::text
        )
      ),
      ''note'', jsonb_build_array(
        jsonb_build_object(
          ''text'', sr.note::text
        )
      )
    ) as result
    FROM public."serviceRequest" sr
    WHERE ';

  -- Handle JSONB fields, occurrence, and other fields
  IF lower(search_field) = 'identifier' THEN
    query_text := query_text || '
      identifier IS NOT NULL AND
      CASE 
        WHEN jsonb_typeof(identifier) = ''array'' THEN 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements(identifier) AS elem
            WHERE elem->>''value'' = $1
          )
        ELSE 
          identifier->>''value'' = $1
      END';
  ELSIF lower(search_field) = 'modality' THEN
    query_text := query_text || '
      modality IS NOT NULL AND
      CASE 
        WHEN jsonb_typeof(modality) = ''array'' THEN 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements(modality) AS elem
            WHERE EXISTS (
              SELECT 1
              FROM jsonb_array_elements(elem->''coding'') AS coding
              WHERE coding->>''code'' = $1
            )
          )
        ELSE 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements(modality->''coding'') AS coding
            WHERE coding->>''code'' = $1
          )
      END';
  ELSIF lower(search_field) = 'code' THEN
    query_text := query_text || '
      code IS NOT NULL AND
      CASE 
        WHEN jsonb_typeof(code) = ''array'' THEN 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements(code) AS elem
            WHERE EXISTS (
              SELECT 1
              FROM jsonb_array_elements(elem->''coding'') AS coding
              WHERE coding->>''code'' = $1
            )
          )
        ELSE 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements(code->''coding'') AS coding
            WHERE coding->>''code'' = $1
          )
      END';
  ELSIF lower(search_field) = 'reason' THEN
    query_text := query_text || '
      "reason" IS NOT NULL AND
      CASE 
        WHEN jsonb_typeof("reason") = ''array'' THEN 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements("reason") AS elem
            WHERE EXISTS (
              SELECT 1
              FROM jsonb_array_elements(elem->''coding'') AS coding
              WHERE coding->>''code'' = $1
            )
          )
        ELSE 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements("reason"->''coding'') AS coding
            WHERE coding->>''code'' = $1
          )
      END';
  ELSIF lower(search_field) = 'insurance' THEN
    query_text := query_text || '
      insurance IS NOT NULL AND
      UPPER(insurance::text) = UPPER($1)';
  ELSIF lower(search_field) = 'occurrence' THEN
    query_text := query_text || '
      "occurrence.dateTime" IS NOT NULL AND
      DATE("occurrence.dateTime") = TO_DATE($1, ''YYYY-MM-DD'')';
  ELSE
    query_text := query_text || '
      ' || quote_ident(lower(search_field)) || '::text = $1';
  END IF;

  -- Execute dynamic query and check if any results were found
  RETURN QUERY EXECUTE query_text USING search_value;
  
  -- Check if no rows were returned
  GET DIAGNOSTICS result_count = ROW_COUNT;
  IF result_count = 0 THEN
    RETURN QUERY SELECT NULL::jsonb;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.search_service_request_export(_since date DEFAULT NULL::date, _until date DEFAULT NULL::date)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
AS $$
BEGIN

  -- Return the query result
  RETURN QUERY
SELECT jsonb_build_object(
    'resourceType', 'ServiceRequest',
    'id', id,
    'extension', jsonb_build_array(
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/modality',
        'valueCodeableConcept', modality
      ),
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/bookmarks',
        'extension', bookmarks
      ),
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/isExported',
        'valueBoolean', "isExported"
      ),
      jsonb_build_object(
        'url', 'http://example.org/fhir/StructureDefinition/locationCode',
        'valueString', "locationCode"
      )
    ),
    'identifier', identifier,
    'status', status,
    'priority', priority,
    'code', code,
    'subject', jsonb_build_object(
      'reference', 'Patient/' || subject,
      'display', "subject.display"
    ),
    'occurrenceDateTime', "occurrence.dateTime",
    'requester', jsonb_build_object(
      'reference', 'Practitioner/' || requester,
      'display',"requester.display"
    ),
    'performer', jsonb_build_array(jsonb_build_object(
      'reference', 'Practitioner/' || performer,
      'display', "performer.display"
    )),
    'reasonCode', reason,
    'insurance', jsonb_build_array(jsonb_build_object('display', insurance)),
    'note', jsonb_build_array(jsonb_build_object('text', note))
  )
  FROM public."serviceRequest"
  WHERE updated_at >= _since AND updated_at <= _until;
END;
$$;
