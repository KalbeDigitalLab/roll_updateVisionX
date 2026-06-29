-- RPC for server-side patient table search.
-- Uses the flattened FHIR patient table `public.patient_fhir`.

create or replace function public.get_patients(
  p_column_filters jsonb default '[]'::jsonb,
  p_sorting jsonb default '[]'::jsonb,
  p_index integer default 0,
  p_size integer default 10
)
returns jsonb
language plpgsql
security invoker
as $$
declare
  v_rows jsonb := '[]'::jsonb;
  v_total_count bigint := 0;
  v_offset integer;
  v_filters jsonb := '{}'::jsonb;
  filter_item jsonb;
  sort_item jsonb;
  v_order_by text := '';
  v_where_clause text := '';
  v_sql text;
begin
  v_offset := greatest(coalesce(p_index, 0), 0) * greatest(coalesce(p_size, 10), 1);

  for filter_item in
    select *
    from jsonb_array_elements(coalesce(p_column_filters, '[]'::jsonb))
  loop
    if
      filter_item ? 'id'
      and filter_item ? 'value'
      and nullif(trim(filter_item ->> 'value'), '') is not null
    then
      v_filters := v_filters || jsonb_build_object(filter_item ->> 'id', trim(filter_item ->> 'value'));
    end if;
  end loop;

  if v_filters ? 'search' then
    v_where_clause := v_where_clause || format(
      ' and (np.mrn ilike %L or np.patient_name ilike %L)',
      '%' || (v_filters ->> 'search') || '%',
      '%' || (v_filters ->> 'search') || '%'
    );
  end if;

  if v_filters ? 'mrn' then
    v_where_clause := v_where_clause || format(' and np.mrn ilike %L', '%' || (v_filters ->> 'mrn') || '%');
  end if;

  if v_filters ? 'name' then
    v_where_clause := v_where_clause || format(' and np.patient_name ilike %L', '%' || (v_filters ->> 'name') || '%');
  end if;

  if v_filters ? 'gender' then
    if upper(v_filters ->> 'gender') = 'M' then
      v_where_clause := v_where_clause || ' and np.gender = ''male''';
    elsif upper(v_filters ->> 'gender') = 'F' then
      v_where_clause := v_where_clause || ' and np.gender = ''female''';
    elsif upper(v_filters ->> 'gender') = 'O' then
      v_where_clause := v_where_clause || ' and np.gender in (''other'', ''unknown'')';
    else
      v_where_clause := v_where_clause || format(' and np.gender ilike %L', '%' || (v_filters ->> 'gender') || '%');
    end if;
  end if;

  if v_filters ? 'birthDate' then
    v_where_clause := v_where_clause || format(' and np.birth_date ilike %L', '%' || (v_filters ->> 'birthDate') || '%');
  end if;

  if v_filters ? 'mrnExact' then
    v_where_clause := v_where_clause || format(' and lower(np.mrn) = lower(%L)', v_filters ->> 'mrnExact');
  end if;

  for sort_item in
    select *
    from jsonb_array_elements(coalesce(p_sorting, '[]'::jsonb))
  loop
    if (sort_item ->> 'id') in ('mrn', 'name', 'gender', 'birthDate') then
      if v_order_by <> '' then
        v_order_by := v_order_by || ', ';
      end if;

      v_order_by := v_order_by
        || case sort_item ->> 'id'
          when 'mrn' then 'np.mrn'
          when 'name' then 'np.patient_name'
          when 'gender' then 'np.gender'
          when 'birthDate' then 'np.birth_date'
        end
        || case when coalesce((sort_item ->> 'desc')::boolean, false) then ' desc' else ' asc' end;
    end if;
  end loop;

  if v_order_by = '' then
    v_order_by := 'np.patient_name asc, np.mrn asc, np.id asc';
  else
    v_order_by := v_order_by || ', np.patient_name asc, np.mrn asc, np.id asc';
  end if;

  v_sql := '
    with normalized_patients as (
      select
        p.id,
        coalesce(
          nullif(trim(p.identifier ->> ''value''), ''''),
          nullif(trim(p.id), ''''),
          ''''
        ) as mrn,
        trim(
          coalesce(
            p.name -> 0 ->> ''text'',
            concat_ws(
              '' '',
              array_to_string(
                array(
                  select jsonb_array_elements_text(coalesce((p.name -> 0 -> ''given'')::jsonb, ''[]''::jsonb))
                ),
                '' ''
              ),
              p.name -> 0 ->> ''family''
            ),
            ''''
          )
        ) as patient_name,
        coalesce(p.gender::text, ''unknown'') as gender,
        coalesce(p."birthDate"::text, '''') as birth_date
      from public.patient_fhir p
    )
    select count(*)
    from normalized_patients np
    where 1 = 1'
    || v_where_clause;

  execute v_sql into v_total_count;

  v_sql := '
    with normalized_patients as (
      select
        p.id,
        coalesce(
          nullif(trim(p.identifier ->> ''value''), ''''),
          nullif(trim(p.id), ''''),
          ''''
        ) as mrn,
        trim(
          coalesce(
            p.name -> 0 ->> ''text'',
            concat_ws(
              '' '',
              array_to_string(
                array(
                  select jsonb_array_elements_text(coalesce((p.name -> 0 -> ''given'')::jsonb, ''[]''::jsonb))
                ),
                '' ''
              ),
              p.name -> 0 ->> ''family''
            ),
            ''''
          )
        ) as patient_name,
        coalesce(p.gender::text, ''unknown'') as gender,
        coalesce(p."birthDate"::text, '''') as birth_date
      from public.patient_fhir p
    )
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          ''id'', paged_patients.id,
          ''mrn'', paged_patients.mrn,
          ''name'', paged_patients.patient_name,
          ''gender'', paged_patients.gender,
          ''birthDate'', paged_patients.birth_date
        )
      ),
      ''[]''::jsonb
    )
    from (
      select np.*
      from normalized_patients np
      where 1 = 1'
      || v_where_clause
      || ' order by '
      || v_order_by
      || format(' limit %s offset %s', greatest(coalesce(p_size, 10), 1), v_offset)
      || '
    ) as paged_patients';

  execute v_sql into v_rows;

  return jsonb_build_object(
    'rows', coalesce(v_rows, '[]'::jsonb),
    'totalCount', coalesce(v_total_count, 0)
  );
end;
$$;
