-- (APRIL) Add hasStockOpname column to serviceRequest (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'serviceRequest'
      AND column_name = 'hasStockOpname'
  ) THEN
    ALTER TABLE public."serviceRequest"
      ADD COLUMN "hasStockOpname" boolean DEFAULT false;
  END IF;
END$$;
