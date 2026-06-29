-- (APRIL) Create report_dictionary table and indexes (idempotent)
CREATE TABLE IF NOT EXISTS public."report_dictionary" (
  "id"         uuid                     DEFAULT gen_random_uuid() NOT NULL,
  "title"      text                     NOT NULL,
  "content"    text                     NOT NULL,
  "created_at" timestamp with time zone DEFAULT now(),
  "user_id"    uuid                     NOT NULL,
  CONSTRAINT "pk_report_dictionary" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS report_dictionary_pkey
  ON public.report_dictionary USING btree (id);

CREATE INDEX IF NOT EXISTS idx_report_dictionary_user_id
  ON public.report_dictionary USING btree (user_id);
