-- (APRIL) Create stock_opname table and indexes (idempotent)
CREATE TABLE IF NOT EXISTS public.stock_opname (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  item_code TEXT NOT NULL,
  item_name TEXT NOT NULL,
  quantity INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  uom TEXT NOT NULL CHECK (uom IN ('pack', 'piece')),
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS stock_opname_item_code_unique_idx
  ON public.stock_opname (lower(item_code));

CREATE INDEX IF NOT EXISTS stock_opname_item_name_idx
  ON public.stock_opname (lower(item_name));

CREATE INDEX IF NOT EXISTS stock_opname_is_deleted_idx
  ON public.stock_opname (is_deleted);

CREATE INDEX IF NOT EXISTS stock_opname_created_at_idx
  ON public.stock_opname (created_at);
