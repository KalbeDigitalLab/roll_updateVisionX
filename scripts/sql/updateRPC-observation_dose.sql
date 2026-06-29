CREATE OR REPLACE FUNCTION public.create_observation(payload jsonb)
  RETURNS text
  LANGUAGE plpgsql
AS $$
DECLARE
  new_id text := gen_random_uuid()::text;
  subject_value text;
  partOf_value text;
  performer_value text;
  subject_display_value text;
  performer_display_value text;
BEGIN
  -- Cek apakah ada nilai pada reference subject
  IF payload -> 'subject' IS NOT NULL THEN
    subject_value := NULLIF(TRIM(split_part(payload -> 'subject' ->> 'reference', '/', 2)), '');
    subject_display_value := payload -> 'subject' ->> 'display';
  ELSE
    subject_value := NULL;
    subject_display_value := NULL;
  END IF;

  IF jsonb_typeof(payload -> 'performer') = 'array' AND jsonb_array_length(payload -> 'performer') > 0 THEN
    performer_value := NULLIF(TRIM(split_part((payload -> 'performer' -> 0) ->> 'reference', '/', 2)), '');
    performer_display_value := (payload -> 'performer' -> 0) ->> 'display';
  ELSE
    performer_value := NULL;
    performer_display_value := NULL;
  END IF;


  IF payload -> 'partOf' IS NOT NULL AND payload -> 'partOf' -> 0 ->> 'reference' IS NOT NULL THEN
    partOf_value := TRIM(payload -> 'partOf' -> 0 ->> 'reference');
    IF partOf_value = '' THEN
      partOf_value := NULL;
    ELSE
      IF position('/' in partOf_value) > 0 THEN
        partOf_value := NULLIF(TRIM(split_part(partOf_value, '/', 2)), '');
      END IF;
    END IF;
  ELSE
    partOf_value := NULL;
  END IF;

  INSERT INTO public."observation" (
    id,
    identifier,
    "partOf",
    status,
    subject,
    "subject.display",
    "effective.dateTime",
    performer,
    "performer.display",
    extension,
    "component.valueQuantity",
    "component.code",
    created_at,
    udpated_at
  )
  VALUES (
    new_id,
    payload -> 'identifier' -> 0,
    partOf_value,
    (payload ->> 'status')::status,
    subject_value,
    subject_display_value,
    (payload ->> 'effectiveDateTime')::timestamp,
    performer_value,
    performer_display_value,
    payload -> 'extension',
    (
      SELECT jsonb_agg(component -> 'valueQuantity')
      FROM jsonb_array_elements(payload -> 'component') AS component
    ),
    (
      SELECT jsonb_agg(component -> 'code')
      FROM jsonb_array_elements(payload -> 'component') AS component
    ),
    now(),
    now()
  );

  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.patch_observation(observation_id text, patch_operations jsonb) 
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
    subject_display_value TEXT;
    performer_display_value TEXT;

    updated_part_of TEXT;
    updated_status status;
    updated_subject TEXT;
    updated_effective_datetime TIMESTAMP;
    updated_performer TEXT;
    updated_component_value_quantity JSONB;
    updated_component_code JSONB;
    updated_identifier JSONB;
    updated_extension JSONB;

    i INT;
    idx INT;
    idx_text TEXT;
    temp_array JSONB;
    before JSONB;
    after JSONB;
    new_array JSONB;
