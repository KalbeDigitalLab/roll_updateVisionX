CREATE OR REPLACE FUNCTION public.insert_default_table_view_configuration()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  default_config jsonb := '[
    { "column": "select", "rank": 1, "show": true },
    { "column": "toggleBookmark", "rank": 2, "show": true },
    { "column": "critical", "rank": 3, "show": true },
    { "column": "hasStockOpname", "rank": 4, "show": true },
    { "column": "process", "rank": 5, "show": true },
    { "column": "isExported", "rank": 6, "show": true },
    { "column": "examination", "rank": 7, "show": true },
    { "column": "bookmark", "rank": 8, "show": false },
    { "column": "mrn", "rank": 9, "show": true },
    { "column": "name", "rank": 10, "show": true },
    { "column": "age", "rank": 11, "show": true },
    { "column": "birthDate", "rank": 12, "show": true },
    { "column": "sex", "rank": 13, "show": true },
    { "column": "modality", "rank": 14, "show": true },
    { "column": "ward", "rank": 15, "show": true },
    { "column": "studyName", "rank": 16, "show": true },
    { "column": "clinical", "rank": 17, "show": true },
    { "column": "comment", "rank": 18, "show": true },
    { "column": "insurance", "rank": 19, "show": true },
    { "column": "picDoctor", "rank": 20, "show": true },
    { "column": "referringDoctor", "rank": 21, "show": true },
    { "column": "assignedDoctor", "rank": 22, "show": true },
    { "column": "readDoctor", "rank": 23, "show": true },
    { "column": "accessionNumber", "rank": 24, "show": true },
    { "column": "imageCount", "rank": 25, "show": true },
    { "column": "radiographer", "rank": 26, "show": true },
    { "column": "operator", "rank": 27, "show": true },
    { "column": "doseVerificator", "rank": 28, "show": true },
    { "column": "examRegister", "rank": 29, "show": true },
    { "column": "examImages", "rank": 30, "show": true },
    { "column": "examRead", "rank": 31, "show": true }
  ]'::jsonb;
BEGIN
  INSERT INTO public.table_view_configuration (view_id, "column", rank, show)
  SELECT
    NEW.id,
    elem ->> 'column',
    (elem ->> 'rank')::smallint,
    (elem ->> 'show')::boolean
  FROM jsonb_array_elements(default_config) AS elems(elem);

  RETURN NEW;
END;
$function$;
