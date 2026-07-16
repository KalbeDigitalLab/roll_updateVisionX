UPDATE public.table_view_configuration c
SET rank = rank + 1
WHERE c.rank >= 22
  AND c."column" <> 'assignedDoctor'
  AND NOT EXISTS (
    SELECT 1
    FROM public.table_view_configuration existing
    WHERE existing.view_id = c.view_id
      AND existing."column" = 'assignedDoctor'
  );

INSERT INTO public.table_view_configuration (view_id, "column", show, rank)
SELECT b.id, 'assignedDoctor', true, 22
FROM public.table_view_basis b
WHERE NOT EXISTS (
  SELECT 1
  FROM public.table_view_configuration c
  WHERE c.view_id = b.id
    AND c."column" = 'assignedDoctor'
);
