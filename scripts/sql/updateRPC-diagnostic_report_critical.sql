CREATE OR REPLACE FUNCTION public.create_diagnostic_report(payload jsonb)
 RETURNS text
 LANGUAGE plpgsql
AS $$
DECLARE
    new_id                     text := gen_random_uuid()::text;

    /* ΓÇöΓÇöΓÇö basic parsed pieces ΓÇöΓÇöΓÇö */
    basedOn_value              text;
    resultsInterpreter_value   text;
    resultsInterpreter_display text;
    performer_value            text;
    performer_display          text;

    /* ΓÇöΓÇöΓÇö extension values ΓÇöΓÇöΓÇö */
    findings_text              text;
    recommendations_text       text;
    is_all_doctor              boolean := false;
    is_critical                boolean := false;
BEGIN
    /* ----------- VALIDATION --------------------------------------- */
    IF payload ->> 'status' IS NULL THEN
        RAISE EXCEPTION 'Status is required';
    END IF;

    IF payload ? 'identifier' IS FALSE THEN
        RAISE EXCEPTION 'Identifier array is required';
    END IF;
    

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇ 1. basedOn (ServiceRequest/<id>) ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
   IF payload ? 'basedOn'
       AND jsonb_array_length(payload -> 'basedOn') > 0 
       AND TRIM(payload -> 'basedOn' -> 0 ->> 'reference') != '' THEN
        basedOn_value :=
            split_part(payload -> 'basedOn' -> 0 ->> 'reference', '/', 2);
        -- Set to NULL if the extracted ID is empty
        IF TRIM(basedOn_value) = '' THEN
            basedOn_value := NULL;
        END IF;
    END IF;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇ 2. resultsInterpreter (first element) ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */

    IF payload ? 'resultsInterpreter'
       AND jsonb_array_length(payload -> 'resultsInterpreter') > 0 
       AND TRIM(payload -> 'resultsInterpreter' -> 0 ->> 'reference') != '' THEN
             resultsInterpreter_value :=
            split_part(payload -> 'resultsInterpreter' -> 0 ->> 'reference','/',2);
        -- Set to NULL if the extracted ID is empty
        IF TRIM(resultsInterpreter_value) = '' THEN
            resultsInterpreter_value := NULL;
        END IF;
    END IF;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇ 3. performer (first element)  Γÿà NEW Γÿà ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
    IF payload ? 'performer'
       AND jsonb_array_length(payload -> 'performer') > 0 
       AND TRIM(payload -> 'performer' -> 0 ->> 'reference') != '' THEN
             performer_value :=
            split_part(payload -> 'performer' -> 0 ->> 'reference','/',2);
        -- Set to NULL if the extracted ID is empty
        IF TRIM(performer_value) = '' THEN
            performer_value := NULL;
        END IF;
    END IF;

    /* ----------- extensions (findings / rec / isAllDoctor) -------- */
    SELECT ext ->> 'valueString'
      INTO findings_text
      FROM jsonb_array_elements(payload -> 'extension') ext
      WHERE ext ->> 'url'
            = 'http://hospital.smarthealth.org/diagnosticreport/findings'
      LIMIT 1;

    SELECT ext ->> 'valueString'
      INTO recommendations_text
      FROM jsonb_array_elements(payload -> 'extension') ext
      WHERE ext ->> 'url'
            = 'http://hospital.smarthealth.org/diagnosticreport/recommendation'
      LIMIT 1;

    SELECT (ext ->> 'valueBoolean')::boolean
      INTO is_all_doctor
      FROM jsonb_array_elements(payload -> 'extension') ext
      WHERE ext ->> 'url'
            = 'http://hospital.smarthealth.org/diagnosticreport/isAllDoctor'
      LIMIT 1;
    
    SELECT (ext ->> 'valueBoolean')::boolean 
      INTO is_critical
      FROM jsonb_array_elements(payload -> 'extension') ext
      WHERE ext ->> 'url' 
            = 'http://hospital.smarthealth.org/diagnosticreport/critical'
      LIMIT 1;

    /* ----------- INSERT ------------------------------------------- */
    INSERT INTO public."diagnosticReport" (
        id,
        findings,
        recommendations,
        "isAllDoctor",
        critical,
        identifier,
        "basedOn",
        status,
        "effective.dateTime",
        "resultsInterpreter",
        "resultsInterpreter.display",
        performer,                    -- NEW
        "performer.display",          -- NEW
        conclusion,
        created_at,
        updated_at
    )
    VALUES (
        new_id,
        findings_text,
        recommendations_text,
        COALESCE(is_all_doctor,false),
        COALESCE(is_critical, false),
        payload -> 'identifier',
        basedOn_value,
        LOWER(payload ->> 'status')::status,
        NULLIF(payload ->> 'effectiveDateTime','')::timestamp,
        resultsInterpreter_value,
        resultsInterpreter_display,
        performer_value,              -- NEW
        performer_display,            -- NEW
        payload ->> 'conclusion',
        now(),
        now()
    );

     -- Γ£à Call sync_identifier_index only once
    PERFORM public.sync_identifier_index(
        'diagnostic_report_identifier_index',
        'diagnostic_report_id',
        new_id,
        payload -> 'identifier'
    );


    RETURN new_id;   -- Node expects plain text/uuid