BEGIN
    -- Fetch current record
    SELECT
        "partOf",
        status,
        subject,
        "subject.display",
        "effective.dateTime",
        performer,
        "performer.display",
        extension,
        "component.valueQuantity",
        "component.code",
        identifier
    INTO
        current_record
    FROM observation
    WHERE id = observation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Observation with ID % not found', observation_id;
    END IF;

    -- Initialize variables
    updated_part_of := current_record."partOf";
    updated_status := current_record.status;
    updated_subject := current_record.subject;
    updated_effective_datetime := current_record."effective.dateTime";
    updated_performer := current_record.performer;
    updated_component_value_quantity := current_record."component.valueQuantity";
    updated_component_code := current_record."component.code";
    updated_identifier := current_record.identifier;
    updated_extension := current_record."extension";
    subject_display_value := current_record."subject.display";
    performer_display_value := current_record."performer.display";

    -- Validate patch_operations
    IF jsonb_typeof(patch_operations) != 'array' THEN
        RAISE EXCEPTION 'patch_operations must be a JSONB array';
    END IF;

    -- Loop through each operation
    FOR i IN 0 .. jsonb_array_length(patch_operations) - 1 LOOP
        op := patch_operations->i;
        op_type := op->>'op';
        path := op->>'path';
        value := op->'value';
        clean_path := SUBSTRING(path FROM 2);
        path_parts := string_to_array(clean_path, '/');

        RAISE NOTICE 'Operation %: op=%, path=%, value=%', i, op_type, path, value;

        CASE op_type
            WHEN 'replace' THEN
                IF clean_path = 'partOf' THEN
                    updated_part_of := op->>'value';
                ELSIF clean_path = 'status' THEN
                    updated_status := (op->>'value')::status;
                ELSIF clean_path = 'subject' THEN
                    updated_subject := op->>'value';
                ELSIF clean_path = 'effectiveDateTime' THEN
                    updated_effective_datetime := (op->>'value')::timestamp;
                ELSIF clean_path = 'performer' THEN
                    updated_performer := op->>'value';
                ELSIF clean_path = 'identifier' THEN
                    updated_identifier := value;
                ELSIF clean_path = 'subject.display' THEN
                    subject_display_value := op->>'value';
                ELSIF clean_path = 'performer.display' THEN
                    performer_display_value := op->>'value';

                ELSIF path_parts[1] = 'extension' THEN
                    IF array_length(path_parts, 1) = 1 THEN
                        -- Replace Full Array: /extension
                        updated_extension := value;
                    ELSE
                        -- Replace Index: /extension/0
                        idx := path_parts[2]::INT;
                        temp_array := COALESCE(updated_extension, '[]'::JSONB);
                        IF idx >= jsonb_array_length(temp_array) THEN
                             RAISE EXCEPTION 'Index % out of bounds for extension', idx;
                        END IF;
                        new_array := '[]'::JSONB;
                        FOR j IN 0 .. jsonb_array_length(temp_array) - 1 LOOP
                            IF j = idx THEN new_array := new_array || jsonb_build_array(value);
                            ELSE new_array := new_array || jsonb_build_array(temp_array->j);
                            END IF;
                        END LOOP;
                        updated_extension := new_array;
                    END IF;

                -- Handle componentValueQuantity (matches your JSON patch path)
                ELSIF path_parts[1] = 'componentValueQuantity' THEN
                    IF array_length(path_parts, 1) = 2 THEN
                        -- Replace entire array: /componentValueQuantity
                        updated_component_value_quantity := value;
                    ELSE
                        -- Replace specific index: /componentValueQuantity/0, /componentValueQuantity/1, etc.
                        idx := path_parts[2]::INT;
                        temp_array := COALESCE(updated_component_value_quantity, '[]'::JSONB);
                        
                        -- Check if index exists in the array
                        IF idx >= jsonb_array_length(temp_array) THEN
                            RAISE EXCEPTION 'Index % out of bounds for componentValueQuantity array (length: %)', idx, jsonb_array_length(temp_array);
                        END IF;
                        
                        -- Build new array with replaced element at index
                        new_array := '[]'::JSONB;
                        FOR j IN 0 .. jsonb_array_length(temp_array) - 1 LOOP
                            IF j = idx THEN
                                new_array := new_array || jsonb_build_array(value);
                            ELSE
                                new_array := new_array || jsonb_build_array(temp_array->j);
                            END IF;
                        END LOOP;
                        updated_component_value_quantity := new_array;
                    END IF;

                -- Handle componentCode (matches your JSON patch path)
                ELSIF path_parts[1] = 'componentCode' THEN
                    IF array_length(path_parts, 1) = 2 THEN
                        -- Replace entire array: /componentCode
                        updated_component_code := value;
                    ELSE
                        -- Replace specific index: /componentCode/0, /componentCode/1, etc.
                        idx := path_parts[2]::INT;
                        temp_array := COALESCE(updated_component_code, '[]'::JSONB);
                        
                        -- Check if index exists in the array
                        IF idx >= jsonb_array_length(temp_array) THEN
                            RAISE EXCEPTION 'Index % out of bounds for componentCode array (length: %)', idx, jsonb_array_length(temp_array);
                        END IF;
                        
                        -- Build new array with replaced element at index
                        new_array := '[]'::JSONB;
                        FOR j IN 0 .. jsonb_array_length(temp_array) - 1 LOOP
                            IF j = idx THEN
                                new_array := new_array || jsonb_build_array(value);
                            ELSE
                                new_array := new_array || jsonb_build_array(temp_array->j);
                            END IF;
                        END LOOP;
                        updated_component_code := new_array;
                    END IF;

                ELSE
                    RAISE EXCEPTION 'Unsupported patch path for replace: %', clean_path;
                END IF;

            WHEN 'remove' THEN
                IF clean_path = 'status' THEN
                    updated_status := NULL;
                ELSIF clean_path = 'partOf' THEN
                    updated_part_of := NULL;
                ELSIF clean_path = 'subject' THEN
                    updated_subject := NULL;
                ELSIF clean_path = 'effective.dateTime' THEN
                    updated_effective_datetime := NULL;
                ELSIF clean_path = 'performer' THEN
                    updated_performer := NULL;
                ELSIF clean_path = 'identifier' THEN
                    updated_identifier := NULL;
                ELSIF clean_path = 'componentValueQuantity' THEN
                    updated_component_value_quantity := NULL;
                ELSIF clean_path = 'componentCode' THEN
                    updated_component_code := NULL;
                ELSIF clean_path = 'subject.display' THEN
                    subject_display_value := NULL;
                ELSIF clean_path = 'performer.display' THEN
                    performer_display_value := NULL;
                ELSIF clean_path = 'extension' THEN updated_extension := NULL; -- Remove full extension
                
                -- HANDLE EXTENSION REMOVE INDEX
                ELSIF path_parts[1] = 'extension' AND array_length(path_parts, 1) = 2 THEN
                    idx := path_parts[2]::INT;
                    temp_array := COALESCE(updated_extension, '[]'::JSONB);
                    new_array := '[]'::JSONB;
                    FOR j IN 0 .. jsonb_array_length(temp_array) - 1 LOOP
                        IF j != idx THEN new_array := new_array || jsonb_build_array(temp_array->j); END IF;
                    END LOOP;
                    updated_extension := new_array;
                
                -- Handle removing specific array elements
                ELSIF path_parts[1] = 'componentValueQuantity' AND array_length(path_parts, 1) = 3 THEN
                    idx := path_parts[2]::INT;
                    temp_array := COALESCE(updated_component_value_quantity, '[]'::JSONB);
                    new_array := '[]'::JSONB;
                    FOR j IN 0 .. jsonb_array_length(temp_array) - 1 LOOP
                        IF j != idx THEN
                            new_array := new_array || jsonb_build_array(temp_array->j);
                        END IF;
                    END LOOP;
                    updated_component_value_quantity := new_array;

                ELSIF path_parts[1] = 'componentCode' AND array_length(path_parts, 1) = 3 THEN
                    idx := path_parts[2]::INT;
                    temp_array := COALESCE(updated_component_code, '[]'::JSONB);
                    new_array := '[]'::JSONB;
                    FOR j IN 0 .. jsonb_array_length(temp_array) - 1 LOOP
                        IF j != idx THEN
                            new_array := new_array || jsonb_build_array(temp_array->j);
                        END IF;
                    END LOOP;
                    updated_component_code := new_array;

                ELSE
                    RAISE EXCEPTION 'Unsupported patch path for remove: %', clean_path;
                END IF;

            WHEN 'add' THEN
                -- HANDLE EXTENSION ADD
                IF path_parts[1] = 'extension' THEN
                    IF array_length(path_parts, 1) = 1 THEN
                         -- Add to end: /extension
                         IF updated_extension IS NULL THEN updated_extension := jsonb_build_array(value);
                         ELSE updated_extension := updated_extension || jsonb_build_array(value);
                         END IF;
                    ELSE
                         -- Insert: /extension/0
                         idx_text := path_parts[2];
                         temp_array := COALESCE(updated_extension, '[]'::JSONB);
                         IF idx_text = '-' THEN updated_extension := temp_array || jsonb_build_array(value);
                         ELSE
                            idx := idx_text::INT;
                            before := COALESCE(jsonb_path_query_array(temp_array, '$[0:' || idx || ']'), '[]'::JSONB);
                            after := COALESCE(jsonb_path_query_array(temp_array, '$[' || idx || ':]'), '[]'::JSONB);
                            updated_extension := before || jsonb_build_array(value) || after;
                         END IF;
                    END IF;
            
                -- Handle componentValueQuantity
                ELSIF path_parts[1] = 'componentValueQuantity' THEN
                    IF array_length(path_parts, 1) = 2 THEN
                        -- Add to end of array: /componentValueQuantity
                        IF updated_component_value_quantity IS NULL THEN
                            updated_component_value_quantity := jsonb_build_array(value);
                        ELSE
                            updated_component_value_quantity := updated_component_value_quantity || jsonb_build_array(value);
                        END IF;
                    ELSE
                        -- Add at specific index: /componentValueQuantity/0, /componentValueQuantity/1, etc.
                        idx_text := path_parts[2];
                        temp_array := COALESCE(updated_component_value_quantity, '[]'::JSONB);
                        IF idx_text = '-' THEN
                            -- Add to end
                            updated_component_value_quantity := temp_array || jsonb_build_array(value);
                        ELSE
                            -- Insert at specific index
                            idx := idx_text::INT;
                            before := COALESCE(jsonb_path_query_array(temp_array, '$[0:' || idx || ']'), '[]'::JSONB);
                            after := COALESCE(jsonb_path_query_array(temp_array, '$[' || idx || ':]'), '[]'::JSONB);
                            updated_component_value_quantity := before || jsonb_build_array(value) || after;
                        END IF;
                    END IF;

                -- Handle componentCode
                ELSIF path_parts[1] = 'componentCode' THEN
                    IF array_length(path_parts, 1) = 2 THEN
                        -- Add to end of array: /componentCode
                        IF updated_component_code IS NULL THEN
                            updated_component_code := jsonb_build_array(value);
                        ELSE
                            updated_component_code := updated_component_code || jsonb_build_array(value);
                        END IF;
                    ELSE
                        -- Add at specific index: /componentCode/0, /componentCode/1, etc.
                        idx_text := path_parts[2];
                        temp_array := COALESCE(updated_component_code, '[]'::JSONB);
                        IF idx_text = '-' THEN
                            -- Add to end
                            updated_component_code := temp_array || jsonb_build_array(value);
                        ELSE
                            -- Insert at specific index
                            idx := idx_text::INT;
                            before := COALESCE(jsonb_path_query_array(temp_array, '$[0:' || idx || ']'), '[]'::JSONB);
                            after := COALESCE(jsonb_path_query_array(temp_array, '$[' || idx || ':]'), '[]'::JSONB);
                            updated_component_code := before || jsonb_build_array(value) || after;
                        END IF;
                    END IF;

                -- Handle other fields
                ELSIF clean_path = 'identifier' THEN
                    IF updated_identifier IS NULL THEN
                        updated_identifier := value;
                    ELSE
                        updated_identifier := updated_identifier || value;
                    END IF;
                ELSIF clean_path = 'status' AND updated_status IS NULL THEN
                    updated_status := (op->>'value')::status;
                ELSIF clean_path = 'partOf' AND updated_part_of IS NULL THEN
                    updated_part_of := op->>'value';
                ELSIF clean_path = 'subject' AND updated_subject IS NULL THEN
                    updated_subject := op->>'value';
                ELSIF clean_path = 'subject.display' AND subject_display_value IS NULL THEN
                    subject_display_value := op->>'value';
                ELSIF clean_path = 'performer.display' AND performer_display_value IS NULL THEN
                    performer_display_value := op->>'value';
                ELSIF clean_path = 'performer' AND updated_performer IS NULL THEN
                    updated_performer := op->>'value';
                ELSIF clean_path = 'effectiveDateTime' AND updated_effective_datetime IS NULL THEN
                    updated_effective_datetime := (op->>'value')::timestamp;
                ELSE
                    RAISE EXCEPTION 'Unsupported or duplicate patch path for add: %', clean_path;
                END IF;

            ELSE
                RAISE EXCEPTION 'Unsupported patch operation: %', op_type;
        END CASE;

        RAISE NOTICE 'After op %: partOf=% status=% subject=% effective.dateTime=% performer=% subject.display=% performer.display=%',
        i, updated_part_of, updated_status, updated_subject, updated_effective_datetime, updated_performer, subject_display_value, performer_display_value;

    END LOOP;

    -- Final UPDATE
    UPDATE public.observation
    SET
        "partOf" = updated_part_of,
        status = updated_status,
        subject = updated_subject,
        "subject.display" = subject_display_value,
        "effective.dateTime" = updated_effective_datetime,
        performer = updated_performer,
        "performer.display" = performer_display_value,
        "component.valueQuantity" = updated_component_value_quantity,
        "component.code" = updated_component_code,
        identifier = updated_identifier,
        "extension" = updated_extension,
        udpated_at = NOW()
    WHERE id = observation_id;

    RETURN observation_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.search_observation_by_id(observation_id text) 
  RETURNS SETOF jsonb 
  LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT jsonb_build_object(
    'resourceType', 'Observation',
    'id', o.id,
    'extension', o.extension,
    'identifier', o.identifier,
    'partOf', CASE 
      WHEN o."partOf" IS NOT NULL THEN jsonb_build_array(
        jsonb_build_object(
          'reference', 'Procedure/' || o."partOf"::text,
          'display', o."partOf"::text  -- Add display field
        )
      )
      ELSE NULL
    END,
    'status', o.status::text,
    'subject', CASE 
      WHEN o.subject IS NOT NULL THEN jsonb_strip_nulls(jsonb_build_object(
        'reference', 'Patient/' || o.subject,
        'display', o."subject.display"
      ))
      ELSE NULL
    END,
    'effectiveDateTime', CASE 
      WHEN o."effective.dateTime" IS NOT NULL 
      THEN to_char(o."effective.dateTime", 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      ELSE NULL
    END,
    'performer', CASE 
      WHEN o.performer IS NOT NULL THEN jsonb_build_array(
        jsonb_strip_nulls(jsonb_build_object(
          'reference', 'Practitioner/' || o.performer,
          'display', o."performer.display"
        ))
      )
      ELSE jsonb_build_array(
        jsonb_build_object(
          'reference', '',
          'display', ''
        )
      )
    END,
    'component', CASE
      WHEN o."component.code" IS NOT NULL OR o."component.valueQuantity" IS NOT NULL THEN
        COALESCE(
          (
            SELECT jsonb_agg(
              jsonb_build_object(
                'code', COALESCE(cc.value, '{}'::jsonb),
                'valueQuantity', COALESCE(cq.value, '{}'::jsonb)
              )
            )
            FROM jsonb_array_elements(
              CASE
                WHEN jsonb_typeof(o."component.code") = 'array' THEN o."component.code"
                WHEN o."component.code" IS NOT NULL THEN jsonb_build_array(o."component.code")
                ELSE '[]'::jsonb
              END
            ) WITH ORDINALITY AS cc(value, idx)
            FULL JOIN jsonb_array_elements(
              CASE
                WHEN jsonb_typeof(o."component.valueQuantity") = 'array' THEN o."component.valueQuantity"
                WHEN o."component.valueQuantity" IS NOT NULL THEN jsonb_build_array(o."component.valueQuantity")
                ELSE '[]'::jsonb
              END
            ) WITH ORDINALITY AS cq(value, idx)
            ON cc.idx = cq.idx
            WHERE cc.value IS NOT NULL OR cq.value IS NOT NULL
          ),
          jsonb_build_array('{}'::jsonb)
        )
      ELSE jsonb_build_array('{}'::jsonb)
    END
  )
  FROM public."observation" o
  WHERE o.id = observation_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.search_observation_dynamic(search_field text, search_value text) 
  RETURNS SETOF jsonb 
  LANGUAGE plpgsql
AS $$
DECLARE
  field_exists BOOLEAN;
  query_text TEXT;
  result_count INTEGER;
BEGIN
  -- Check if the field exists in the observation table or is 'part-of' or 'date'
  IF lower(search_field) NOT IN ('part-of', 'date', 'component-value-quantity', 'component-code') THEN
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'observation'
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
      ''resourceType'', ''Observation'',
      ''id'', id,
      ''partOf'', CASE WHEN "partOf" IS NOT NULL THEN jsonb_build_array(
        jsonb_build_object(
          ''reference'', ''Procedure/'' || "partOf"
        )
      ) ELSE NULL END,
      ''extension'', extension,
      ''identifier'', identifier,
      ''status'', status,
      ''subject'', CASE WHEN subject IS NOT NULL THEN jsonb_build_object(
        ''reference'', ''Patient/'' || subject,
        ''display'', "subject.display"
      ) ELSE NULL END,
      ''effectiveDateTime'', "effective.dateTime",
      ''performer'', CASE WHEN performer IS NOT NULL THEN jsonb_build_array(
        jsonb_build_object(
          ''reference'', ''Practitioner/'' || performer,
          ''display'', "performer.display"
        )
      ) ELSE NULL END,
      ''component'', COALESCE(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              ''code'', cc.value,
              ''valueQuantity'', cq.value
            )
          )
          FROM jsonb_array_elements(
            CASE
              WHEN jsonb_typeof("component.code") = ''array'' THEN "component.code"
              ELSE jsonb_build_array("component.code")
            END
          ) WITH ORDINALITY AS cc(value, idx)
          FULL JOIN jsonb_array_elements(
            CASE
              WHEN jsonb_typeof("component.valueQuantity") = ''array'' THEN "component.valueQuantity"
              ELSE jsonb_build_array("component.valueQuantity")
            END
          ) WITH ORDINALITY AS cq(value, idx)
          ON cc.idx = cq.idx
          WHERE cc.value IS NOT NULL OR cq.value IS NOT NULL
        ),
        ''[]''::jsonb
      )
    ) as result
    FROM public.observation
    WHERE ';

  -- Handle JSONB fields, part-of, date, and other fields
  IF lower(search_field) = 'component-value-quantity' THEN
    query_text := query_text || '
      "component.valueQuantity" IS NOT NULL AND
      CASE 
        WHEN jsonb_typeof("component.valueQuantity") = ''array'' THEN 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements("component.valueQuantity") AS elem
            WHERE (elem->>''value'')::TEXT = $1
          )
        ELSE 
          ("component.valueQuantity"->>''value'')::TEXT = $1
      END';
  ELSIF lower(search_field) = 'identifier' THEN
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
  ELSIF lower(search_field) = 'component-code' THEN
    query_text := query_text || '
      "component.code" IS NOT NULL AND
      CASE 
        WHEN jsonb_typeof("component.code") = ''array'' THEN 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements("component.code") AS elem
            WHERE EXISTS (
              SELECT 1
              FROM jsonb_array_elements(elem->''coding'') AS coding
              WHERE coding->>''code'' = $1
            )
          )
        ELSE 
          EXISTS (
            SELECT 1
            FROM jsonb_array_elements("component.code"->''coding'') AS coding
            WHERE coding->>''code'' = $1
          )
      END';
  ELSIF lower(search_field) = 'part-of' THEN
    query_text := query_text || '
      "partOf" IS NOT NULL AND
      "partOf" = $1::text';
  ELSIF lower(search_field) = 'date' THEN
    query_text := query_text || '
      "effective.dateTime" IS NOT NULL AND
      DATE("effective.dateTime") = TO_DATE($1, ''YYYY-MM-DD'')';
  ELSE
    query_text := query_text || quote_ident(lower(search_field)) || '::text = $1';
  END IF;

  -- Execute dynamic query and check if any results were found
  RETURN QUERY EXECUTE query_text USING search_value;
  
  -- Check if no rows were returned
  GET DIAGNOSTICS result_count = ROW_COUNT;
  IF result_count = 0 THEN
    RETURN QUERY SELECT NULL::jsonb;
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    -- Return null on error
    RETURN QUERY SELECT NULL::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION public.search_observation_export(_since date DEFAULT NULL::date, _until date DEFAULT NULL::date) 
  RETURNS SETOF jsonb 
  LANGUAGE plpgsql
