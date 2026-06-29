alter table "serviceRequest"
alter column "insurance" type text using "insurance"::text;