END;
$$;

CREATE OR REPLACE FUNCTION public.patch_diagnostic_report(report_id text, patch_operations jsonb)
 RETURNS text
 LANGUAGE plpgsql
AS $$
DECLARE
    /* ---------- loop helpers ---------- */
    op                   jsonb;
    op_type              text;
    path                 text;
    clean_path           text;
    value                jsonb;
    i                    int;

    /* ---------- current row ---------- */
    current_record                record;

    /* ---------- working copies (may change in loop) ---------- */
    updated_findings              text;
    updated_recommendations       text;
    updated_is_all_doctor         boolean;
    updated_critical              boolean;
    updated_identifier            jsonb;
    updated_status                status;
    updated_effective_datetime    timestamp;
    updated_result_interpreter    text;
    updated_result_interpreter_display text;
    updated_performer             text;      -- Γÿà NEW Γÿà
    updated_performer_display     text;      -- Γÿà NEW Γÿà
    updated_based_on              text;
    updated_conclusion            text;
BEGIN
    /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ 1. fetch current row ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
    SELECT  findings,
            recommendations,
            "isAllDoctor",
            critical,
            identifier,
            status,
            "effective.dateTime",
            "resultsInterpreter",
            "resultsInterpreter.display",
            performer,
            "performer.display",
            "basedOn",
            conclusion
    INTO    current_record
    FROM    public."diagnosticReport"
    WHERE   id = report_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DiagnosticReport with ID % not found', report_id;
    END IF;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ 2. prime working copies with current data ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
    updated_findings                   := current_record.findings;
    updated_recommendations            := current_record.recommendations;
    updated_is_all_doctor              := current_record."isAllDoctor";
    updated_critical                   := current_record.critical;
    updated_identifier                 := current_record.identifier;
    updated_status                     := current_record.status;
    updated_effective_datetime         := current_record."effective.dateTime";
    updated_result_interpreter         := current_record."resultsInterpreter";
    updated_result_interpreter_display := current_record."resultsInterpreter.display";
    updated_performer                  := current_record.performer;           -- Γÿà
    updated_performer_display          := current_record."performer.display"; -- Γÿà
    updated_based_on                   := current_record."basedOn";
    updated_conclusion                 := current_record.conclusion;

    /* validate payload */
    IF jsonb_typeof(patch_operations) <> 'array' THEN
        RAISE EXCEPTION 'patch_operations must be a JSON array';
    END IF;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ 3. process each patch op ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
    FOR i IN 0 .. jsonb_array_length(patch_operations) - 1 LOOP
        op       := patch_operations -> i;
        op_type  := op ->> 'op';
        path     := op ->> 'path';          -- e.g. "/status"
        value    := op ->  'value';
        clean_path := substr(path, 2);      -- drop leading "/"

        CASE op_type

            /* ---------- REPLACE ----------------------------------- */
            WHEN 'replace' THEN
                IF      clean_path = 'findings'                 THEN updated_findings        := value ->> '';
                ELSIF   clean_path = 'recommendations'          THEN updated_recommendations := value ->> '';
                ELSIF   clean_path = 'isAllDoctor'              THEN updated_is_all_doctor   := (value ->> '')::boolean;
                ELSIF clean_path = 'critical'                   THEN updated_critical := (value ->> '')::boolean;
                ELSIF   clean_path = 'identifier'               THEN updated_identifier      := value;
                ELSIF   clean_path = 'status'                   THEN updated_status          := LOWER(value ->> '')::status;
                ELSIF   clean_path = 'effectiveDateTime'        THEN updated_effective_datetime := (value ->> '')::timestamp;
                ELSIF   clean_path = 'resultsInterpreter'       THEN updated_result_interpreter := value ->> '';
                ELSIF   clean_path = 'resultsInterpreter.display' THEN updated_result_interpreter_display := value ->> '';
                ELSIF   clean_path = 'performer'                THEN updated_performer       := value ->> '';       -- Γÿà
                ELSIF   clean_path = 'performer.display'        THEN updated_performer_display := value ->> '';      -- Γÿà
                ELSIF   clean_path = 'basedOn'                  THEN updated_based_on        := value ->> '';
                ELSIF   clean_path = 'conclusion'               THEN updated_conclusion      := value ->> '';
                ELSE
                    RAISE EXCEPTION 'Unsupported replace path: %', clean_path;
                END IF;

            /* ---------- REMOVE ------------------------------------ */
            WHEN 'remove' THEN
                IF      clean_path = 'findings'                 THEN updated_findings        := NULL;
                ELSIF   clean_path = 'recommendations'          THEN updated_recommendations := NULL;
                ELSIF   clean_path = 'isAllDoctor'              THEN updated_is_all_doctor   := NULL;
                ELSIF   clean_path = 'critical'                 THEN updated_critical        := false;
                ELSIF   clean_path = 'identifier'               THEN updated_identifier      := NULL;
                ELSIF   clean_path = 'status'                   THEN updated_status          := NULL;
                ELSIF   clean_path = 'effectiveDateTime'        THEN updated_effective_datetime := NULL;
                ELSIF   clean_path = 'resultsInterpreter'       THEN updated_result_interpreter := NULL;
                ELSIF   clean_path = 'resultsInterpreter.display' THEN updated_result_interpreter_display := NULL;
                ELSIF   clean_path = 'performer'                THEN updated_performer       := NULL;               -- Γÿà
                ELSIF   clean_path = 'performer.display'        THEN updated_performer_display := NULL;             -- Γÿà
                ELSIF   clean_path = 'basedOn'                  THEN updated_based_on        := NULL;
                ELSIF   clean_path = 'conclusion'               THEN updated_conclusion      := NULL;
                ELSE
                    RAISE EXCEPTION 'Unsupported remove path: %', clean_path;
                END IF;

            /* ---------- ADD --------------------------------------- */
            WHEN 'add' THEN
                IF      clean_path = 'identifier'               THEN
                    updated_identifier := COALESCE(updated_identifier, '[]'::jsonb) || value;
                ELSIF   clean_path = 'findings'                 THEN updated_findings        := COALESCE(updated_findings, value ->> '');
                ELSIF   clean_path = 'recommendations'          THEN updated_recommendations := COALESCE(updated_recommendations, value ->> '');
                ELSIF   clean_path = 'isAllDoctor'              THEN updated_is_all_doctor   := COALESCE(updated_is_all_doctor,(value ->> '')::boolean);
                ELSIF   clean_path = 'critical'              THEN updated_critical   := COALESCE(updated_critical,(value ->> '')::boolean);
                ELSIF   clean_path = 'status'                   THEN updated_status          := COALESCE(updated_status, LOWER(value ->> '')::status);
                ELSIF   clean_path = 'effectiveDateTime'        THEN updated_effective_datetime := COALESCE(updated_effective_datetime,(value ->> '')::timestamp);
                ELSIF   clean_path = 'resultsInterpreter'       THEN updated_result_interpreter := COALESCE(updated_result_interpreter, value ->> '');
                ELSIF   clean_path = 'resultsInterpreter.display' THEN updated_result_interpreter_display := COALESCE(updated_result_interpreter_display, value ->> '');
                ELSIF   clean_path = 'performer'                THEN updated_performer       := COALESCE(updated_performer, value ->> '');          -- Γÿà
                ELSIF   clean_path = 'performer.display'        THEN updated_performer_display := COALESCE(updated_performer_display, value ->> ''); -- Γÿà
                ELSIF   clean_path = 'basedOn'                  THEN updated_based_on        := COALESCE(updated_based_on, value ->> '');
                ELSIF   clean_path = 'conclusion'               THEN updated_conclusion      := COALESCE(updated_conclusion, value ->> '');
                ELSE
                    RAISE EXCEPTION 'Unsupported add path: %', clean_path;
                END IF;

            ELSE
                RAISE EXCEPTION 'Unsupported patch op: %', op_type;
        END CASE;
    END LOOP;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ 4. final UPDATE ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
    UPDATE public."diagnosticReport"
       SET findings                     = updated_findings,
           recommendations              = updated_recommendations,
           "isAllDoctor"                = updated_is_all_doctor,
           critical                     = updated_critical,
           identifier                   = updated_identifier,
           status                       = updated_status,
           "effective.dateTime"         = updated_effective_datetime,
           "resultsInterpreter"         = updated_result_interpreter,
           "resultsInterpreter.display" = updated_result_interpreter_display,
           performer                    = updated_performer,             -- Γÿà
           "performer.display"          = updated_performer_display,     -- Γÿà
           "basedOn"                    = updated_based_on,
           conclusion                   = updated_conclusion,
           updated_at                   = now()
     WHERE id = report_id;

    RETURN report_id;