AS $$
BEGIN

  -- Return the query result
  RETURN QUERY
   SELECT jsonb_build_object(
    'resourceType', 'Observation',
    'id', id::text,
    'extension', extension,
    'identifier', identifier,
    'partOf', jsonb_build_array(
      jsonb_build_object(
        'reference', 'Procedure/' || COALESCE("partOf"::text, 'unknown'),
        'display', 'ini msh dihardcode'
      )
    ),
    'status', COALESCE(status, 'unknown'),
    'subject', jsonb_build_object(
      'reference', 'Patient/' || subject::text,
      'display', "subject.display"
    ),
    'effectiveDateTime', COALESCE(
      to_char("effective.dateTime", 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'unknown'
    ),
    'performer', jsonb_build_array(
      jsonb_build_object(
        'reference', 'Practitioner/' || performer::text,
        'display', "performer.display"
      )
    ),
    'component', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'code', cc.value,
            'valueQuantity', cq.value
          )
        )
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof("component.code") = 'array' THEN "component.code"
            ELSE jsonb_build_array("component.code")
          END
        ) WITH ORDINALITY AS cc(value, idx)
        FULL JOIN jsonb_array_elements(
          CASE
            WHEN jsonb_typeof("component.valueQuantity") = 'array' THEN "component.valueQuantity"
            ELSE jsonb_build_array("component.valueQuantity")
          END
        ) WITH ORDINALITY AS cq(value, idx)
        ON cc.idx = cq.idx
        WHERE cc.value IS NOT NULL OR cq.value IS NOT NULL
      ),
      '[]'::jsonb
    )
  )
  FROM public.observation
  WHERE udpated_at >= _since AND udpated_at <= _until;

   IF NOT FOUND THEN
    RETURN QUERY SELECT '[]'::jsonb;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Error in search_observations: %', SQLERRM;
    RETURN QUERY SELECT jsonb_build_object(
      'resourceType', 'OperationOutcome',
      'issue', jsonb_build_array(
        jsonb_build_object(
          'severity', 'error',
          'code', 'internal',
          'details', jsonb_build_object(
            'text', 'Unexpected error: ' || SQLERRM
          )
        )
      )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.search_observations() 
  RETURNS SETOF jsonb 
  LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT jsonb_build_object(
    'resourceType', 'Observation',
    'id', id::text,
    'extension', extension,
    'identifier', identifier,
    'partOf', jsonb_build_array(
      jsonb_build_object(
        'reference', 'Procedure/' || COALESCE("partOf"::text, 'unknown'),
        'display', 'ini msh dihardcode'
      )
    ),
    'status', COALESCE(status, 'unknown'),
    'subject', jsonb_build_object(
      'reference', 'Patient/' || subject::text,
      'display', "subject.display"
    ),
    'effectiveDateTime', COALESCE(
      to_char("effective.dateTime", 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'unknown'
    ),
    'performer', jsonb_build_array(
      jsonb_build_object(
        'reference', 'Practitioner/' || performer::text,
        'display', "performer.display"
      )
    ),
    'component', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'code', cc.value,
            'valueQuantity', cq.value
          )
        )
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof("component.code") = 'array' THEN "component.code"
            ELSE jsonb_build_array("component.code")
          END
        ) WITH ORDINALITY AS cc(value, idx)
        FULL JOIN jsonb_array_elements(
          CASE
            WHEN jsonb_typeof("component.valueQuantity") = 'array' THEN "component.valueQuantity"
            ELSE jsonb_build_array("component.valueQuantity")
          END
        ) WITH ORDINALITY AS cq(value, idx)
        ON cc.idx = cq.idx
        WHERE cc.value IS NOT NULL OR cq.value IS NOT NULL
      ),
      '[]'::jsonb
    )
  )
  FROM public.observation;

  IF NOT FOUND THEN
    RETURN QUERY SELECT '[]'::jsonb;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Error in search_observations: %', SQLERRM;
    RETURN QUERY SELECT jsonb_build_object(
      'resourceType', 'OperationOutcome',
      'issue', jsonb_build_array(
        jsonb_build_object(
          'severity', 'error',
          'code', 'internal',
          'details', jsonb_build_object(
            'text', 'Unexpected error: ' || SQLERRM
          )
        )
      )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_observation(observation_id uuid, payload jsonb) 
  RETURNS uuid 
  LANGUAGE plpgsql
AS $$
DECLARE
  updated_id uuid := observation_id;
BEGIN
  UPDATE public."observation"
  SET
    "partOf" = split_part(payload -> 'partOf' -> 0 ->> 'reference', '/', 2)::uuid,
    status = (payload ->> 'status')::status,
    subject = split_part(payload -> 'subject' ->> 'reference', '/', 2)::uuid,
    "effective.dateTime" = (payload ->> 'effectiveDateTime')::timestamp,
    performer = split_part(payload -> 'performer' -> 0 ->> 'reference', '/', 2)::uuid,
    "extension" = payload -> 'extension',
    "component.valueQuantity" = (
      SELECT jsonb_agg(component -> 'valueQuantity')
      FROM jsonb_array_elements(payload -> 'component') AS component
    ),
    component.code = (
      SELECT jsonb_agg(component -> 'code')
      FROM jsonb_array_elements(payload -> 'component') AS component
    ),
    udpated_at = now()
  WHERE id = observation_id
  RETURNING id INTO updated_id;

  IF updated_id IS NULL THEN
    RAISE EXCEPTION 'Observation with id % not found or update failed', observation_id;
  END IF;

  RETURN updated_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_observation(payload jsonb, observation_id text) 
  RETURNS text 
  LANGUAGE plpgsql
AS $$
DECLARE
  existing_id text;
  subject_value text;
  performer_value text;
  partOf_value text;
  subject_display_value text;
  performer_display_value text;
BEGIN
  -- Validate required fields
  IF payload ->> 'status' IS NULL THEN
    RAISE EXCEPTION 'Status is required';
  END IF;

  -- Cek dan ambil subject_value, bisa NULL jika tidak valid
  IF payload -> 'subject' IS NOT NULL THEN
    IF payload -> 'subject' ->> 'reference' IS NOT NULL AND split_part(payload -> 'subject' ->> 'reference', '/', 2) <> '' THEN
      subject_value := split_part(payload -> 'subject' ->> 'reference', '/', 2);
    ELSE
      subject_value := NULL;
    END IF;

    subject_display_value := payload -> 'subject' ->> 'display';
  ELSE
    subject_value := NULL;
    subject_display_value := NULL;
  END IF;

  IF jsonb_typeof(payload -> 'performer') = 'array' AND jsonb_array_length(payload -> 'performer') > 0 THEN
    IF (payload -> 'performer' -> 0) ->> 'reference' IS NOT NULL AND split_part((payload -> 'performer' -> 0) ->> 'reference', '/', 2) <> '' THEN
      performer_value := split_part((payload -> 'performer' -> 0) ->> 'reference', '/', 2);
    ELSE
      performer_value := NULL;
    END IF;

    performer_display_value := (payload -> 'performer' -> 0) ->> 'display';
  ELSE
    performer_value := NULL;
    performer_display_value := NULL;
  END IF;

  IF payload -> 'partOf' IS NOT NULL AND payload -> 'partOf' -> 0 ->> 'reference' IS NOT NULL THEN
    partOf_value := TRIM(payload -> 'partOf' -> 0->> 'reference');
    IF partOf_value = '' THEN
      partOf_value := NULL;
    ELSE
      IF position('/' in partOf_value) > 0 THEN
        partOf_value := split_part(partOf_value, '/', 2);
        IF partOf_value = '' THEN
          partOf_value := NULL;
        END IF;
      END IF;
    END IF;
  ELSE
    partOf_value := NULL;
  END IF;

  -- Check if observation exists
  SELECT id INTO existing_id
  FROM public."observation"
  WHERE id = observation_id;

  IF existing_id IS NOT NULL THEN
    -- Update existing observation
    UPDATE public."observation"
    SET
      identifier = payload -> 'identifier' -> 0,
      "partOf" = partOf_value,
      status = (payload ->> 'status')::status,
      subject = subject_value,
      "subject.display" = subject_display_value,
      "effective.dateTime" = (payload ->> 'effectiveDateTime')::timestamp,
      performer = performer_value,
      "performer.display" = performer_display_value,
      "extension" = payload -> 'extension',
      "component.valueQuantity" = (
        SELECT 
          CASE 
            WHEN payload -> 'component' IS NOT NULL AND jsonb_array_length(payload -> 'component') > 0
            THEN jsonb_agg(component -> 'valueQuantity')
            ELSE NULL
          END
        FROM jsonb_array_elements(payload -> 'component') AS component
      ),
      "component.code" = (
        SELECT 
          CASE 
            WHEN payload -> 'component' IS NOT NULL AND jsonb_array_length(payload -> 'component') > 0
            THEN jsonb_agg(component -> 'code')
            ELSE NULL
          END
        FROM jsonb_array_elements(payload -> 'component') AS component
      ),
      udpated_at = now()
    WHERE id = observation_id
    RETURNING id INTO existing_id;
  ELSE
    -- Insert new observation
    INSERT INTO public."observation" (
      id,
      identifier,
      "partOf",
      status,
      subject,
      "subject.display",
      "effective.dateTime",
      performer,
      "performer.display",
      extension,
      "component.valueQuantity",
      "component.code",
      created_at,
      udpated_at
    )
    VALUES (
      observation_id,
      payload -> 'identifier' -> 0,
      partOf_value,
      (payload ->> 'status')::status,
      subject_value,
      subject_display_value,
      (payload ->> 'effectiveDateTime')::timestamp,
      performer_value,
      performer_display_value,
      payload -> 'extension',
      (
        SELECT 
          CASE 
            WHEN payload -> 'component' IS NOT NULL AND jsonb_array_length(payload -> 'component') > 0
            THEN jsonb_agg(component -> 'valueQuantity')
            ELSE NULL
          END
        FROM jsonb_array_elements(payload -> 'component') AS component
      ),
      (
        SELECT 
          CASE 
            WHEN payload -> 'component' IS NOT NULL AND jsonb_array_length(payload -> 'component') > 0
            THEN jsonb_agg(component -> 'code')
            ELSE NULL
          END
        FROM jsonb_array_elements(payload -> 'component') AS component
      ),
      now(),
      now()
    )
    RETURNING id INTO existing_id;
  END IF;

  RETURN existing_id;

  EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'Error in upsert_observation: %', SQLERRM;
END;
$$;
