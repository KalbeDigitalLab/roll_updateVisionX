CREATE OR REPLACE FUNCTION public.fast_fetch_studies_paginated_filter_v3(p_column_filters jsonb DEFAULT '[]'::jsonb, p_sorting jsonb DEFAULT '[]'::jsonb, p_index integer DEFAULT 0, p_size integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    result          jsonb;
    v_offset        integer;
    v_total_count   bigint;
    v_filters       jsonb := '{}'::jsonb;
    filter_item     jsonb;
    sort_item       jsonb;
    v_order_by      text := '';
    v_where_clause  text := '';
    v_sql           text;
    -- New variables for optimization
    v_needs_patient BOOLEAN := FALSE;
    v_needs_dr BOOLEAN := FALSE;
    v_needs_proc BOOLEAN := FALSE;
    v_needs_imgs BOOLEAN := FALSE;
    v_needs_obs BOOLEAN := FALSE;
    v_needs_proc_radiographers BOOLEAN := FALSE;
    v_needs_proc_operator BOOLEAN := FALSE;
    v_needs_dr_read_pract BOOLEAN := FALSE;
    v_needs_dr_assigned_pract BOOLEAN := FALSE;
    v_needs_obs_dose_verificator BOOLEAN := FALSE;
BEGIN
    /* ───────── offset ───────── */
    v_offset := p_index * p_size;

    /* ─────── convert filters ─────── */
    FOR filter_item IN SELECT * FROM jsonb_array_elements(p_column_filters) LOOP
        v_filters := v_filters || jsonb_build_object(filter_item->>'id', filter_item->'value');
    END LOOP;

    /* ───────── Analyze which tables we need based on filters ───────── */
    -- Check filters for patient table
    IF v_filters->>'mrn' IS NOT NULL OR 
       v_filters->>'name' IS NOT NULL OR 
       v_filters->>'birthDate' IS NOT NULL OR 
       v_filters->>'age' IS NOT NULL OR 
       v_filters->>'sex' IS NOT NULL OR
       v_filters->>'studyHistoryBasedOnMRN' IS NOT NULL OR
       v_filters->>'studyHistoryBasedOnAccession' IS NOT NULL THEN
        v_needs_patient := TRUE;
    END IF;

    -- Check filters for diagnostic report
    IF v_filters->>'readDoctor' IS NOT NULL OR 
       v_filters->>'status' IS NOT NULL OR 
       v_filters->>'examRead' IS NOT NULL OR
       v_filters->>'reportKeywords' IS NOT NULL OR
       v_filters->>'processStatusFilter' IS NOT NULL OR
       v_filters->>'pageSpecificFilters' IS NOT NULL THEN
        v_needs_dr := TRUE;
    END IF;

    -- Check filters for procedure
    IF v_filters->>'radiographer' IS NOT NULL OR 
       v_filters->>'operator' IS NOT NULL OR 
       v_filters->>'examRegister' IS NOT NULL OR
       v_filters->>'status' IS NOT NULL OR
       v_filters->>'processStatusFilter' IS NOT NULL OR
       v_filters->>'pageSpecificFilters' IS NOT NULL THEN
        v_needs_proc := TRUE;
    END IF;

    -- Check filters for imaging study
    IF v_filters->>'examImages' IS NOT NULL OR 
       v_filters->>'status' IS NOT NULL OR
       v_filters->>'processStatusFilter' IS NOT NULL OR
       v_filters->>'pageSpecificFilters' IS NOT NULL THEN
        v_needs_imgs := TRUE;
    END IF;

    -- Check filters for observation
    IF v_filters->>'doseVerificator' IS NOT NULL OR 
       v_filters->>'status' IS NOT NULL OR
       v_filters->>'processStatusFilter' IS NOT NULL OR
       v_filters->>'pageSpecificFilters' IS NOT NULL THEN
        v_needs_obs := TRUE;
    END IF;

    -- Check specific practitioner needs
    IF v_filters->>'radiographer' IS NOT NULL THEN
        v_needs_proc_radiographers := TRUE;
        v_needs_proc := TRUE;
    END IF;

    IF v_filters->>'operator' IS NOT NULL THEN
        v_needs_proc_operator := TRUE;
        v_needs_proc := TRUE;
    END IF;

    IF v_filters->>'readDoctor' IS NOT NULL THEN
        v_needs_dr_read_pract := TRUE;
        v_needs_dr := TRUE;
    END IF;

    IF v_filters->>'doseVerificator' IS NOT NULL THEN
        v_needs_obs_dose_verificator := TRUE;
        v_needs_obs := TRUE;
    END IF;

    /* ───────── Check sorting requirements ───────── */
    IF jsonb_array_length(p_sorting) > 0 THEN
        v_order_by := ' ORDER BY ';
        FOR sort_item IN SELECT * FROM jsonb_array_elements(p_sorting) LOOP
            -- Check what tables we need for sorting
            CASE sort_item->>'id'
                WHEN 'mrn', 'name', 'birthDate', 'age', 'sex' THEN 
                    v_needs_patient := TRUE;
                WHEN 'status' THEN 
                    v_needs_dr := TRUE; 
                    v_needs_proc := TRUE; 
                    v_needs_imgs := TRUE; 
                    v_needs_obs := TRUE;
                WHEN 'assignedDoctor' THEN
                    v_needs_dr := TRUE;
                    v_needs_dr_assigned_pract := TRUE;
                WHEN 'readDoctor' THEN
                    v_needs_dr := TRUE;
                    v_needs_dr_read_pract := TRUE;
                WHEN 'examRead' THEN 
                    v_needs_dr := TRUE;
                WHEN 'radiographer' THEN 
                    v_needs_proc := TRUE; 
                    v_needs_proc_radiographers := TRUE;
                WHEN 'operator' THEN 
                    v_needs_proc := TRUE; 
                    v_needs_proc_operator := TRUE;
                WHEN 'doseVerificator' THEN 
                    v_needs_obs := TRUE;
                    v_needs_obs_dose_verificator := TRUE;
                WHEN 'examRegister' THEN 
                    v_needs_proc := TRUE;
                WHEN 'examImages', 'imageCount' THEN 
                    v_needs_imgs := TRUE;
                ELSE NULL;
            END CASE;

            -- Build ORDER BY clause
            IF v_order_by <> ' ORDER BY ' THEN
                v_order_by := v_order_by || ', ';
            END IF;

            v_order_by := v_order_by ||
                CASE sort_item->>'id'
                    WHEN 'examination'     THEN 'sr."occurrence.dateTime"'
                    WHEN 'cito'            THEN '(sr.priority::text = ''stat'')'
                    WHEN 'mrn'             THEN '(SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' LIMIT 1)'
                    WHEN 'name'            THEN '(SELECT string_agg(TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', '''')), '', '') FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(pat.name) = ''array'' AND jsonb_array_length(pat.name) > 0)'
                    WHEN 'status'          THEN 'determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text)'
                    WHEN 'modality'        THEN 'sr.modality->''coding''->0->>''code'''
                    WHEN 'accessionNumber' THEN '(SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier) WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1)'
                    WHEN 'studyName'       THEN 'sr.code->''coding''->0->>''display'''
                    WHEN 'ward'            THEN 'sr."locationCode"'
                    WHEN 'referringDoctor' THEN 'sr."requester.display"'
                    WHEN 'assignedDoctor'  THEN 'CASE WHEN COALESCE(dr."isAllDoctor", false) THEN ''All Doctor'' ELSE format_practitioner_name_sql(dr_assigned_pract.name) END'
                    WHEN 'picDoctor'       THEN 'sr."performer.display"'
                    WHEN 'readDoctor'      THEN 'format_practitioner_name_sql(dr_read_pract.name)'
                    WHEN 'radiographer'    THEN 'proc_radiographers.radiographer_names'
                    WHEN 'operator'        THEN 'proc_operator.operator_name'
                    WHEN 'doseVerificator' THEN 'format_practitioner_name_sql(obs_dose_verificator.name)'
                    WHEN 'examRegister'    THEN 'proc."performedDateTime"'
                    WHEN 'examRead'        THEN 'dr."effective.dateTime"'
                    WHEN 'examImages'      THEN 'imgs.started'
                    WHEN 'imageCount'      THEN 'imgs."numberOfInstances"'
                    WHEN 'clinical'        THEN 'sr.reason->''coding''->0->>''display'''
                    WHEN 'insurance'       THEN 'sr.insurance::text'
                    WHEN 'birthDate'       THEN 'pat."birthDate"'
                    WHEN 'age'             THEN 'calculate_age_sql(sr."occurrence.dateTime", pat."birthDate")'
                    WHEN 'sex'             THEN 'CASE pat.gender::text WHEN ''female'' THEN ''F'' WHEN ''male'' THEN ''M'' ELSE ''O'' END'
                    WHEN 'isExported'      THEN 'COALESCE((sr."isExported")::boolean, false)'
                    ELSE 'sr."occurrence.dateTime"'
                END || ' ' ||
                CASE
                    WHEN (sort_item->'desc')::text = 'true'  THEN 'DESC'
                    WHEN (sort_item->'desc')::text = 'false' THEN 'ASC'
                    ELSE 'DESC'
                END || ' NULLS LAST';
        END LOOP;
    ELSE
        v_order_by := ' ORDER BY sr."occurrence.dateTime" DESC NULLS LAST';
    END IF;

    /* ───────── Build WHERE clause (keeping all existing filter logic) ───────── */
    v_where_clause := '';
    
    IF v_filters != '{}'::jsonb THEN
        -- Bookmark filter
        IF v_filters->>'bookmark' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'bookmark') = 'array' THEN
                v_where_clause := v_where_clause ||
                    ' AND EXISTS (' ||
                    '    SELECT 1 ' ||
                    '    FROM jsonb_array_elements(sr.bookmarks) elem ' ||
                    '    WHERE elem->>''url'' = ''tag'' ' ||
                    '    AND EXISTS (' ||
                    '        SELECT 1 ' ||
                    '        FROM jsonb_array_elements_text(''' || (v_filters->'bookmark')::text || '''::jsonb) search_term ' ||
                    '        WHERE LOWER(elem->>''valueString'') ILIKE ''%'' || LOWER(search_term) || ''%''' ||
                    '    )' ||
                    ')';
            ELSE
                v_where_clause := v_where_clause ||
                    ' AND EXISTS (' ||
                    '    SELECT 1 ' ||
                    '    FROM jsonb_array_elements(sr.bookmarks) elem ' ||
                    '    WHERE elem->>''url'' = ''tag'' ' ||
                    '    AND LOWER(elem->>''valueString'') ILIKE ''%'' || LOWER(''' || (v_filters->>'bookmark') || ''') || ''%''' ||
                    ')';
            END IF;
        END IF;

        -- Ward filter
        IF v_filters->>'ward' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('sr."locationCode"', v_filters->'ward', FALSE);
        END IF;

        -- Study Name filter
        IF v_filters->>'studyName' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('(sr.code->''coding''->0->>''display'')', v_filters->'studyName', FALSE);
        END IF;

        -- Clinical filter
        IF v_filters->>'clinical' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('(sr.reason->''coding''->0->>''display'')', v_filters->'clinical', FALSE);
        END IF;

        -- Comment filter
        IF v_filters->>'comment' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('sr.note', v_filters->'comment', FALSE);
        END IF;

        -- Insurance filter
        IF v_filters->>'insurance' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('sr.insurance::text', v_filters->'insurance', FALSE);
        END IF;

        -- Pic Doctor filter
        IF v_filters->>'picDoctor' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('sr."performer.display"', v_filters->'picDoctor', FALSE);
        END IF;

        -- Referring Doctor filter
        IF v_filters->>'referringDoctor' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('sr."requester.display"', v_filters->'referringDoctor', FALSE);
        END IF;

        -- Read Doctor filter
        IF v_filters->>'readDoctor' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('format_practitioner_name_sql(dr_read_pract.name)', v_filters->'readDoctor', FALSE);
        END IF;

        -- Radiographer filter
        IF v_filters->>'radiographer' IS NOT NULL THEN
            v_where_clause := v_where_clause || '
                AND EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(proc."performer.function") f,
                         jsonb_array_elements(f->''coding'') c
                    WHERE c->>''code'' = ''Radiografer'')
                AND ' ||
                _ilike_predicate('proc_radiographers.radiographer_names', v_filters->'radiographer', FALSE);
        END IF;

        -- Operator filter
        IF v_filters->>'operator' IS NOT NULL THEN
            v_where_clause := v_where_clause || '
                AND EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(proc."performer.function") f,
                         jsonb_array_elements(f->''coding'') c
                    WHERE c->>''code'' = ''Operator'')
                AND ' ||
                _ilike_predicate('proc_operator.operator_name', v_filters->'operator', FALSE);
        END IF;

        -- Dose Verificator filter
        IF v_filters->>'doseVerificator' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('format_practitioner_name_sql(obs_dose_verificator.name)', v_filters->'doseVerificator', FALSE);
        END IF;

        -- Accession Number filter
        IF v_filters->>'accessionNumber' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('(SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier) WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1)',
                                v_filters->'accessionNumber', FALSE);
        END IF;

        -- Age filter
        IF v_filters->>'age' IS NOT NULL THEN
            v_where_clause := v_where_clause ||
                ' AND calculate_age_sql(sr."occurrence.dateTime", pat."birthDate")::text ILIKE ''%'' || ''' ||
                (v_filters->>'age') || ''' || ''%''';
        END IF;

        -- Birth Date filter
        IF v_filters->>'birthDate' IS NOT NULL THEN
            DECLARE
                v_birthdate_filter TEXT;
            BEGIN
                v_birthdate_filter := REPLACE(v_filters->>'birthDate', '''', '');
                
                IF LENGTH(v_birthdate_filter) = 4 THEN
                    v_where_clause := v_where_clause ||
                        ' AND EXTRACT(YEAR FROM pat."birthDate") = ' || v_birthdate_filter::integer;
                ELSIF LENGTH(v_birthdate_filter) = 7 AND v_birthdate_filter LIKE '____-__' THEN
                    v_where_clause := v_where_clause ||
                        ' AND TO_CHAR(pat."birthDate", ''YYYY-MM'') = ''' || v_birthdate_filter || '''';
                ELSIF LENGTH(v_birthdate_filter) = 10 AND v_birthdate_filter LIKE '____-__-__' THEN
                    v_where_clause := v_where_clause ||
                        ' AND pat."birthDate" = ''' || v_birthdate_filter || '''::date';
                ELSE
                    v_where_clause := v_where_clause ||
                        ' AND pat."birthDate"::text ILIKE ''%'' || ''' || v_birthdate_filter || ''' || ''%''';
                END IF;
            END;
        END IF;

        -- MRN filter
        IF v_filters->>'mrn' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'mrn') = 'array' THEN
                v_where_clause := v_where_clause || ' AND LOWER((SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' LIMIT 1)) = ANY(SELECT LOWER(jsonb_array_elements_text(''' || (v_filters->'mrn')::text || '''::jsonb)))';
            ELSE
                v_where_clause := v_where_clause || ' AND (SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' LIMIT 1) ILIKE ''%'' || ''' || (v_filters->>'mrn') || ''' || ''%''';
            END IF;
        END IF;

        -- Name filter
        IF v_filters->>'name' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('(SELECT string_agg(TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', '''')), '', '') FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(pat.name) = ''array'' AND jsonb_array_length(pat.name) > 0)',
                                v_filters->'name', FALSE);
        END IF;

        -- Status filter
        IF v_filters->>'status' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'status') = 'array' THEN
                v_where_clause := v_where_clause || ' AND LOWER(determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text)) = ANY(SELECT LOWER(jsonb_array_elements_text(''' || (v_filters->'status')::text || '''::jsonb)))';
            ELSE
                v_where_clause := v_where_clause || ' AND LOWER(determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text)) = LOWER(''' || (v_filters->>'status') || ''')';
            END IF;
        END IF;

        -- Modality filter
        IF v_filters->>'modality' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'modality') = 'array' THEN
                v_where_clause := v_where_clause || 
                    ' AND EXISTS (' ||
                    '    SELECT 1 ' ||
                    '    FROM jsonb_array_elements_text(''' || (v_filters->'modality')::text || '''::jsonb) search_term ' ||
                    '    WHERE UPPER(sr.modality->''coding''->0->>''code'') LIKE ''%'' || UPPER(search_term) || ''%''' ||
                    ')';
            ELSE
                v_where_clause := v_where_clause || 
                    ' AND UPPER(sr.modality->''coding''->0->>''code'') LIKE ''%'' || UPPER(''' || (v_filters->>'modality') || ''') || ''%''';
            END IF;
        END IF;

        -- CITO filter
        IF v_filters->>'cito' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND (sr.priority::text = ''stat'') = ' || (v_filters->>'cito')::boolean;
        END IF;

        -- Sex filter
        IF v_filters->>'sex' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'sex') = 'array' THEN
                v_where_clause := v_where_clause ||
                    ' AND UPPER(CASE pat.gender::text WHEN ''female'' THEN ''F'' WHEN ''male'' THEN ''M'' ELSE ''O'' END) = ANY(SELECT UPPER(jsonb_array_elements_text(''' ||
                    (v_filters->'sex')::text || '''::jsonb)))';
            ELSE
                v_where_clause := v_where_clause ||
                    ' AND UPPER(CASE pat.gender::text WHEN ''female'' THEN ''F'' WHEN ''male'' THEN ''M'' ELSE ''O'' END) = UPPER(''' || (v_filters->>'sex') || ''')';
            END IF;
        END IF;

        -- Date range filters
        -- Examination date
        IF v_filters->>'examination' IS NOT NULL AND jsonb_typeof(v_filters->'examination') = 'object' AND (v_filters->'examination'->>'type') = 'dateRange' THEN
            IF v_filters->'examination'->>'start' IS NOT NULL THEN
                v_where_clause := v_where_clause || ' AND sr."occurrence.dateTime" >= ''' || (v_filters->'examination'->>'start') || '''::timestamp';
            END IF;
            IF v_filters->'examination'->>'end' IS NOT NULL THEN
                v_where_clause := v_where_clause || ' AND sr."occurrence.dateTime" <= ''' || (v_filters->'examination'->>'end') || '''::timestamp';
            END IF;
        END IF;
        
        -- Exam Read date
        IF v_filters->>'examRead' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'examRead') = 'object' AND (v_filters->'examRead'->>'type') = 'dateRange' THEN
                IF v_filters->'examRead'->>'start' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= ''' || (v_filters->'examRead'->>'start') || '''::timestamp';
                END IF;
                IF v_filters->'examRead'->>'end' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND dr."effective.dateTime" <= ''' || (v_filters->'examRead'->>'end') || '''::timestamp';
                END IF;
            ELSIF jsonb_typeof(v_filters->'examRead') = 'string' THEN
                CASE v_filters->>'examRead'
                    WHEN 'Today' THEN
                        v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= CURRENT_DATE AND dr."effective.dateTime" < CURRENT_DATE + INTERVAL ''1 day''';
                    WHEN 'Last 7 Days' THEN
                        v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= CURRENT_DATE - INTERVAL ''7 days'' AND dr."effective.dateTime" < CURRENT_DATE + INTERVAL ''1 day''';
                    WHEN 'Last 30 Days' THEN
                        v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= CURRENT_DATE - INTERVAL ''30 days'' AND dr."effective.dateTime" < CURRENT_DATE + INTERVAL ''1 day''';
                    WHEN 'This Month' THEN
                        v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= DATE_TRUNC(''month'', CURRENT_DATE) AND dr."effective.dateTime" < DATE_TRUNC(''month'', CURRENT_DATE) + INTERVAL ''1 month''';
                    WHEN 'Last Month' THEN
                        v_where_clause := v_where_clause || ' AND dr."effective.dateTime" >= DATE_TRUNC(''month'', CURRENT_DATE - INTERVAL ''1 month'') AND dr."effective.dateTime" < DATE_TRUNC(''month'', CURRENT_DATE)';
                    ELSE
                        NULL;
                END CASE;
            END IF;
        END IF;
        
        -- Exam Register date
        IF v_filters->>'examRegister' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'examRegister') = 'object' AND (v_filters->'examRegister'->>'type') = 'dateRange' THEN
                IF v_filters->'examRegister'->>'start' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= ''' || (v_filters->'examRegister'->>'start') || '''::timestamp';
                END IF;
                IF v_filters->'examRegister'->>'end' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND proc."performedDateTime" <= ''' || (v_filters->'examRegister'->>'end') || '''::timestamp';
                END IF;
            ELSIF jsonb_typeof(v_filters->'examRegister') = 'string' THEN
                CASE v_filters->>'examRegister'
                    WHEN 'Today' THEN
                        v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= CURRENT_DATE AND proc."performedDateTime" < CURRENT_DATE + INTERVAL ''1 day''';
                    WHEN 'Last 7 Days' THEN
                        v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= CURRENT_DATE - INTERVAL ''7 days'' AND proc."performedDateTime" < CURRENT_DATE + INTERVAL ''1 day''';
                    WHEN 'Last 30 Days' THEN
                        v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= CURRENT_DATE - INTERVAL ''30 days'' AND proc."performedDateTime" < CURRENT_DATE + INTERVAL ''1 day''';
                    WHEN 'This Month' THEN
                        v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= DATE_TRUNC(''month'', CURRENT_DATE) AND proc."performedDateTime" < DATE_TRUNC(''month'', CURRENT_DATE) + INTERVAL ''1 month''';
                    WHEN 'Last Month' THEN
                        v_where_clause := v_where_clause || ' AND proc."performedDateTime" >= DATE_TRUNC(''month'', CURRENT_DATE - INTERVAL ''1 month'') AND proc."performedDateTime" < DATE_TRUNC(''month'', CURRENT_DATE)';
                    ELSE
                        NULL;
                END CASE;
            END IF;
        END IF;
        
        -- Exam Images date
        IF v_filters->>'examImages' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'examImages') = 'object' AND (v_filters->'examImages'->>'type') = 'dateRange' THEN
                IF v_filters->'examImages'->>'start' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND imgs.started >= ''' || (v_filters->'examImages'->>'start') || '''::timestamp';
                END IF;
                IF v_filters->'examImages'->>'end' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND imgs.started <= ''' || (v_filters->'examImages'->>'end') || '''::timestamp';
                END IF;
            ELSIF jsonb_typeof(v_filters->'examImages') = 'string' THEN
                CASE v_filters->>'examImages'
                    WHEN 'Today' THEN
                        v_where_clause := v_where_clause || ' AND imgs.started >= CURRENT_DATE AND imgs.started < CURRENT_DATE + INTERVAL ''1 day''';
                    WHEN 'Last 7 Days' THEN
                        v_where_clause := v_where_clause || ' AND imgs.started >= CURRENT_DATE - INTERVAL ''7 days'' AND imgs.started < CURRENT_DATE + INTERVAL ''1 day''';
                    WHEN 'Last 30 Days' THEN
                        v_where_clause := v_where_clause || ' AND imgs.started >= CURRENT_DATE - INTERVAL ''30 days'' AND imgs.started < CURRENT_DATE + INTERVAL ''1 day''';
                    WHEN 'This Month' THEN
                        v_where_clause := v_where_clause || ' AND imgs.started >= DATE_TRUNC(''month'', CURRENT_DATE) AND imgs.started < DATE_TRUNC(''month'', CURRENT_DATE) + INTERVAL ''1 month''';
                    WHEN 'Last Month' THEN
                        v_where_clause := v_where_clause || ' AND imgs.started >= DATE_TRUNC(''month'', CURRENT_DATE - INTERVAL ''1 month'') AND imgs.started < DATE_TRUNC(''month'', CURRENT_DATE)';
                    ELSE
                        NULL;
                END CASE;
            END IF;
        END IF;

        -- Process/Status Filter
        IF v_filters->>'processStatusFilter' IS NOT NULL THEN
            DECLARE
                v_process_filter JSONB;
                v_has_dose BOOLEAN;
                v_status_values JSONB;
                v_process_where TEXT := '';
            BEGIN
                v_process_filter := v_filters->'processStatusFilter';
                v_has_dose := COALESCE((v_process_filter->>'hasDose')::boolean, false);
                v_status_values := COALESCE(v_process_filter->'statusValues', '[]'::jsonb);
                
                IF v_has_dose OR jsonb_array_length(v_status_values) > 0 THEN
                    v_process_where := ' AND (';
                    
                    IF v_has_dose THEN
                        v_process_where := v_process_where || 
                            'LOWER(obs.status::text) = ''final''';
                    END IF;
                    
                    IF jsonb_array_length(v_status_values) > 0 THEN
                        IF v_has_dose THEN
                            v_process_where := v_process_where || ' OR ';
                        END IF;
                        v_process_where := v_process_where || 
                            'LOWER(determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text)) = ANY(SELECT LOWER(jsonb_array_elements_text(''' || 
                            v_status_values::text || '''::jsonb)))';
                    END IF;
                    
                    v_process_where := v_process_where || ')';
                    v_where_clause := v_where_clause || v_process_where;
                END IF;
            END;

        -- Page-Specific Filters
        ELSEIF v_filters->>'pageSpecificFilters' IS NOT NULL THEN
            DECLARE
                v_pf          JSONB  := v_filters->'pageSpecificFilters';
                v_pid         TEXT   := v_pf->>'performerId';
                v_dose        BOOLEAN := COALESCE((v_pf->>'isDosePage')   ::BOOLEAN, FALSE);
                v_worklist    BOOLEAN := COALESCE((v_pf->>'isWorklistPage')::BOOLEAN, FALSE);
                v_report      BOOLEAN := COALESCE((v_pf->>'isReportPage') ::BOOLEAN, FALSE);
                v_admin       BOOLEAN := COALESCE((v_pf->>'isSuperadmin') ::BOOLEAN, FALSE);
                v_allproc     BOOLEAN := COALESCE((v_pf->>'hasAllProcessFilter')::BOOLEAN, FALSE);
                v_extra_count INTEGER;
            BEGIN
                SELECT COUNT(*)
                  INTO v_extra_count
                  FROM jsonb_each(v_filters) AS f(key, val)
                 WHERE key NOT IN ('examination','pageSpecificFilters');

                IF v_extra_count = 0 THEN
                    IF NOT v_admin THEN
                        IF NOT v_allproc THEN
                            IF v_report AND v_pid IS NOT NULL AND v_pid <> '' THEN
                                v_where_clause := v_where_clause ||
                                  ' AND ((dr.performer = ''' || v_pid || ''')' ||
                                  ' OR COALESCE(dr."isAllDoctor", false))' ||
                                  ' AND LOWER((determine_process_sql(' ||
                                  'sr.status::text,' ||
                                  'sr.modality->''coding''->0->>''code'',' ||
                                  'proc.status::text, imgs.status::text,' ||
                                  'dr.status::text, obs.status::text' ||
                                  ')->>''order'')::text) = ''done''' ||
                                  ' AND LOWER((determine_process_sql(' ||
                                  'sr.status::text,' ||
                                  'sr.modality->''coding''->0->>''code'',' ||
                                  'proc.status::text, imgs.status::text,' ||
                                  'dr.status::text, obs.status::text' ||
                                  ')->>''image'')::text) = ''available''' ||
                                  ' AND COALESCE(LOWER(dr.status::text), '''') != ''final''';
                            ELSIF v_report THEN
                                v_where_clause := v_where_clause ||
                                  ' AND LOWER((determine_process_sql(' ||
                                  'sr.status::text,' ||
                                  'sr.modality->''coding''->0->>''code'',' ||
                                  'proc.status::text, imgs.status::text,' ||
                                  'dr.status::text, obs.status::text' ||
                                  ')->>''order'')::text) = ''done''' ||
                                  ' AND LOWER((determine_process_sql(' ||
                                  'sr.status::text,' ||
                                  'sr.modality->''coding''->0->>''code'',' ||
                                  'proc.status::text, imgs.status::text,' ||
                                  'dr.status::text, obs.status::text' ||
                                  ')->>''image'')::text) = ''available''' ||
                                  ' AND COALESCE(LOWER(dr.status::text), '''') != ''final''';
                            END IF;
                            IF v_worklist THEN
                                 v_where_clause := v_where_clause ||
                            ' AND LOWER(determine_status_sql(' ||
                            'sr.status::text, dr.status::text, obs.status::text, ' ||
                            'proc.status::text, imgs.status::text' ||
                            ')) = ANY(ARRAY[''unscheduled'', ''appointed'', ''on-process''])';
                            END IF;
                            IF v_dose THEN
                                v_where_clause := v_where_clause ||
                                  ' AND LOWER((determine_process_sql(' ||
                                  'sr.status::text,' ||
                                  'sr.modality->''coding''->0->>''code'',' ||
                                  'proc.status::text, imgs.status::text,' ||
                                  'dr.status::text, obs.status::text' ||
                                  ')->>''order'')::text) != ''cancel''' ||
                                  ' AND LOWER((determine_process_sql(' ||
                                  'sr.status::text,' ||
                                  'sr.modality->''coding''->0->>''code'',' ||
                                  'proc.status::text, imgs.status::text,' ||
                                  'dr.status::text, obs.status::text' ||
                                  ')->>''image'')::text) = ''available''' ||
                                  ' AND COALESCE(LOWER(obs.status::text), '''') != ''final''' ||
                                  ' AND NOT (UPPER(sr.modality->''coding''->0->>''code'') = ANY(ARRAY[''MR'', ''US'', ''ECG'']))';
                            END IF;
                            IF NOT v_report AND NOT v_worklist AND NOT v_dose THEN
                                v_where_clause := v_where_clause ||
                                  ' AND NOT (' ||
                                  'LOWER((determine_process_sql(' ||
                                  'sr.status::text,' ||
                                  'sr.modality->''coding''->0->>''code'',' ||
                                  'proc.status::text, imgs.status::text,' ||
                                  'dr.status::text, obs.status::text' ||
                                  ')->>''image'')::text) = ''unscheduled''' ||
                                  ' OR LOWER((determine_process_sql(' ||
                                  'sr.status::text,' ||
                                  'sr.modality->''coding''->0->>''code'',' ||
                                  'proc.status::text, imgs.status::text,' ||
                                  'dr.status::text, obs.status::text' ||
                                  ')->>''report'')::text) = ''verified''' ||
                                  ' OR LOWER((determine_process_sql(' ||
                                  'sr.status::text,' ||
                                  'sr.modality->''coding''->0->>''code'',' ||
                                  'proc.status::text, imgs.status::text,' ||
                                  'dr.status::text, obs.status::text' ||
                                  ')->''dose''->>''status'')::text) = ''verified''' ||
                                  ')';
                            END IF;
                        END IF;
                    END IF;
                END IF;
            END;
        END IF;
        
        -- Study History Based on MRN Filter
        IF v_filters->>'studyHistoryBasedOnMRN' IS NOT NULL THEN
            DECLARE
                v_history_filter JSONB;
                v_show_history BOOLEAN;
                v_history_mrn TEXT;
            BEGIN
                v_history_filter := v_filters->'studyHistoryBasedOnMRN';
                v_show_history := COALESCE((v_history_filter->>'showHistory')::boolean, false);
                v_history_mrn := v_history_filter->>'mrn';
                
                IF v_show_history AND v_history_mrn IS NOT NULL AND v_history_mrn != '' THEN
                    v_where_clause := v_where_clause || 
                        ' AND LOWER((SELECT val->>''value'' ' ||
                        'FROM jsonb_array_elements(' ||
                            'CASE ' ||
                                'WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) ' ||
                                'WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ' ||
                                'ELSE ''[]''::jsonb ' ||
                            'END' ||
                        ') val ' ||
                        'WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' ' ||
                        'LIMIT 1)) = LOWER(' || quote_literal(v_history_mrn) || ')';
                END IF;
            END;
        END IF;

        -- Study History Based on Accession Number Filter
        IF v_filters->>'studyHistoryBasedOnAccession' IS NOT NULL THEN
            DECLARE
                v_history_filter JSONB;
                v_show_history BOOLEAN;
                v_history_accession TEXT;
            BEGIN
                v_history_filter := v_filters->'studyHistoryBasedOnAccession';
                v_show_history := COALESCE((v_history_filter->>'showHistory')::boolean, false);
                v_history_accession := v_history_filter->>'accessionNumber';
                
                IF v_show_history AND v_history_accession IS NOT NULL AND v_history_accession != '' THEN
                    v_where_clause := v_where_clause || 
                        ' AND pat.id IN (' ||
                            'SELECT DISTINCT sr_inner.subject ' ||
                            'FROM public."serviceRequest" sr_inner ' ||
                            'WHERE LOWER((SELECT val->>''value'' ' ||
                                'FROM jsonb_array_elements(' ||
                                    'CASE ' ||
                                        'WHEN jsonb_typeof(sr_inner.identifier) = ''object'' THEN jsonb_build_array(sr_inner.identifier) ' ||
                                        'WHEN jsonb_typeof(sr_inner.identifier) = ''array'' THEN sr_inner.identifier ' ||
                                        'ELSE ''[]''::jsonb ' ||
                                    'END' ||
                                ') val ' ||
                                'WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' ' ||
                                'LIMIT 1)) = LOWER(' || quote_literal(v_history_accession) || ')' ||
                        ')';
                END IF;
            END;
        END IF;
        
        -- Report Keywords filter
        IF v_filters->>'reportKeywords' IS NOT NULL THEN
            v_where_clause := v_where_clause ||
                ' AND ( ' ||
                  _ilike_predicate('COALESCE(dr.findings, '''')', v_filters->'reportKeywords', FALSE) ||
                ' OR ' ||
                  _ilike_predicate('COALESCE(dr.recommendations, '''')', v_filters->'reportKeywords', FALSE) ||
                ' OR ' ||
                  _ilike_predicate('COALESCE(dr.conclusion, '''')', v_filters->'reportKeywords', FALSE) ||
                ' )';
        END IF;
    END IF;

    -- Always need dr_read_pract for resultsInterpreter in report
    v_needs_dr_read_pract := TRUE;
    v_needs_dr := TRUE;

    /* ───────── OPTIMIZED total-count query ───────── */
    -- Build count query with minimal joins
    v_sql := 'SELECT COUNT(*) FROM public."serviceRequest" sr';
    
    -- Only add joins that are actually needed for the WHERE clause
    IF v_needs_patient THEN
        v_sql := v_sql || ' LEFT JOIN public.patient_fhir pat ON sr.subject = pat.id';
    END IF;
    
    IF v_needs_proc THEN
        v_sql := v_sql || ' LEFT JOIN LATERAL (
            SELECT p.*
            FROM public.procedure p
            WHERE p."basedOn" = sr.id
            ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
            LIMIT 1
        ) proc ON true';
    END IF;
    
    IF v_needs_proc_radiographers THEN
        v_sql := v_sql || ' LEFT JOIN LATERAL (
            SELECT string_agg(
                format_practitioner_name_sql(pr.name), '', ''
                ORDER BY format_practitioner_name_sql(pr.name)
            ) AS radiographer_names
            FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord)
            JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(val,ord2)
                ON ord = ord2
            JOIN public.practitioner pr
                ON pr.id = split_part(act.val->>''reference'',''/'',2)
            WHERE EXISTS (
                SELECT 1
                FROM jsonb_array_elements(fn.val->''coding'') c
                WHERE c->>''code'' = ''Radiografer''
            )
        ) proc_radiographers ON true';
    END IF;
    
    IF v_needs_proc_operator THEN
        v_sql := v_sql || ' LEFT JOIN LATERAL (
            SELECT format_practitioner_name_sql(pr.name) AS operator_name
            FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord)
            JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(val,ord2)
                ON ord = ord2
            JOIN public.practitioner pr
                ON pr.id = split_part(act.val->>''reference'',''/'',2)
            WHERE EXISTS (
                SELECT 1
                FROM jsonb_array_elements(fn.val->''coding'') c
                WHERE c->>''code'' = ''Operator''
            )
            LIMIT 1
        ) proc_operator ON true';
    END IF;
    
    IF v_needs_dr THEN
        v_sql := v_sql || ' LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id';
    END IF;
    
    IF v_needs_dr_read_pract THEN
        v_sql := v_sql || ' LEFT JOIN public.practitioner dr_read_pract ON dr."resultsInterpreter" = dr_read_pract.id';
    END IF;
    
    IF v_needs_dr_assigned_pract THEN
        v_sql := v_sql || ' LEFT JOIN public.practitioner dr_assigned_pract ON dr.performer = dr_assigned_pract.id';
    END IF;
    
    IF v_needs_imgs THEN
        -- Use simplified join for counting
        v_sql := v_sql || ' LEFT JOIN public."imagingStudy" imgs ON 
            EXISTS (
                SELECT 1 
                FROM jsonb_array_elements(COALESCE(imgs.identifier, ''[]''::jsonb)) img_ident,
                     jsonb_array_elements(COALESCE(proc.identifier, ''[]''::jsonb)) proc_ident
                WHERE img_ident->>''system'' = ''http://hospital.smarthealth.org/accession''
                AND proc_ident->>''system'' = ''http://hospital.smarthealth.org/accession''
                AND img_ident->>''value'' = proc_ident->>''value''
            )
            AND imgs.subject = ' || CASE WHEN v_needs_patient THEN 'pat.id' ELSE 'sr.subject' END;
    END IF;
    
    IF v_needs_obs THEN
        v_sql := v_sql || ' LEFT JOIN public.observation obs ON obs."partOf" = ' || 
                         CASE WHEN v_needs_proc THEN 'proc.id' ELSE 'NULL' END;
    END IF;
    
    IF v_needs_obs_dose_verificator THEN
        v_sql := v_sql || ' LEFT JOIN public.practitioner obs_dose_verificator ON obs.performer = obs_dose_verificator.id';
    END IF;
    
    -- Add WHERE clause
    v_sql := v_sql || ' WHERE 1=1' || v_where_clause;
    
    -- Execute count query
    EXECUTE v_sql INTO v_total_count;

    /* ───────── Paginated data query (keeping existing structure) ───────── */
    v_sql := '
    SELECT jsonb_agg(study_data_rows.study_data)
    FROM (
        SELECT jsonb_build_object(
            ''accessionNumber'', (
                SELECT val->>''value''
                FROM jsonb_array_elements(
                    CASE
                        WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier)
                        WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier
                        ELSE ''[]''::jsonb
                    END) val
                WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession''
                LIMIT 1
            ),
            ''age'', calculate_age_sql(sr."occurrence.dateTime", pat."birthDate"),
            ''assignedDoctor'', CASE
                                  WHEN COALESCE(dr."isAllDoctor", false) THEN ''All Doctor''
                                  ELSE format_practitioner_name_sql(dr_assigned_pract.name)
                              END,
            ''birthDate'', format_date_sql(pat."birthDate", true),
            ''bookmark'', COALESCE(
                              (SELECT jsonb_agg(elem->>''valueString'')
                               FROM jsonb_array_elements(sr.bookmarks) elem
                               WHERE elem->>''url'' = ''tag''),
                              ''[]''::jsonb
                          ),
            ''cito'', to_jsonb(sr.priority::text = ''stat''),
            ''clinical'', (sr.reason->''coding''->0->>''display''),
            ''comment'', sr.note,
            ''diagnosticReportId'', dr.id,
            ''dose'', CASE
                WHEN obs.id IS NULL THEN ''null''::jsonb
                ELSE jsonb_build_object(
                    ''resourceType'', ''Observation'',
                    ''id'', obs.id,
                    ''partOf'', jsonb_build_array(
                        jsonb_build_object(
                            ''reference'', ''Procedure/'' || proc.id,
                            ''display'', (
                                SELECT val->>''value''
                                FROM jsonb_array_elements(
                                    CASE
                                        WHEN jsonb_typeof(proc.identifier) = ''object'' THEN jsonb_build_array(proc.identifier)
                                        WHEN jsonb_typeof(proc.identifier) = ''array'' THEN proc.identifier
                                        ELSE ''[]''::jsonb
                                    END
                                ) val
                                WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession''
                                LIMIT 1
                            )
                        )
                    ),
                    ''subject'', jsonb_build_object(
                        ''reference'', ''Patient/'' || pat.id
                    ),
                    ''component'', jsonb_build_array(
                        jsonb_build_object(
                            ''code'', obs."component.code",
                            ''valueQuantity'', obs."component.valueQuantity"
                        )
                    ),
                    ''performer'', jsonb_build_array(
                        jsonb_build_object(
                            ''reference'', ''Practitioner/'' || COALESCE(obs.performer::text, ''unknown''),
                            ''display'', COALESCE(format_practitioner_name_sql(obs_performer.name), '''')
                        )
                    ),
                    ''status'', COALESCE(obs.status::text, ''unknown''),
                    ''effectiveDateTime'', COALESCE(obs."effective.dateTime"::text, '''')
                )
            END,
            ''doseVerificator'', COALESCE(format_practitioner_name_sql(obs_dose_verificator.name), ''''),
            ''examImages'', format_date_sql(imgs.started, false),
            ''examRead'', COALESCE(format_date_sql(dr."effective.dateTime", false), ''''),
            ''examRegister'', format_date_sql(proc."performedDateTime", false),
            ''examination'', format_date_sql(sr."occurrence.dateTime", false),
            ''imageCount'', COALESCE(imgs."numberOfInstances", 0),
            ''imagingStudyId'', imgs.id,
            ''insurance'', COALESCE(sr.insurance::text, ''''),
            ''isExported'', COALESCE((sr."isExported")::boolean, false),
            ''modality'', (sr.modality->''coding''->0->>''code''),
            ''mrn'', (
                SELECT val->>''value''
                FROM jsonb_array_elements(
                    CASE
                        WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier)
                        WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier
                        ELSE ''[]''::jsonb
                    END
                ) val
                WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn''
                LIMIT 1
            ),
            ''name'', (SELECT string_agg(
                        TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', '''')),
                        '', ''
                    )
                    FROM jsonb_array_elements(pat.name) name_parts
                    WHERE jsonb_typeof(pat.name) = ''array'' AND jsonb_array_length(pat.name) > 0),
            ''observationId'', obs.id,
            ''operator'', COALESCE(proc_operator.operator_name, ''''),
            ''patientId'', pat.id,
            ''picDoctor'', COALESCE(sr."performer.display", ''''),
            ''procedure'', CASE
                WHEN proc.id IS NULL THEN ''null''::jsonb
                ELSE jsonb_build_object(
                    ''resourceType'',''Procedure'',
                    ''id'', proc.id,
                    ''identifier'', COALESCE(proc.identifier,''[]''::jsonb),
                    ''basedOn'', jsonb_build_array(
                        jsonb_build_object(
                            ''reference'', ''ServiceRequest/'' || sr.id,
                            ''display'', (
                                SELECT val->>''value''
                                FROM jsonb_array_elements(
                                    CASE
                                        WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier)
                                        WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier
                                        ELSE ''[]''::jsonb
                                    END
                                ) val
                                WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession''
                                LIMIT 1
                            )
                        )
                    ),
                    ''status'', COALESCE(proc.status::text,''unknown''),
                    ''performedDateTime'', COALESCE(proc."performedDateTime"::text,''''),
                    ''performer'', CASE
                        WHEN jsonb_array_length(proc."performer.function") = 0
                        THEN ''[]''::jsonb
                        ELSE (
                            SELECT jsonb_agg(
                                     jsonb_build_object(
                                       ''function'', fn.value,
                                       ''actor'',   act.value
                                     ))
                            FROM   jsonb_array_elements(proc."performer.function")
                                     WITH ORDINALITY fn(value,ord)
                            JOIN   jsonb_array_elements(proc."performer.actor")
                                     WITH ORDINALITY act(value,ord2)
                                   ON ord = ord2
                        )
                    END,
                    ''location'', jsonb_build_object(
                        ''reference'',''Location/''||COALESCE(proc.location::text,''unknown''),
                        ''display'',   COALESCE(proc_location.name,'''')
                    )
                )
            END,
            ''procedureId'', proc.id,
            ''process'', determine_process_sql(sr.status::text, (sr.modality->''coding''->0->>''code''), proc.status::text, imgs.status::text, dr.status::text, obs.status::text),
            ''radiographer'', COALESCE(proc_radiographers.radiographer_names, ''''),
            ''readDoctor'', COALESCE(format_practitioner_name_sql(dr_read_pract.name), ''''),
            ''referringDoctor'', COALESCE(sr."requester.display", ''''),
            ''report'', CASE
                WHEN dr.id IS NULL THEN ''null''::jsonb
                ELSE jsonb_build_object(
                    ''resourceType'', ''DiagnosticReport'',
                    ''id'', dr.id,
                    ''extension'', jsonb_build_array(
                        jsonb_build_object(
                            ''url'', ''http://hospital.smarthealth.org/diagnosticreport/isAllDoctor'',
                            ''valueBoolean'', COALESCE(dr."isAllDoctor", false)
                        ),
                        jsonb_build_object(
                            ''url'', ''http://hospital.smarthealth.org/diagnosticreport/recommendation'',
                            ''valueString'', dr.recommendations
                        ),
                        jsonb_build_object(
                            ''url'', ''http://hospital.smarthealth.org/diagnosticreport/findings'',
                            ''valueString'', dr.findings
                        )
                    ),
                    ''conclusion'', dr.conclusion,
                    ''identifier'', jsonb_build_array(
                        jsonb_build_object(
                            ''system'', ''http://hospital.smarthealth.org/accession'',
                            ''value'', (
                                SELECT val->>''value''
                                FROM jsonb_array_elements(
                                    CASE
                                        WHEN jsonb_typeof(dr.identifier) = ''object'' THEN jsonb_build_array(dr.identifier)
                                        WHEN jsonb_typeof(dr.identifier) = ''array'' THEN dr.identifier
                                        ELSE ''[]''::jsonb
                                    END
                                ) val
                                WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession''
                                LIMIT 1
                            )
                        )
                    ),
                    ''basedOn'', jsonb_build_array(
                        jsonb_build_object(
                            ''reference'', ''ServiceRequest/'' || sr.id,
                            ''display'', (
                                SELECT val->>''value''
                                FROM jsonb_array_elements(
                                    CASE
                                        WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier)
                                        WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier
                                        ELSE ''[]''::jsonb
                                    END
                                ) val
                                WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession''
                                LIMIT 1
                            )
                        )
                    ),
                    ''status'', COALESCE(dr.status, ''unknown''),
                    ''performer'', jsonb_build_array(
                        jsonb_build_object(
                            ''reference'', ''Practitioner/'' || COALESCE(dr.performer::text, ''unknown''),
                            ''display'', COALESCE(format_practitioner_name_sql(dr_assigned_pract.name), '''')
                        )
                    ),
                    ''resultsInterpreter'', CASE
                        WHEN dr."resultsInterpreter" IS NOT NULL THEN
                            jsonb_build_array(
                                jsonb_build_object(
                                    ''reference'', ''Practitioner/'' || dr."resultsInterpreter"::text,
                                    ''display'', COALESCE(format_practitioner_name_sql(dr_read_pract.name), '''')
                                )
                            )
                        ELSE ''[]''::jsonb
                    END
                )
            END,
            ''serviceRequest'', jsonb_build_object(
                ''resourceType'', ''ServiceRequest'',
                ''id'', sr.id,
                ''extension'', 
                    CASE 
                        WHEN sr.modality IS NOT NULL OR sr.bookmarks IS NOT NULL OR sr."isExported" IS NOT NULL OR sr."locationCode" IS NOT NULL
                        THEN (
                            SELECT jsonb_agg(ext) 
                            FROM (
                                SELECT jsonb_build_object(
                                    ''url'', ''http://example.org/fhir/StructureDefinition/modality'',
                                    ''valueCodeableConcept'', sr.modality
                                ) AS ext
                                WHERE sr.modality IS NOT NULL
                                UNION ALL
                                SELECT jsonb_build_object(
                                    ''url'', ''http://example.org/fhir/StructureDefinition/bookmarks''
                                ) || 
                                CASE 
                                    WHEN jsonb_array_length(COALESCE(sr.bookmarks, ''[]''::jsonb)) > 0 
                                    THEN jsonb_build_object(''extension'', sr.bookmarks)
                                    ELSE ''{}''::jsonb
                                END AS ext
                                WHERE TRUE
                                UNION ALL
                                SELECT jsonb_build_object(
                                    ''url'', ''http://example.org/fhir/StructureDefinition/locationCode'',
                                    ''valueString'', sr."locationCode"
                                ) AS ext
                                WHERE sr."locationCode" IS NOT NULL AND sr."locationCode" <> ''''
                            ) extensions
                        )
                        ELSE ''[]''::jsonb
                    END,
                ''identifier'', COALESCE(
                    (SELECT jsonb_agg(val)
                     FROM jsonb_array_elements(
                         CASE
                             WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier)
                             WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier
                             ELSE ''[]''::jsonb
                         END
                     ) val
                    ),
                    ''[]''::JSONB
                ),
                ''status'', COALESCE(sr.status::text, ''unknown''),
                ''priority'', COALESCE(sr.priority::text, ''routine''),
                ''code'', COALESCE(sr.code, ''{}''::jsonb),
                ''subject'', jsonb_build_object(
                    ''reference'', ''Patient/'' || pat.id,
                    ''display'', COALESCE(
                        (SELECT TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', ''''))
                         FROM jsonb_array_elements(pat.name) name_parts
                         WHERE jsonb_typeof(pat.name) = ''array''
                         LIMIT 1),
                        ''''
                    )
                ),
                ''occurrenceDateTime'', COALESCE(
                    to_char(sr."occurrence.dateTime", ''YYYY-MM-DD"T"HH24:MI:SS''),
                    ''''
                ),
                ''requester'', CASE 
                    WHEN sr."requester.display" IS NOT NULL AND sr."requester.display" <> ''''
                    THEN jsonb_build_object(
                        ''display'', sr."requester.display"
                    )
                    ELSE jsonb_build_object(
                        ''display'', ''''
                    )
                END,
                ''performer'', CASE 
                    WHEN sr."performer.display" IS NOT NULL AND sr."performer.display" <> ''''
                    THEN jsonb_build_array(
                        jsonb_build_object(
                            ''display'', sr."performer.display"
                        )
                    )
                    ELSE ''[]''::jsonb
                END,
                ''reasonCode'', CASE 
                    WHEN sr.reason IS NOT NULL 
                    THEN jsonb_build_array(sr.reason)
                    ELSE ''[]''::jsonb
                END,
                ''insurance'', CASE
                    WHEN sr.insurance IS NOT NULL AND sr.insurance::text <> ''''
                    THEN jsonb_build_array(jsonb_build_object(''display'', sr.insurance::text))
                    ELSE ''[]''::jsonb
                END,
                ''note'', CASE 
                    WHEN sr.note IS NOT NULL AND sr.note <> '''' 
                    THEN jsonb_build_array(jsonb_build_object(''text'', sr.note)) 
                    ELSE ''[]''::jsonb
                END
            ),
            ''serviceRequestId'', sr.id,
            ''sex'', CASE pat.gender::text WHEN ''female'' THEN ''F'' WHEN ''male'' THEN ''M'' ELSE ''O'' END,
            ''status'', determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text),
            ''studyImageId'', (
                SELECT val->>''value''
                FROM jsonb_array_elements(
                    CASE
                        WHEN jsonb_typeof(imgs.identifier) = ''object'' THEN jsonb_build_array(imgs.identifier)
                        WHEN jsonb_typeof(imgs.identifier) = ''array'' THEN imgs.identifier
                        ELSE ''[]''::jsonb
                    END
                ) val
                WHERE val->>''system'' = ''http://hospital.smarthealth.org/study-id''
                LIMIT 1
            ),
            ''studyImages'', CASE
                WHEN imgs.id IS NULL THEN ''null''::jsonb
                ELSE jsonb_build_object(
                    ''resourceType'', ''ImagingStudy'',
                    ''id'', imgs.id,
                    ''identifier'', COALESCE(imgs.identifier, ''[]''::JSONB),
                    ''status'', COALESCE(imgs.status::text, ''unknown''),
                    ''modality'', jsonb_build_array(
                        jsonb_build_object(
                            ''code'', COALESCE((imgs.modality->>''code''), (sr.modality->''coding''->0->>''code''))
                        )
                    ),
                    ''subject'', jsonb_build_object(''reference'', ''Patient/'' || pat.id),
                    ''started'', COALESCE(imgs.started::text, ''''),
                    ''numberOfInstances'', COALESCE(imgs."numberOfInstances", 0)
                )
            END,
            ''studyName'', (sr.code->''coding''->0->>''display''),
            ''ward'', COALESCE(sr."locationCode", '''')
        ) AS study_data
        FROM public."serviceRequest" sr
        LEFT JOIN public.patient_fhir  pat ON sr.subject   = pat.id
        LEFT JOIN public.practitioner  sr_requester  ON sr.requester = sr_requester.id
        LEFT JOIN public.practitioner  sr_performer  ON sr.performer = sr_performer.id
        LEFT JOIN LATERAL (
            SELECT p.*
            FROM   public.procedure p
            WHERE  p."basedOn" = sr.id
            ORDER  BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
            LIMIT 1
        ) proc ON true
        LEFT JOIN LATERAL (
            SELECT string_agg(
                     format_practitioner_name_sql(pr.name), '', ''
                     ORDER BY format_practitioner_name_sql(pr.name)
                   ) AS radiographer_names
            FROM  jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord)
            JOIN  jsonb_array_elements(proc."performer.actor")    WITH ORDINALITY act(val,ord2)
                     ON ord = ord2
            JOIN  public.practitioner pr
                     ON pr.id = split_part(act.val->>''reference'',''/'',2)
            WHERE EXISTS (
                    SELECT 1
                    FROM   jsonb_array_elements(fn.val->''coding'') c
                    WHERE  c->>''code'' = ''Radiografer''
                  )
        ) proc_radiographers ON true
        LEFT JOIN LATERAL (
            SELECT format_practitioner_name_sql(pr.name) AS operator_name
            FROM  jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord)
            JOIN  jsonb_array_elements(proc."performer.actor")    WITH ORDINALITY act(val,ord2)
                     ON ord = ord2
            JOIN  public.practitioner pr
                     ON pr.id = split_part(act.val->>''reference'',''/'',2)
            WHERE EXISTS (
                    SELECT 1
                    FROM   jsonb_array_elements(fn.val->''coding'') c
                    WHERE  c->>''code'' = ''Operator''
                  )
            LIMIT 1
        ) proc_operator ON true
        LEFT JOIN public.location_fhir proc_location ON proc.location = proc_location.id
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public.practitioner dr_read_pract ON dr."resultsInterpreter" = dr_read_pract.id
        LEFT JOIN public.practitioner dr_assigned_pract ON dr.performer = dr_assigned_pract.id
        LEFT JOIN public."imagingStudy" imgs ON (
            SELECT val->>''value'' FROM jsonb_array_elements(COALESCE(imgs.identifier, ''[]''::jsonb)) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1
        ) = (
            SELECT val->>''value'' FROM jsonb_array_elements(COALESCE(proc.identifier, ''[]''::jsonb)) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1
        ) AND imgs.subject = pat.id
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        LEFT JOIN public.practitioner obs_performer ON obs.performer = obs_performer.id
        LEFT JOIN public.practitioner obs_dose_verificator ON obs.performer = obs_dose_verificator.id
        WHERE 1=1' || v_where_clause || '
        ' || v_order_by || '
        LIMIT ' || p_size || ' OFFSET ' || v_offset || '
    ) study_data_rows';

    EXECUTE v_sql INTO result;

    IF result IS NULL THEN
        result := '[]'::jsonb;
    END IF;

    RETURN jsonb_build_object(
        'rows',       result,
        'totalCount', v_total_count
    );
END;
$function$
