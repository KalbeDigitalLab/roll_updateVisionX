-- ============================================================
-- Migration: Stock Opname Transaction
-- ============================================================

-- 1. Create stock_opname_transaction table
-- (hasStockOpname column already exists on serviceRequest)
CREATE TABLE IF NOT EXISTS public.stock_opname_transaction (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  stock_opname_id uuid NOT NULL
    REFERENCES public.stock_opname(id) ON DELETE RESTRICT,
  service_request_id text
    REFERENCES public."serviceRequest"(id) ON DELETE CASCADE,
  practitioner_id text NOT NULL
    REFERENCES public.practitioner(id) ON DELETE RESTRICT,
  quantity_used integer NOT NULL CHECK (quantity_used > 0),
  created_at timestamptz DEFAULT now() NOT NULL,
  transaction_type text NOT NULL DEFAULT 'use'
    CHECK (transaction_type IN ('use', 'add', 'reduce'))
);

CREATE INDEX IF NOT EXISTS idx_sot_stock_opname_id
  ON public.stock_opname_transaction (stock_opname_id);

CREATE INDEX IF NOT EXISTS idx_sot_service_request_id
  ON public.stock_opname_transaction (service_request_id);

CREATE INDEX IF NOT EXISTS idx_sot_practitioner_id
  ON public.stock_opname_transaction (practitioner_id);

CREATE INDEX IF NOT EXISTS idx_sot_created_at
  ON public.stock_opname_transaction (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_sot_transaction_type
  ON public.stock_opname_transaction (transaction_type);

-- 2. Batch atomic deduction RPC
-- Locks rows in UUID order (prevents deadlocks).
-- Validates ALL items first; deducts ALL or NONE.
CREATE OR REPLACE FUNCTION public.batch_deduct_stock_opname_items(
  p_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  item jsonb;
  v_qty integer;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  FOR item IN
    SELECT value
    FROM jsonb_array_elements(p_items) AS t(value)
    ORDER BY (value->>'item_id')
  LOOP
    SELECT quantity INTO v_qty
    FROM public.stock_opname
    WHERE id = (item->>'item_id')::uuid
      AND is_deleted = false
    FOR UPDATE;

    IF NOT FOUND THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'item_id', item->>'item_id',
          'message', 'Item not found or has been archived'
        )
      );
    ELSIF v_qty < (item->>'amount')::integer THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'item_id', item->>'item_id',
          'message', format('Insufficient stock: only %s available', v_qty),
          'available', v_qty
        )
      );
    END IF;
  END LOOP;

  IF jsonb_array_length(v_errors) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errors', v_errors);
  END IF;

  FOR item IN
    SELECT value
    FROM jsonb_array_elements(p_items) AS t(value)
  LOOP
    UPDATE public.stock_opname
    SET quantity = quantity - (item->>'amount')::integer,
        updated_at = now()
    WHERE id = (item->>'item_id')::uuid;
  END LOOP;

  RETURN jsonb_build_object('success', true);
END;
$$;

-- 3. Enable Supabase Realtime replication for stock_opname
-- (Required for live quantity updates in the UI)
-- Run this once if not already done:
-- ALTER PUBLICATION supabase_realtime ADD TABLE public.stock_opname;

-- 4. Backward-compatible extension for existing tables
ALTER TABLE public.stock_opname_transaction
  ADD COLUMN IF NOT EXISTS transaction_type text NOT NULL DEFAULT 'use'
    CHECK (transaction_type IN ('use', 'add', 'reduce')),
  ALTER COLUMN service_request_id DROP NOT NULL;

-- 5. Stock restore RPC — adds quantity back (used when editing/removing usages)
CREATE OR REPLACE FUNCTION public.batch_restore_stock_opname_items(
  p_items jsonb
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  item jsonb;
BEGIN
  FOR item IN
    SELECT value
    FROM jsonb_array_elements(p_items) AS t(value)
  LOOP
    UPDATE public.stock_opname
    SET quantity = quantity + (item->>'amount')::integer,
        updated_at = now()
    WHERE id = (item->>'item_id')::uuid;
  END LOOP;
END;
$$;
