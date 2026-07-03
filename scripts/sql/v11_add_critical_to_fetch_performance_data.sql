CREATE OR REPLACE FUNCTION public.fetch_performance_data(p_user_id text DEFAULT NULL::text, p_index integer DEFAULT 0, p_size integer DEFAULT 50, p_column_filters jsonb DEFAULT '[]'::jsonb, p_sorting jsonb DEFAULT '[]'::jsonb)
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
    v_user_filter   text := '';
    v_date_filter   jsonb;
BEGIN
    /* ───────── offset ───────── */
    v_offset := p_index * p_size;

    /* ─────── convert filters and extract examination filter ─────── */
    FOR filter_item IN SELECT * FROM jsonb_array_elements(p_column_filters) LOOP
        -- Check if this is the examination filter
        IF filter_item->>'id' = 'examination' THEN
            IF jsonb_typeof(filter_item->'value') = 'object' THEN
                v_date_filter := filter_item->'value';
            END IF;
        ELSE
            -- Build the filters object for other filters
            v_filters := v_filters || jsonb_build_object(filter_item->>'id', filter_item->'value');
        END IF;
    END LOOP;

    /* ───────── user filter for non-admin access ───────── */
    IF p_user_id IS NOT NULL THEN
        v_user_filter := ' AND (perf.radiographer_id LIKE ''%'' || ''' || p_user_id || ''' || ''%'' OR perf.read_doctor_id LIKE ''%'' || ''' || p_user_id || ''' || ''%'')';
    END IF;

    /* ───────── sort builder ───────── */
    IF jsonb_array_length(p_sorting) > 0 THEN
        v_order_by := ' ORDER BY ';
        FOR sort_item IN SELECT * FROM jsonb_array_elements(p_sorting) LOOP
            IF v_order_by <> ' ORDER BY ' THEN
                v_order_by := v_order_by || ', ';
            END IF;

            v_order_by := v_order_by ||
                CASE sort_item->>'id'
                    -- Performance-specific columns
                    WHEN 'startExam'       THEN 'perf.start_exam'
                    WHEN 'endExam'         THEN 'perf.end_exam'
                    WHEN 'startReport'     THEN 'perf.start_report'
                    WHEN 'endReport'       THEN 'perf.end_report'
                    WHEN 'examDuration'    THEN '(EXTRACT(EPOCH FROM (perf.end_exam::timestamp - perf.start_exam::timestamp)) * 1000)'
                    WHEN 'reportDuration'  THEN '(EXTRACT(EPOCH FROM (perf.end_report::timestamp - perf.start_report::timestamp)) * 1000)'
                    WHEN 'totalDuration'   THEN '((EXTRACT(EPOCH FROM (perf.end_exam::timestamp - perf.start_exam::timestamp)) + EXTRACT(EPOCH FROM (perf.end_report::timestamp - perf.start_report::timestamp))) * 1000)'
                    -- Standard study columns
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
                    ELSE 'perf.accession_number'
                END || ' ' ||
                CASE
                    WHEN (sort_item->'desc')::text = 'true'  THEN 'DESC'
                    WHEN (sort_item->'desc')::text = 'false' THEN 'ASC'
                    ELSE 'DESC'
                END || ' NULLS LAST';
        END LOOP;
    ELSE
        v_order_by := ' ORDER BY perf.accession_number ASC';
    END IF;

    /* ───────── filters (WHERE) ───────── */
    v_where_clause := '';
    
    -- Apply examination date filter if present
    IF v_date_filter IS NOT NULL AND v_date_filter->>'type' = 'dateRange' THEN
        IF v_date_filter->>'start' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND sr."occurrence.dateTime" >= ''' || (v_date_filter->>'start') || '''::timestamp';
        END IF;
        IF v_date_filter->>'end' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND sr."occurrence.dateTime" <= ''' || (v_date_filter->>'end') || '''::timestamp';
        END IF;
    END IF;
    
    IF v_filters != '{}'::jsonb THEN
        -- Performance-specific filters
        IF v_filters->>'startExam' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'startExam') = 'object' AND (v_filters->'startExam'->>'type') = 'dateRange' THEN
                IF v_filters->'startExam'->>'start' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND perf.start_exam >= ''' || (v_filters->'startExam'->>'start') || '''::timestamp';
                END IF;
                IF v_filters->'startExam'->>'end' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND perf.start_exam <= ''' || (v_filters->'startExam'->>'end') || '''::timestamp';
                END IF;
            END IF;
        END IF;

        IF v_filters->>'endExam' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'endExam') = 'object' AND (v_filters->'endExam'->>'type') = 'dateRange' THEN
                IF v_filters->'endExam'->>'start' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND perf.end_exam >= ''' || (v_filters->'endExam'->>'start') || '''::timestamp';
                END IF;
                IF v_filters->'endExam'->>'end' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND perf.end_exam <= ''' || (v_filters->'endExam'->>'end') || '''::timestamp';
                END IF;
            END IF;
        END IF;

        IF v_filters->>'startReport' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'startReport') = 'object' AND (v_filters->'startReport'->>'type') = 'dateRange' THEN
                IF v_filters->'startReport'->>'start' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND perf.start_report >= ''' || (v_filters->'startReport'->>'start') || '''::timestamp';
                END IF;
                IF v_filters->'startReport'->>'end' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND perf.start_report <= ''' || (v_filters->'startReport'->>'end') || '''::timestamp';
                END IF;
            END IF;
        END IF;

        IF v_filters->>'endReport' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'endReport') = 'object' AND (v_filters->'endReport'->>'type') = 'dateRange' THEN
                IF v_filters->'endReport'->>'start' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND perf.end_report >= ''' || (v_filters->'endReport'->>'start') || '''::timestamp';
                END IF;
                IF v_filters->'endReport'->>'end' IS NOT NULL THEN
                    v_where_clause := v_where_clause || ' AND perf.end_report <= ''' || (v_filters->'endReport'->>'end') || '''::timestamp';
                END IF;
            END IF;
        END IF;

        -- Standard filters (same as original function)
        IF v_filters->>'accessionNumber' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('(SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier) WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1)',
                                v_filters->'accessionNumber', FALSE);
        END IF;

        IF v_filters->>'mrn' IS NOT NULL THEN
            IF jsonb_typeof(v_filters->'mrn') = 'array' THEN
                v_where_clause := v_where_clause || ' AND LOWER((SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' LIMIT 1)) = ANY(SELECT LOWER(jsonb_array_elements_text(''' || (v_filters->'mrn')::text || '''::jsonb)))';
            ELSE
                v_where_clause := v_where_clause || ' AND (SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' LIMIT 1) ILIKE ''%'' || ''' || (v_filters->>'mrn') || ''' || ''%''';
            END IF;
        END IF;

        IF v_filters->>'name' IS NOT NULL THEN
            v_where_clause := v_where_clause || ' AND ' ||
                _ilike_predicate('(SELECT string_agg(TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', '''')), '', '') FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(pat.name) = ''array'' AND jsonb_array_length(pat.name) > 0)',
                                v_filters->'name', FALSE);
        END IF;

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

        -- Add other filters as needed from the original function...
    END IF;

    /* ───────── total-count query ───────── */
    v_sql := '
    SELECT COUNT(*)
    FROM public.performance perf
    INNER JOIN public."serviceRequest" sr ON perf.service_request_id = sr.id
    LEFT JOIN public.patient_fhir pat ON sr.subject = pat.id
    LEFT JOIN public.practitioner sr_requester ON sr.requester = sr_requester.id
    LEFT JOIN public.practitioner sr_performer ON sr.performer = sr_performer.id
    LEFT JOIN LATERAL (
        SELECT p.*
        FROM   public.procedure p
        WHERE  p."basedOn" = sr.id
        ORDER  BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC
        LIMIT  1
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
    LEFT JOIN public."imagingStudy" imgs
           ON (
                SELECT val->>''value''
                FROM   jsonb_array_elements(COALESCE(imgs.identifier,''[]''::jsonb)) val
                WHERE  val->>''system'' = ''http://hospital.smarthealth.org/accession''
                LIMIT 1
              )
           =
              (
                SELECT val->>''value''
                FROM   jsonb_array_elements(COALESCE(proc.identifier,''[]''::jsonb)) val
                WHERE  val->>''system'' = ''http://hospital.smarthealth.org/accession''
                LIMIT 1
              )
          AND imgs.subject = pat.id
    LEFT JOIN public.observation obs ON obs."partOf" = proc.id
    LEFT JOIN public.practitioner obs_performer ON obs.performer = obs_performer.id
    LEFT JOIN public.practitioner obs_dose_verificator ON obs.performer = obs_dose_verificator.id
    WHERE 1=1' || v_where_clause || v_user_filter;

    EXECUTE v_sql INTO v_total_count;

    /* ───────── paginated-data query with performance data ───────── */
    v_sql := '
    WITH ordered_performance AS (
        SELECT perf.*, sr.id as sr_id
        FROM public.performance perf
        INNER JOIN public."serviceRequest" sr ON perf.service_request_id = sr.id
        LEFT JOIN public.patient_fhir pat ON sr.subject = pat.id
        LEFT JOIN public.practitioner sr_requester ON sr.requester = sr_requester.id
        LEFT JOIN public.practitioner sr_performer ON sr.performer = sr_performer.id
        LEFT JOIN LATERAL (SELECT p.* FROM public.procedure p WHERE p."basedOn" = sr.id ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC LIMIT 1) proc ON true
        LEFT JOIN LATERAL (SELECT string_agg(format_practitioner_name_sql(pr.name), '', '') AS radiographer_names FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord) JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(val,ord2) ON ord = ord2 JOIN public.practitioner pr ON pr.id = split_part(act.val->>''reference'',''/'',2) WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(fn.val->''coding'') c WHERE c->>''code'' = ''Radiografer'')) proc_radiographers ON true
        LEFT JOIN LATERAL (SELECT format_practitioner_name_sql(pr.name) AS operator_name FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord) JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(val,ord2) ON ord = ord2 JOIN public.practitioner pr ON pr.id = split_part(act.val->>''reference'',''/'',2) WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(fn.val->''coding'') c WHERE c->>''code'' = ''Operator'') LIMIT 1) proc_operator ON true
        LEFT JOIN public.location_fhir proc_location ON proc.location = proc_location.id
        LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
        LEFT JOIN public.practitioner dr_read_pract ON dr."resultsInterpreter" = dr_read_pract.id
        LEFT JOIN public.practitioner dr_assigned_pract ON dr.performer = dr_assigned_pract.id
        LEFT JOIN public."imagingStudy" imgs ON (SELECT val->>''value'' FROM jsonb_array_elements(COALESCE(imgs.identifier,''[]''::jsonb)) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1) = (SELECT val->>''value'' FROM jsonb_array_elements(COALESCE(proc.identifier,''[]''::jsonb)) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1) AND imgs.subject = pat.id
        LEFT JOIN public.observation obs ON obs."partOf" = proc.id
        LEFT JOIN public.practitioner obs_performer ON obs.performer = obs_performer.id
        LEFT JOIN public.practitioner obs_dose_verificator ON obs.performer = obs_dose_verificator.id
        WHERE 1=1 ' || v_where_clause || v_user_filter || '
        ' || v_order_by || '
        LIMIT ' || p_size || ' OFFSET ' || v_offset || '
    )
    SELECT jsonb_agg(performance_data_rows.performance_data)
    FROM (
        SELECT
          jsonb_build_object(
            -- Performance-specific fields
            ''startExam'', perf.start_exam,
            ''endExam'', perf.end_exam,
            ''startReport'', perf.start_report,
            ''endReport'', perf.end_report,
            ''examDuration'', EXTRACT(EPOCH FROM (perf.end_exam::timestamp - perf.start_exam::timestamp)) * 1000,
            ''reportDuration'', EXTRACT(EPOCH FROM (perf.end_report::timestamp - perf.start_report::timestamp)) * 1000,
            ''totalDuration'', (EXTRACT(EPOCH FROM (perf.end_exam::timestamp - perf.start_exam::timestamp)) + EXTRACT(EPOCH FROM (perf.end_report::timestamp - perf.start_report::timestamp))) * 1000,
            -- Standard study fields
            ''accessionNumber'', (SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(sr.identifier) = ''object'' THEN jsonb_build_array(sr.identifier) WHEN jsonb_typeof(sr.identifier) = ''array'' THEN sr.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1),
            ''age'', calculate_age_sql(sr."occurrence.dateTime", pat."birthDate"),
            ''assignedDoctor'', CASE WHEN COALESCE(dr."isAllDoctor", false) THEN ''All Doctor'' ELSE format_practitioner_name_sql(dr_assigned_pract.name) END,
            ''birthDate'', format_date_sql(pat."birthDate", true),
            ''cito'', to_jsonb(sr.priority::text = ''stat''),
            ''critical'', COALESCE(dr.critical, false),
            ''clinical'', (sr.reason->''coding''->0->>''display''),
            ''comment'', sr.note,
            ''doseVerificator'', COALESCE(format_practitioner_name_sql(obs_dose_verificator.name), ''''),
            ''examImages'', format_date_sql(imgs.started, false),
            ''examRead'', COALESCE(format_date_sql(dr."effective.dateTime", false), ''''),
            ''examRegister'', format_date_sql(proc."performedDateTime", false),
            ''examination'', format_date_sql(sr."occurrence.dateTime", false),
            ''imageCount'', COALESCE(imgs."numberOfInstances", 0),
            ''insurance'', COALESCE(sr.insurance::text, ''''),
            ''isExported'', COALESCE((sr."isExported")::boolean, false),
            ''modality'', (sr.modality->''coding''->0->>''code''),
            ''mrn'', (SELECT val->>''value'' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pat.identifier) = ''object'' THEN jsonb_build_array(pat.identifier) WHEN jsonb_typeof(pat.identifier) = ''array'' THEN pat.identifier ELSE ''[]''::jsonb END) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/mrn'' LIMIT 1),
            ''name'', (SELECT string_agg(TRIM(BOTH '' '' FROM COALESCE(name_parts->''given''->>0, '''') || '' '' || COALESCE(name_parts->>''family'', '''')),'', '') FROM jsonb_array_elements(pat.name) name_parts WHERE jsonb_typeof(pat.name) = ''array'' AND jsonb_array_length(pat.name) > 0),
            ''operator'', COALESCE(proc_operator.operator_name, ''''),
            ''picDoctor'', COALESCE(sr."performer.display", ''''),
            ''radiographer'', COALESCE(proc_radiographers.radiographer_names, ''''),
            ''readDoctor'', COALESCE(format_practitioner_name_sql(dr_read_pract.name), ''''),
            ''referringDoctor'', COALESCE(sr."requester.display", ''''),
            ''sex'', CASE pat.gender::text WHEN ''female'' THEN ''F'' WHEN ''male'' THEN ''M'' ELSE ''O'' END,
            ''status'', determine_status_sql(sr.status::text, dr.status::text, obs.status::text, proc.status::text, imgs.status::text),
            ''studyName'', (sr.code->''coding''->0->>''display''),
            ''ward'', COALESCE(sr."locationCode", ''''),
            -- IDs for reference
            ''serviceRequestId'', sr.id,
            ''patientId'', pat.id,
            ''procedureId'', proc.id,
            ''diagnosticReportId'', dr.id,
            ''imagingStudyId'', imgs.id,
            ''observationId'', obs.id
        ) AS performance_data
        FROM
            ordered_performance perf
            JOIN public."serviceRequest" sr ON perf.sr_id = sr.id
            LEFT JOIN public.patient_fhir pat ON sr.subject = pat.id
            LEFT JOIN public.practitioner sr_requester ON sr.requester = sr_requester.id
            LEFT JOIN public.practitioner sr_performer ON sr.performer = sr_performer.id
            LEFT JOIN LATERAL (SELECT p.* FROM public.procedure p WHERE p."basedOn" = sr.id ORDER BY p."performedDateTime" DESC NULLS LAST, p.created_at DESC LIMIT 1) proc ON true
            LEFT JOIN LATERAL (SELECT string_agg(format_practitioner_name_sql(pr.name), '', '') AS radiographer_names FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord) JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(val,ord2) ON ord = ord2 JOIN public.practitioner pr ON pr.id = split_part(act.val->>''reference'',''/'',2) WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(fn.val->''coding'') c WHERE c->>''code'' = ''Radiografer'')) proc_radiographers ON true
            LEFT JOIN LATERAL (SELECT format_practitioner_name_sql(pr.name) AS operator_name FROM jsonb_array_elements(proc."performer.function") WITH ORDINALITY fn(val,ord) JOIN jsonb_array_elements(proc."performer.actor") WITH ORDINALITY act(val,ord2) ON ord = ord2 JOIN public.practitioner pr ON pr.id = split_part(act.val->>''reference'',''/'',2) WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(fn.val->''coding'') c WHERE c->>''code'' = ''Operator'') LIMIT 1) proc_operator ON true
            LEFT JOIN public.location_fhir proc_location ON proc.location = proc_location.id
            LEFT JOIN public."diagnosticReport" dr ON dr."basedOn" = sr.id
            LEFT JOIN public.practitioner dr_read_pract ON dr."resultsInterpreter" = dr_read_pract.id
            LEFT JOIN public.practitioner dr_assigned_pract ON dr.performer = dr_assigned_pract.id
            LEFT JOIN public."imagingStudy" imgs ON (SELECT val->>''value'' FROM jsonb_array_elements(COALESCE(imgs.identifier,''[]''::jsonb)) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1) = (SELECT val->>''value'' FROM jsonb_array_elements(COALESCE(proc.identifier,''[]''::jsonb)) val WHERE val->>''system'' = ''http://hospital.smarthealth.org/accession'' LIMIT 1) AND imgs.subject = pat.id
            LEFT JOIN public.observation obs ON obs."partOf" = proc.id
            LEFT JOIN public.practitioner obs_performer ON obs.performer = obs_performer.id
            LEFT JOIN public.practitioner obs_dose_verificator ON obs.performer = obs_dose_verificator.id
        ' || v_order_by || '
    ) performance_data_rows';

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
