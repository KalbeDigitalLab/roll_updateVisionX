CREATE OR REPLACE FUNCTION public.create_service_request(payload jsonb) 
 RETURNS text 
 LANGUAGE plpgsql
AS $$
DECLARE
  new_id TEXT := gen_random_uuid()::TEXT;
  performer_value TEXT;
  performer_display TEXT;
  requester_value TEXT;
  requester_display TEXT;
  subject_value TEXT;
  subject_display TEXT;
BEGIN
  -- Extract subject
  IF jsonb_typeof(payload -> 'subject') <> 'object' THEN
    subject_value := NULL;
    subject_display := NULL;
  ELSE
    subject_value := NULLIF(TRIM(split_part(payload -> 'subject' ->> 'reference', '/', 2)), '');
    subject_display := payload -> 'subject' ->> 'display';
  END IF;

  -- Extract requester
  IF jsonb_typeof(payload -> 'requester') <> 'object' THEN
    requester_value := NULL;
    requester_display := NULL;
  ELSE
    requester_value := NULLIF(TRIM(split_part(payload -> 'requester' ->> 'reference', '/', 2)), '');
    requester_display := payload -> 'requester' ->> 'display';
  END IF;

  -- Extract performer
  IF payload -> 'performer' IS NULL OR jsonb_array_length(payload -> 'performer') = 0 THEN
    performer_value := NULL;
    performer_display := NULL;
  ELSE
    performer_value := NULLIF(TRIM(split_part(payload -> 'performer' -> 0 ->> 'reference', '/', 2)), '');
    performer_display := payload -> 'performer' -> 0 ->> 'display';
  END IF;

  INSERT INTO public."serviceRequest" (
    id,
    modality,
    bookmarks,
    "isExported",
    "locationCode",
    "hasStockOpname",
    identifier,
    status,
    code,
    priority,
    subject,
    "occurrence.dateTime",
    requester,
    performer,
    reason,
    insurance,
    note,
    "performer.display",
    "subject.display",
    "requester.display",
    created_at,
    updated_at
  )
  VALUES (
    new_id,
    (SELECT ext -> 'valueCodeableConcept'
     FROM jsonb_path_query(payload -> 'extension', '$[*] ? (@.url == "http://example.org/fhir/StructureDefinition/modality")') ext
     WHERE ext IS NOT NULL LIMIT 1),
    (SELECT ext -> 'extension'
     FROM jsonb_path_query(payload -> 'extension', '$[*] ? (@.url == "http://example.org/fhir/StructureDefinition/bookmarks")') ext
     WHERE ext IS NOT NULL LIMIT 1),
    (SELECT ext -> 'valueBoolean'
     FROM jsonb_path_query(payload -> 'extension', '$[*] ? (@.url == "http://example.org/fhir/StructureDefinition/isExported")') ext
     WHERE ext IS NOT NULL LIMIT 1),
    (SELECT ext ->> 'valueString'
     FROM jsonb_path_query(payload -> 'extension', '$[*] ? (@.url == "http://example.org/fhir/StructureDefinition/locationCode")') ext
     WHERE ext IS NOT NULL LIMIT 1),
    (SELECT (ext ->> 'valueBoolean')::boolean
     FROM jsonb_path_query(payload -> 'extension', '$[*] ? (@.url == "http://example.org/fhir/StructureDefinition/hasStockOpname")') ext
     WHERE ext IS NOT NULL LIMIT 1),
    (SELECT payload -> 'identifier' -> 0
     WHERE payload -> 'identifier' IS NOT NULL LIMIT 1),
    COALESCE((payload ->> 'status')::status, 'active'),
    (SELECT payload -> 'code'
     WHERE payload -> 'code' IS NOT NULL LIMIT 1),
    COALESCE((payload ->> 'priority')::priority, 'routine'),
    subject_value,
    (SELECT (payload ->> 'occurrenceDateTime')::timestamp
     WHERE payload ->> 'occurrenceDateTime' IS NOT NULL),
    requester_value,
    performer_value,
    (SELECT payload -> 'reasonCode' -> 0
     WHERE payload -> 'reasonCode' IS NOT NULL LIMIT 1),
    (SELECT payload -> 'insurance' -> 0 ->> 'display'
     WHERE payload -> 'insurance' IS NOT NULL LIMIT 1),
    (SELECT (payload -> 'note' -> 0 ->> 'text')::TEXT
     WHERE payload -> 'note' IS NOT NULL LIMIT 1),
    performer_display,
    subject_display,
    requester_display,
    now(),
    now()
  );

  PERFORM public.sync_identifier_index(
    'service_request_identifier_index',
    'service_request_id',
    new_id,
    payload -> 'identifier'
  );

  RETURN new_id;
END;
$$;
