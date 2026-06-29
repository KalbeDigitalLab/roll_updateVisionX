CREATE OR REPLACE FUNCTION public.insert_default_table_view_configuration()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$DECLARE
  default_config JSONB := '[
    {
      "column": "select",
      "rank": 1,
      "show": true
    },
    {
      "column": "toggleBookmark",
      "rank": 2,
      "show": true
    },
    {
      "column": "critical",
      "rank": 3,
      "show": true
    },
    {
      "column": "process",
      "rank": 4,
      "show": true
    },
    {
      "column": "isExported",
      "rank": 5,
      "show": true
    },
    {
      "column": "examination",
      "rank": 6,
      "show": true
    },
    {
      "column": "bookmark",
      "rank": 7,
      "show": false
    },
    {
      "column": "mrn",
      "rank": 8,
      "show": true
    },
    {
      "column": "name",
      "rank": 9,
      "show": true
    },
    {
      "column": "age",
      "rank": 10,
      "show": true
    },
    {
      "column": "birthDate",
      "rank": 11,
      "show": true
    },
    {
      "column": "sex",
      "rank": 12,
      "show": true
    },
    {
      "column": "modality",
      "rank": 13,
      "show": true
    },
    {
      "column": "ward",
      "rank": 14,
      "show": true
    },
    {
      "column": "studyName",
      "rank": 15,
      "show": true
    },
    {
      "column": "clinical",
      "rank": 16,
      "show": true
    },
    {
      "column": "comment",
      "rank": 17,
      "show": true
    },
    {
      "column": "insurance",
      "rank": 18,
      "show": true
    },
    {
      "column": "picDoctor",
      "rank": 19,
      "show": true
    },
    {
      "column": "referringDoctor",
      "rank": 20,
      "show": true
    },
    {
      "column": "readDoctor",
      "rank": 21,
      "show": true
    },
    {
      "column": "accessionNumber",
      "rank": 22,
      "show": true
    },
    {
      "column": "imageCount",
      "rank": 23,
      "show": true
    },
    {
      "column": "radiographer",
      "rank": 24,
      "show": true
    },
    {
      "column": "operator",
      "rank": 25,
      "show": true
    },
    {
      "column": "doseVerificator",
      "rank": 26,
      "show": true
    },
    {
      "column": "examRegister",
      "rank": 27,
      "show": true
    },
    {
      "column": "examImages",
      "rank": 28,
      "show": true
    },
    {
      "column": "examRead",
      "rank": 29,
      "show": true
    }
  ]';
BEGIN
  INSERT INTO public.table_view_configuration (
    view_id,
    "column",    -- must be double-quoted because itΓÇÖs a reserved word
    rank,
    show
  )
  SELECT
    NEW.id,
    elem ->> 'column',             -- extract the JSON ΓÇ£columnΓÇ¥ value
    (elem ->> 'rank')::smallint,    -- extract + cast the JSON ΓÇ£rankΓÇ¥
    (elem ->> 'show')::boolean
  FROM jsonb_array_elements(default_config) AS elems(elem);

  RETURN NEW;
END;$function$
