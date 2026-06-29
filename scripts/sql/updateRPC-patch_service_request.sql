CREATE OR REPLACE FUNCTION public.patch_service_request(request_id text, patch_operations jsonb) 
 RETURNS text 
 LANGUAGE plpgsql
AS $$
DECLARE 
    current_record RECORD;
    op JSONB;
    op_type TEXT;
    path TEXT;
    value JSONB;
    clean_path TEXT;
    path_parts TEXT[];

    updated_modality JSONB;
    updated_identifier JSONB;
    updated_status status;
    updated_code JSONB;
    updated_priority priority;
    updated_reason JSONB;
    updated_occurrence_datetime TIMESTAMP;
    updated_insurance TEXT;
    updated_location TEXT;
    updated_bookmarks JSONB;
    updated_is_exported JSONB;
    updated_note TEXT;
    updated_subject TEXT;
    updated_subject_display TEXT;
    updated_requester TEXT;
    updated_requester_display TEXT;
    updated_performer TEXT;
    updated_performer_display TEXT;
    updated_has_stock_opname BOOLEAN;

    i INT;
BEGIN
    SELECT
        modality,
        identifier,
        status,
        code,
        priority,
        reason,
        "occurrence.dateTime",
        insurance,
        "locationCode",
        bookmarks,
        "isExported",
        note,
        subject,
        "subject.display",
        requester,
        "requester.display",
        performer,
        "performer.display",
        "hasStockOpname"
    INTO current_record
    FROM public."serviceRequest"
    WHERE id = request_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ServiceRequest with ID % not found', request_id;
    END IF;

    updated_modality             := current_record.modality;
    updated_identifier           := current_record.identifier;
    updated_status               := current_record.status;
    updated_code                 := current_record.code;
    updated_priority             := current_record.priority;
    updated_reason               := current_record.reason;
    updated_occurrence_datetime  := current_record."occurrence.dateTime";
    updated_insurance            := current_record.insurance;
    updated_location             := current_record."locationCode";
    updated_bookmarks            := current_record.bookmarks;
    updated_is_exported          := current_record."isExported";
    updated_note                 := current_record.note;
    updated_subject              := current_record.subject;
    updated_subject_display      := current_record."subject.display";
    updated_requester            := current_record.requester;
    updated_requester_display    := current_record."requester.display";
    updated_performer            := current_record.performer;
    updated_performer_display    := current_record."performer.display";
    updated_has_stock_opname     := current_record."hasStockOpname";

    IF jsonb_typeof(patch_operations) != 'array' THEN
        RAISE EXCEPTION 'patch_operations must be a JSONB array';
    END IF;

    FOR i IN 0 .. jsonb_array_length(patch_operations) - 1 LOOP
        op         := patch_operations->i;
        op_type    := op->>'op';
        path       := op->>'path';
        value      := op->'value';
        clean_path := SUBSTRING(path FROM 2);
        path_parts := string_to_array(clean_path, '/');

        RAISE NOTICE 'Operation %: op=%, path=%, value=%', i, op_type, path, value;

        CASE op_type
            WHEN 'replace' THEN
                IF clean_path = 'modality' THEN updated_modality := value;
                ELSIF clean_path = 'identifier' THEN updated_identifier := value;
                ELSIF clean_path = 'status' THEN updated_status := (op->>'value')::status;
                ELSIF clean_path = 'code' THEN updated_code := value;
                ELSIF clean_path = 'priority' THEN updated_priority := (op->>'value')::priority;
                ELSIF clean_path = 'reason' THEN updated_reason := value;
                ELSIF clean_path = 'occurrenceDateTime' THEN updated_occurrence_datetime := (op->>'value')::timestamp;
                ELSIF clean_path = 'insurance' THEN updated_insurance := op->>'value';
                ELSIF clean_path = 'locationCode' THEN updated_location := op->>'value';
                ELSIF clean_path = 'bookmarks' THEN updated_bookmarks := value;
                ELSIF clean_path = 'isExported' THEN updated_is_exported := value;
                ELSIF clean_path = 'note' THEN updated_note := op->>'value';
                ELSIF clean_path = 'subject' THEN updated_subject := op->>'value';
                ELSIF clean_path = 'subjectDisplay' THEN updated_subject_display := op->>'value';
                ELSIF clean_path = 'requester' THEN updated_requester := op->>'value';
                ELSIF clean_path = 'requesterDisplay' THEN updated_requester_display := op->>'value';
                ELSIF clean_path = 'performer' THEN updated_performer := op->>'value';
                ELSIF clean_path = 'performerDisplay' THEN updated_performer_display := op->>'value';
                ELSIF clean_path = 'hasStockOpname' THEN updated_has_stock_opname := (op->>'value')::boolean;
                ELSE RAISE EXCEPTION 'Unsupported patch path for replace: %', clean_path;
                END IF;

            WHEN 'remove' THEN
                IF clean_path = 'status' THEN updated_status := NULL;
                ELSIF clean_path = 'priority' THEN updated_priority := NULL;
                ELSIF clean_path = 'insurance' THEN updated_insurance := NULL;
                ELSIF clean_path = 'locationCode' THEN updated_location := NULL;
                ELSIF clean_path = 'bookmarks' THEN updated_bookmarks := NULL;
                ELSIF clean_path = 'isExported' THEN updated_is_exported := NULL;
                ELSIF clean_path = 'note' THEN updated_note := NULL;
                ELSIF clean_path = 'subject' THEN updated_subject := NULL;
                ELSIF clean_path = 'subjectDisplay' THEN updated_subject_display := NULL;
                ELSIF clean_path = 'requester' THEN updated_requester := NULL;
                ELSIF clean_path = 'requesterDisplay' THEN updated_requester_display := NULL;
                ELSIF clean_path = 'performer' THEN updated_performer := NULL;
                ELSIF clean_path = 'performerDisplay' THEN updated_performer_display := NULL;
                ELSIF clean_path = 'hasStockOpname' THEN updated_has_stock_opname := NULL;
                ELSE RAISE EXCEPTION 'Unsupported patch path for remove: %', clean_path;
                END IF;

            WHEN 'add' THEN
                IF clean_path = 'modality' THEN
                    updated_modality := CASE WHEN updated_modality IS NULL THEN value ELSE updated_modality || value END;
                ELSIF clean_path = 'identifier' THEN
                    updated_identifier := CASE WHEN updated_identifier IS NULL THEN value ELSE updated_identifier || value END;
                ELSIF clean_path = 'code' THEN
                    updated_code := CASE WHEN updated_code IS NULL THEN value ELSE updated_code || value END;
                ELSIF clean_path = 'reason' THEN
                    updated_reason := CASE WHEN updated_reason IS NULL THEN value ELSE updated_reason || value END;
                ELSIF clean_path = 'locationCode' AND updated_location IS NULL THEN updated_location := op->>'value';
                ELSIF clean_path = 'status' AND updated_status IS NULL THEN updated_status := (op->>'value')::status;
                ELSIF clean_path = 'priority' AND updated_priority IS NULL THEN updated_priority := (op->>'value')::priority;
                ELSIF clean_path = 'insurance' AND updated_insurance IS NULL THEN updated_insurance := op->>'value';
                ELSIF clean_path = 'occurrenceDateTime' AND updated_occurrence_datetime IS NULL THEN updated_occurrence_datetime := (op->>'value')::timestamp;
                ELSIF clean_path = 'isExported' THEN updated_is_exported := value;
                ELSIF clean_path = 'note' THEN updated_note := op->>'value';
                ELSIF clean_path = 'subject' THEN updated_subject := op->>'value';
                ELSIF clean_path = 'subjectDisplay' THEN updated_subject_display := op->>'value';
                ELSIF clean_path = 'requester' THEN updated_requester := op->>'value';
                ELSIF clean_path = 'requesterDisplay' THEN updated_requester_display := op->>'value';
                ELSIF clean_path = 'performer' THEN updated_performer := op->>'value';
                ELSIF clean_path = 'performerDisplay' THEN updated_performer_display := op->>'value';
                ELSIF clean_path = 'hasStockOpname' AND updated_has_stock_opname IS NULL THEN updated_has_stock_opname := (op->>'value')::boolean;
                ELSE RAISE EXCEPTION 'Unsupported or duplicate patch path for add: %', clean_path;
                END IF;

            ELSE
                RAISE EXCEPTION 'Unsupported patch operation: %', op_type;
        END CASE;

        RAISE NOTICE 'Updated after op %: modality=%, identifier=%, status=%, code=%, priority=%, reason=%, occurrence.dateTime=%, insurance=%, locationCode=%, bookmarks=%, isExported=%, note=%, subject=%, subject.display=%, requester=%, requester.display=%, performer=%, performer.display=%, hasStockOpname=%',
            i, updated_modality, updated_identifier, updated_status, updated_code, updated_priority,
            updated_reason, updated_occurrence_datetime, updated_insurance, updated_location,
            updated_bookmarks, updated_is_exported, updated_note, updated_subject,
            updated_subject_display, updated_requester, updated_requester_display,
            updated_performer, updated_performer_display, updated_has_stock_opname;
    END LOOP;

    UPDATE public."serviceRequest"
    SET
        modality              = updated_modality,
        identifier            = updated_identifier,
        status                = updated_status,
        code                  = updated_code,
        priority              = updated_priority,
        reason                = updated_reason,
        "occurrence.dateTime" = updated_occurrence_datetime,
        insurance             = updated_insurance,
        "locationCode"        = updated_location,
        bookmarks             = updated_bookmarks,
        "isExported"          = updated_is_exported,
        note                  = updated_note,
        subject               = updated_subject,
        "subject.display"     = updated_subject_display,
        requester             = updated_requester,
        "requester.display"   = updated_requester_display,
        performer             = updated_performer,
        "performer.display"   = updated_performer_display,
        "hasStockOpname"      = updated_has_stock_opname,
        updated_at            = NOW()
    WHERE id = request_id;

    RETURN request_id;
END;
$$;
