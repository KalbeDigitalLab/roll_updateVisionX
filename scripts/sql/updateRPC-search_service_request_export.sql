CREATE OR REPLACE FUNCTION public.search_service_request_export(_since date DEFAULT NULL::date, _until date DEFAULT NULL::date)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
AS $$
BEGIN
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
        ),
        jsonb_build_object(
          'url', 'http://example.org/fhir/StructureDefinition/hasStockOpname',
          'valueBoolean', "hasStockOpname"
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
    WHERE updated_at >= _since AND updated_at <= _until;
END;
$$;
