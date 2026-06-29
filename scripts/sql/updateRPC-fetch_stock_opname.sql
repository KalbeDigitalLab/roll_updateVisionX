CREATE OR REPLACE FUNCTION public.fetch_stock_opname(
  p_column_filters JSONB DEFAULT '[]'::jsonb,
  p_sorting JSONB DEFAULT '[]'::jsonb,
  p_index INTEGER DEFAULT 0,
  p_size INTEGER DEFAULT 10,
  p_show_deleted BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_rows JSONB := '[]'::jsonb;
  v_total_count BIGINT := 0;
  v_offset INTEGER;
  v_filters JSONB := '{}'::jsonb;
  filter_item JSONB;
  sort_item JSONB;
  v_order_by TEXT := '';
  v_where_clause TEXT := '';
  v_sql TEXT;
BEGIN
  v_offset := greatest(coalesce(p_index, 0), 0) * greatest(coalesce(p_size, 10), 1);

  FOR filter_item IN
    SELECT *
    FROM jsonb_array_elements(coalesce(p_column_filters, '[]'::jsonb))
  LOOP
    IF
      filter_item ? 'id'
      AND filter_item ? 'value'
      AND jsonb_typeof(filter_item -> 'value') = 'string'
      AND nullif(trim(filter_item ->> 'value'), '') IS NOT NULL
    THEN
      v_filters := v_filters || jsonb_build_object(filter_item ->> 'id', trim(filter_item ->> 'value'));
    ELSIF
      filter_item ? 'id'
      AND filter_item ? 'value'
      AND jsonb_typeof(filter_item -> 'value') <> 'null'
    THEN
      v_filters := v_filters || jsonb_build_object(filter_item ->> 'id', filter_item -> 'value');
    END IF;
  END LOOP;

  IF NOT coalesce(p_show_deleted, FALSE) THEN
    v_where_clause := v_where_clause || ' AND so.is_deleted = FALSE';
  END IF;

  IF v_filters ? 'is_deleted' THEN
    IF lower(v_filters ->> 'is_deleted') = 'deleted' THEN
      v_where_clause := v_where_clause || ' AND so.is_deleted = TRUE';
    ELSIF lower(v_filters ->> 'is_deleted') = 'active' THEN
      v_where_clause := v_where_clause || ' AND so.is_deleted = FALSE';
    END IF;
  END IF;

  IF v_filters ? 'item_code' THEN
    v_where_clause := v_where_clause || format(
      ' AND so.item_code ILIKE %L',
      '%' || (v_filters ->> 'item_code') || '%'
    );
  END IF;

  IF v_filters ? 'item_name' THEN
    v_where_clause := v_where_clause || format(
      ' AND so.item_name ILIKE %L',
      '%' || (v_filters ->> 'item_name') || '%'
    );
  END IF;

  IF v_filters ? 'quantity' THEN
    v_where_clause := v_where_clause || format(
      ' AND so.quantity::text ILIKE %L',
      '%' || (v_filters ->> 'quantity') || '%'
    );
  END IF;

  IF v_filters ? 'uom' THEN
    v_where_clause := v_where_clause || format(
      ' AND lower(so.uom) = lower(%L)',
      v_filters ->> 'uom'
    );
  END IF;

  IF v_filters ? 'created_at' THEN
    IF jsonb_typeof(v_filters -> 'created_at') = 'object' THEN
      IF (v_filters -> 'created_at' ->> 'start') IS NOT NULL THEN
        v_where_clause := v_where_clause || format(
          ' AND so.created_at >= %L::timestamptz',
          v_filters -> 'created_at' ->> 'start'
        );
      END IF;

      IF (v_filters -> 'created_at' ->> 'end') IS NOT NULL THEN
        v_where_clause := v_where_clause || format(
          ' AND so.created_at <= %L::timestamptz',
          v_filters -> 'created_at' ->> 'end'
        );
      END IF;
    ELSE
      CASE v_filters ->> 'created_at'
        WHEN 'Today' THEN
          v_where_clause := v_where_clause || ' AND so.created_at >= CURRENT_DATE AND so.created_at < CURRENT_DATE + INTERVAL ''1 day''';
        WHEN 'Yesterday' THEN
          v_where_clause := v_where_clause || ' AND so.created_at >= CURRENT_DATE - 1 AND so.created_at < CURRENT_DATE';
        WHEN 'Last 7 Days' THEN
          v_where_clause := v_where_clause || ' AND so.created_at >= CURRENT_DATE - 7 AND so.created_at < CURRENT_DATE + INTERVAL ''1 day''';
        WHEN '1 Month' THEN
          v_where_clause := v_where_clause || ' AND so.created_at >= CURRENT_TIMESTAMP - INTERVAL ''1 month''';
        WHEN '1 Year' THEN
          v_where_clause := v_where_clause || ' AND so.created_at >= CURRENT_TIMESTAMP - INTERVAL ''1 year''';
        ELSE NULL;
      END CASE;
    END IF;
  END IF;

  FOR sort_item IN
    SELECT *
    FROM jsonb_array_elements(coalesce(p_sorting, '[]'::jsonb))
  LOOP
    IF (sort_item ->> 'id') IN ('item_code', 'item_name', 'quantity', 'uom', 'created_at', 'updated_at') THEN
      IF v_order_by <> '' THEN
        v_order_by := v_order_by || ', ';
      END IF;

      v_order_by := v_order_by
        || CASE sort_item ->> 'id'
          WHEN 'item_code' THEN 'so.item_code'
          WHEN 'item_name' THEN 'so.item_name'
          WHEN 'quantity' THEN 'so.quantity'
          WHEN 'uom' THEN 'so.uom'
          WHEN 'created_at' THEN 'so.created_at'
          WHEN 'updated_at' THEN 'so.updated_at'
        END
        || CASE WHEN coalesce((sort_item ->> 'desc')::boolean, FALSE) THEN ' DESC' ELSE ' ASC' END;
    END IF;
  END LOOP;

  IF v_order_by = '' THEN
    v_order_by := 'so.item_name ASC, so.item_code ASC, so.id ASC';
  ELSE
    v_order_by := v_order_by || ', so.item_name ASC, so.item_code ASC, so.id ASC';
  END IF;

  v_sql := '
    SELECT count(*)
    FROM public.stock_opname so
    WHERE 1 = 1'
    || v_where_clause;

  EXECUTE v_sql INTO v_total_count;

  v_sql := '
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          ''id'', paged_stock.id,
          ''item_code'', paged_stock.item_code,
          ''item_name'', paged_stock.item_name,
          ''quantity'', paged_stock.quantity,
          ''uom'', paged_stock.uom,
          ''is_deleted'', paged_stock.is_deleted,
          ''created_at'', paged_stock.created_at,
          ''updated_at'', paged_stock.updated_at
        )
      ),
      ''[]''::jsonb
    )
    FROM (
      SELECT
        so.id,
        so.item_code,
        so.item_name,
        so.quantity,
        so.uom,
        so.is_deleted,
        so.created_at,
        so.updated_at
      FROM public.stock_opname so
      WHERE 1 = 1'
      || v_where_clause
      || ' ORDER BY '
      || v_order_by
      || format(' LIMIT %s OFFSET %s', greatest(coalesce(p_size, 10), 1), v_offset)
      || '
    ) AS paged_stock';

  EXECUTE v_sql INTO v_rows;

  RETURN jsonb_build_object(
    'rows', coalesce(v_rows, '[]'::jsonb),
    'totalCount', coalesce(v_total_count, 0)
  );
END;
$$;