END;
$$;


CREATE OR REPLACE FUNCTION public.search_diagnostic_report_by_id(report_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $$
DECLARE
    result jsonb;
BEGIN
    /* -------------------------------------------------------------
       Build a single JSON object for the requested report.
       If no row matches, the function returns NULL   (FHIR clients
       usually treat this as ΓÇ£404 ΓÇô not foundΓÇ¥).
    ------------------------------------------------------------- */
    SELECT jsonb_build_object(
             /* ------------ envelope ------------------------------ */
             'resourceType', 'DiagnosticReport',
             'id',           d.id,

             /* ------------ extension ----------------------------- */
             'extension', jsonb_build_array(
                 jsonb_build_object(
                     'url',         'http://hospital.smarthealth.org/diagnosticreport/findings',
                     'valueString', d.findings
                 ),
                 jsonb_build_object(
                     'url',         'http://hospital.smarthealth.org/diagnosticreport/recommendation',
                     'valueString', d.recommendations
                 ),
                 jsonb_build_object(
                     'url',          'http://hospital.smarthealth.org/diagnosticreport/isAllDoctor',
                     'valueBoolean', COALESCE(d."isAllDoctor", false)
                 ),
                 jsonb_build_object(
                    'url',          'http://hospital.smarthealth.org/diagnosticreport/critical',
                    'valueBoolean', COALESCE(d."critical", false)
                )
             ),

             /* ------------ identifier ---------------------------- */
             'identifier', d.identifier,

             /* ------------ basedOn ------------------------------- */
             'basedOn', CASE
                          WHEN d."basedOn" IS NULL
                          THEN jsonb_build_array()
                          ELSE jsonb_build_array(
                                   jsonb_build_object(
                                       'reference',
                                       'ServiceRequest/' || d."basedOn"
                                   ))
                        END,

             /* ------------ core scalar fields -------------------- */
             'status',            d.status,
             'effectiveDateTime', d."effective.dateTime",

             /* ------------ resultsInterpreter -------------------- */
             'resultsInterpreter', CASE
                 WHEN d."resultsInterpreter" IS NULL
                 THEN jsonb_build_array()
                 ELSE jsonb_build_array(
                        jsonb_build_object(
                            'reference',
                            'Practitioner/' || d."resultsInterpreter",
                            'display',
                            d."resultsInterpreter.display"
                        )
                      )
             END,

             /* ------------ performer (NEW) ----------------------- */
             'performer', CASE
                 WHEN d.performer IS NULL
                 THEN jsonb_build_array()
                 ELSE jsonb_build_array(
                        jsonb_build_object(
                            'reference',
                            'Practitioner/' || d.performer,
                            'display',
                            d."performer.display"
                        )
                      )
             END,

             /* ------------ conclusion ---------------------------- */
             'conclusion', d.conclusion
           )
      INTO result
    FROM public."diagnosticReport"  d
    WHERE d.id = report_id          -- ΓåÉ argument

    LIMIT 1;                        -- safety: at most one row

    RETURN result;                  -- may be NULL ΓåÆ ΓÇ£not foundΓÇ¥
END;
$$;

CREATE OR REPLACE FUNCTION public.search_diagnostic_report_dynamic(search_field text, search_value text)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
AS $$
DECLARE
    field_exists  boolean;
    query_text    text;
    result_count  int;
    quoted_field  text;
BEGIN
    /* ΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇö field-existence guard ΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇö */
    IF lower(search_field) NOT IN
       ('based-on','date','results-interpreter','conclusion',
        'performer','performer.display', 'critical')   -- ΓåÉ added new fields
    THEN
        SELECT EXISTS (
            SELECT 1
            FROM   information_schema.columns
            WHERE  table_schema = 'public'
              AND  table_name   = 'diagnosticReport'
              AND  column_name  = lower(search_field)
        )
        INTO field_exists;

        IF NOT field_exists THEN               -- unknown column
            RETURN QUERY SELECT NULL::jsonb;
            RETURN;
        END IF;
    END IF;

    /* ΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇö build JSON wrapper ΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇö */
    query_text := $q$
        SELECT jsonb_build_object(
                 'resourceType',       'DiagnosticReport',
                 'id',                 id,
                 'extension', jsonb_build_array(
                     jsonb_build_object(
                       'url',         'http://hospital.smarthealth.org/diagnosticreport/findings',
                       'valueString', findings
                     ),
                     jsonb_build_object(
                       'url',         'http://hospital.smarthealth.org/diagnosticreport/recommendation',
                       'valueString', recommendations
                     ),
                     jsonb_build_object(
                       'url',          'http://hospital.smarthealth.org/diagnosticreport/isAllDoctor',
                       'valueBoolean', "isAllDoctor"
                     ),
                     jsonb_build_object(
                        'url',          'http://hospital.smarthealth.org/diagnosticreport/critical',
                        'valueBoolean', COALESCE(d."critical", false)
                    )
                 ),
                 'identifier',         identifier,
                 'basedOn',            CASE
                                           WHEN "basedOn" IS NULL
                                           THEN jsonb_build_array()
                                           ELSE jsonb_build_array(
                                                  jsonb_build_object(
                                                    'reference',
                                                    'ServiceRequest/' || "basedOn"))
                                       END,
                 'status',             status,
                 'effectiveDateTime',  "effective.dateTime",
                 'resultsInterpreter', CASE
                                           WHEN "resultsInterpreter" IS NULL
                                           THEN jsonb_build_array()
                                           ELSE jsonb_build_array(
                                                  jsonb_build_object(
                                                    'reference',
                                                    'Practitioner/' || "resultsInterpreter",
                                                    'display',
                                                    "resultsInterpreter.display"))
                                       END,
                 'performer',          CASE                             -- Γÿà NEW Γÿà
                                           WHEN performer IS NULL
                                           THEN jsonb_build_array()
                                           ELSE jsonb_build_array(
                                                  jsonb_build_object(
                                                    'reference',
                                                    'Practitioner/' || performer,
                                                    'display',
                                                    "performer.display"))
                                       END,
                 'conclusion',         conclusion
               ) AS result
        FROM   public."diagnosticReport"
        WHERE  $q$;

    /* ΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇö WHERE-clause per field ΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇö */
    IF lower(search_field) = 'identifier' THEN
        query_text := query_text || $w$
            CASE
              WHEN jsonb_typeof(identifier) = 'array' THEN
                   EXISTS (SELECT 1
                           FROM jsonb_array_elements(identifier) el
                           WHERE el->>'value' ILIKE $1)
              ELSE identifier->>'value' ILIKE $1
            END $w$;

    ELSIF lower(search_field) = 'based-on' THEN
        query_text := query_text || '"basedOn" = $1';

    ELSIF lower(search_field) = 'date' THEN
        query_text := query_text || '
            "effective.dateTime" IS NOT NULL
        AND DATE("effective.dateTime") = TO_DATE($1,''YYYY-MM-DD'')';

    ELSIF lower(search_field) = 'results-interpreter' THEN
        query_text := query_text || '"resultsInterpreter" = $1';

    ELSIF lower(search_field) = 'performer' THEN                       -- Γÿà NEW Γÿà
        query_text := query_text || 'performer = $1';

    ELSIF lower(search_field) = 'performer.display' THEN               -- Γÿà NEW Γÿà
        query_text := query_text || '"performer.display" ILIKE $1';
    
    ELSIF lower(search_field) = 'critical' THEN 
        query_text := query_text || ' "critical" = ($1::boolean) ';

    ELSIF lower(search_field) = 'conclusion' THEN
        query_text := query_text || 'conclusion ILIKE $1';

    ELSE
        /* generic scalar column ΓÇö must quote if mixed case / dot */
        quoted_field := '"' || lower(search_field) || '"';
        query_text   := query_text || quoted_field || '::text = $1';
    END IF;

    /* ΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇö execute & post-process ΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇöΓÇö */
    RETURN QUERY EXECUTE query_text USING search_value;

    GET DIAGNOSTICS result_count = ROW_COUNT;
    IF result_count = 0 THEN
        RETURN QUERY SELECT NULL::jsonb;
    END IF;

EXCEPTION
    WHEN others THEN
        RETURN QUERY SELECT NULL::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION public.search_diagnostic_reports()
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT jsonb_build_object(
             'resourceType', 'DiagnosticReport',
             'id',             d.id,
             /* ---------- extension block -------------------------------- */
             'extension', jsonb_build_array(
                 jsonb_build_object(
                     'url',         'http://hospital.smarthealth.org/diagnosticreport/findings',
                     'valueString', d.findings
                 ),
                 jsonb_build_object(
                     'url',         'http://hospital.smarthealth.org/diagnosticreport/recommendation',
                     'valueString', d.recommendations
                 ),
                 jsonb_build_object(
                     'url',          'http://hospital.smarthealth.org/diagnosticreport/isAllDoctor',
                     'valueBoolean', COALESCE(d."isAllDoctor", false)
                 ),
                 jsonb_build_object(
                      'url',          'http://hospital.smarthealth.org/diagnosticreport/critical',
                      'valueBoolean', COALESCE(d."critical", false)
                  )
             ),
             /* ---------- identifier ------------------------------------- */
             'identifier', d.identifier,

             /* ---------- basedOn ---------------------------------------- */
             'basedOn', CASE
                          WHEN d."basedOn" IS NULL
                          THEN jsonb_build_array()
                          ELSE jsonb_build_array(
                                   jsonb_build_object(
                                     'reference', 'ServiceRequest/' || d."basedOn"
                                   )
                                )
                        END,

             /* ---------- core fields ----------------------------------- */
             'status',            d.status,
             'effectiveDateTime', d."effective.dateTime",

             /* ---------- resultsInterpreter (first element) ------------- */
             'resultsInterpreter', CASE
                 WHEN d."resultsInterpreter" IS NULL
                 THEN jsonb_build_array()
                 ELSE jsonb_build_array(
                        jsonb_build_object(
                          'reference', 'Practitioner/' || d."resultsInterpreter",
                          'display',   d."resultsInterpreter.display"
                        )
                      )
             END,

             /* ---------- performer (NEW) -------------------------------- */
             'performer', CASE
                 WHEN d.performer IS NULL
                 THEN jsonb_build_array()
                 ELSE jsonb_build_array(
                        jsonb_build_object(
                          'reference', 'Practitioner/' || d.performer,
                          'display',   d."performer.display"
                        )
                      )
             END,

             /* ---------- conclusion ------------------------------------ */
             'conclusion', d.conclusion
           )
    FROM public."diagnosticReport" d;
END;
$$;

CREATE OR REPLACE FUNCTION public.search_diagnostic_reports_export(_since date DEFAULT NULL::date, _until date DEFAULT NULL::date)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT jsonb_build_object(
             'resourceType', 'DiagnosticReport',
             'id',             d.id,
             /* ---------- extension block -------------------------------- */
             'extension', jsonb_build_array(
                 jsonb_build_object(
                     'url',         'http://hospital.smarthealth.org/diagnosticreport/findings',
                     'valueString', d.findings
                 ),
                 jsonb_build_object(
                     'url',         'http://hospital.smarthealth.org/diagnosticreport/recommendation',
                     'valueString', d.recommendations
                 ),
                 jsonb_build_object(
                     'url',          'http://hospital.smarthealth.org/diagnosticreport/isAllDoctor',
                     'valueBoolean', COALESCE(d."isAllDoctor", false)
                 ),
                 jsonb_build_object(
                      'url',          'http://hospital.smarthealth.org/diagnosticreport/critical',
                      'valueBoolean', COALESCE(d."critical", false)
                  )
             ),
             /* ---------- identifier ------------------------------------- */
             'identifier', d.identifier,

             /* ---------- basedOn ---------------------------------------- */
             'basedOn', CASE
                          WHEN d."basedOn" IS NULL
                          THEN jsonb_build_array()
                          ELSE jsonb_build_array(
                                   jsonb_build_object(
                                     'reference', 'ServiceRequest/' || d."basedOn"
                                   )
                                )
                        END,

             /* ---------- core fields ----------------------------------- */
             'status',            d.status,
             'effectiveDateTime', d."effective.dateTime",

             /* ---------- resultsInterpreter (first element) ------------- */
             'resultsInterpreter', CASE
                 WHEN d."resultsInterpreter" IS NULL
                 THEN jsonb_build_array()
                 ELSE jsonb_build_array(
                        jsonb_build_object(
                          'reference', 'Practitioner/' || d."resultsInterpreter",
                          'display',   d."resultsInterpreter.display"
                        )
                      )
             END,

             /* ---------- performer (NEW) -------------------------------- */
             'performer', CASE
                 WHEN d.performer IS NULL
                 THEN jsonb_build_array()
                 ELSE jsonb_build_array(
                        jsonb_build_object(
                          'reference', 'Practitioner/' || d.performer,
                          'display',   d."performer.display"
                        )
                      )
             END,

             /* ---------- conclusion ------------------------------------ */
             'conclusion', d.conclusion
           )
    FROM public."diagnosticReport" d
    WHERE updated_at >= _since AND updated_at <= _until;
  
END;
$$;


CREATE OR REPLACE FUNCTION public.upsert_diagnostic_report(report_id text, payload jsonb)
 RETURNS text
 LANGUAGE plpgsql
AS $$
DECLARE
    /* look-ups & flags */
    existing_id                  text;

    findings_text                text;
    recommendations_text         text;
    is_all_doctor                boolean := false;
    is_critical                  boolean := false;

    basedOn_value                text;

    resultsInterpreter_value     text;
    resultsInterpreter_display   text;

    performer_value              text;   -- Γÿà NEW Γÿà
    performer_display            text;   -- Γÿà NEW Γÿà
BEGIN
    /* ΓöÇΓöÇΓöÇΓöÇΓöÇ 1. basedOn (ServiceRequest/<id>) ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
   IF payload ? 'basedOn'
       AND jsonb_array_length(payload -> 'basedOn') > 0 
       AND TRIM(payload -> 'basedOn' -> 0 ->> 'reference') != '' THEN
        basedOn_value :=
            split_part(payload -> 'basedOn' -> 0 ->> 'reference', '/', 2);
        -- Set to NULL if the extracted ID is empty
        IF TRIM(basedOn_value) = '' THEN
            basedOn_value := NULL;
        END IF;
    END IF;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇ 2. resultsInterpreter (first element) ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */

    IF payload ? 'resultsInterpreter'
       AND jsonb_array_length(payload -> 'resultsInterpreter') > 0 
       AND TRIM(payload -> 'resultsInterpreter' -> 0 ->> 'reference') != '' THEN
             resultsInterpreter_value :=
            split_part(payload -> 'resultsInterpreter' -> 0 ->> 'reference','/',2);
        -- Set to NULL if the extracted ID is empty
        IF TRIM(resultsInterpreter_value) = '' THEN
            resultsInterpreter_value := NULL;
        END IF;
    END IF;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇ 3. performer (first element)  Γÿà NEW Γÿà ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
    IF payload ? 'performer'
       AND jsonb_array_length(payload -> 'performer') > 0 
       AND TRIM(payload -> 'performer' -> 0 ->> 'reference') != '' THEN
             performer_value :=
            split_part(payload -> 'performer' -> 0 ->> 'reference','/',2);
        -- Set to NULL if the extracted ID is empty
        IF TRIM(performer_value) = '' THEN
            performer_value := NULL;
        END IF;
    END IF;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇ 4. extension fields (findings / rec / isAllDoctor) ΓöÇΓöÇΓöÇΓöÇΓöÇ */
    SELECT ext ->> 'valueString'
      INTO findings_text
      FROM jsonb_array_elements(payload -> 'extension') ext
      WHERE ext ->> 'url'
            = 'http://hospital.smarthealth.org/diagnosticreport/findings'
      LIMIT 1;

    SELECT ext ->> 'valueString'
      INTO recommendations_text
      FROM jsonb_array_elements(payload -> 'extension') ext
      WHERE ext ->> 'url'
            = 'http://hospital.smarthealth.org/diagnosticreport/recommendation'
      LIMIT 1;

    SELECT (ext ->> 'valueBoolean')::boolean
      INTO is_all_doctor
      FROM jsonb_array_elements(payload -> 'extension') ext
      WHERE ext ->> 'url'
            = 'http://hospital.smarthealth.org/diagnosticreport/isAllDoctor'
      LIMIT 1;
    
    SELECT (ext ->> 'valueBoolean')::boolean 
      INTO is_critical
      FROM jsonb_array_elements(payload -> 'extension') ext
      WHERE ext ->> 'url' = 'http://hospital.smarthealth.org/diagnosticreport/critical'
      LIMIT 1;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇ 5. basic validation ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
    IF payload ->> 'status' IS NULL THEN
        RAISE EXCEPTION 'Status is required';
    END IF;

    IF payload ? 'identifier' IS FALSE THEN
        RAISE EXCEPTION 'Identifier is required';
    END IF;

    /* ΓöÇΓöÇΓöÇΓöÇΓöÇ 6. upsert logic ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ */
    SELECT id
      INTO existing_id
      FROM public."diagnosticReport"
      WHERE id = report_id;

    IF existing_id IS NOT NULL THEN
        /* -------------------- UPDATE ------------------------------ */
        UPDATE public."diagnosticReport"
        SET   findings                     = findings_text,
              recommendations              = recommendations_text,
              "isAllDoctor"                = COALESCE(is_all_doctor,false),
              critical                     = COALESCE(is_critical,false),
              identifier                   = payload -> 'identifier',
              "basedOn"                    = basedOn_value,
              status                       = LOWER(payload ->> 'status')::status,
              "effective.dateTime"         = NULLIF(payload ->> 'effectiveDateTime','')::timestamp,
              "resultsInterpreter"         = resultsInterpreter_value,
              "resultsInterpreter.display" = resultsInterpreter_display,
              performer                    = performer_value,          -- Γÿà NEW Γÿà
              "performer.display"          = performer_display,       -- Γÿà NEW Γÿà
              conclusion                   = payload ->> 'conclusion',
              updated_at                   = now()
        WHERE  id = report_id
        RETURNING id INTO existing_id;

    ELSE
        /* -------------------- INSERT ------------------------------ */
        INSERT INTO public."diagnosticReport" (
            id,
            findings,
            recommendations,
            "isAllDoctor",
            critical,
            identifier,
            "basedOn",
            status,
            "effective.dateTime",
            "resultsInterpreter",
            "resultsInterpreter.display",
            performer,                    -- Γÿà NEW Γÿà
            "performer.display",          -- Γÿà NEW Γÿà
            conclusion,
            created_at,
            updated_at
        )
        VALUES (
            report_id,
            findings_text,
            recommendations_text,
            COALESCE(is_all_doctor,false),
            COALESCE(is_critical,false),
            payload -> 'identifier',
            basedOn_value,
            LOWER(payload ->> 'status')::status,
            NULLIF(payload ->> 'effectiveDateTime','')::timestamp,
            resultsInterpreter_value,
            resultsInterpreter_display,
            performer_value,              -- Γÿà NEW Γÿà
            performer_display,            -- Γÿà NEW Γÿà
            payload ->> 'conclusion',
            now(),
            now()
        )
        RETURNING id INTO existing_id;
    END IF;
    
    -- Γ£à Call sync_identifier_index only once
    PERFORM public.sync_identifier_index(
        'diagnostic_report_identifier_index',
        'diagnostic_report_id',
        existing_id,
        payload -> 'identifier'
    );

    RETURN existing_id;
END;
$$;
