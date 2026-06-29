-- Patient Merge Cleanup DRY RUN (batched, ROLLBACK each batch, no data change)
-- Sama seperti LIVE: procedure yang sama, p_dry_run = true → satu batch lalu ROLLBACK dan exit.

CREATE OR REPLACE PROCEDURE public.patient_merge_cleanup_batched(
  p_batch_size int DEFAULT 500,
  p_dry_run boolean DEFAULT false
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_total_estimated bigint := 0;
  v_processed_so_far bigint := 0;
  v_batch_num int := 0;
  v_batch_actual int;
  v_pct numeric;
  v_first_round boolean := true;
BEGIN
  SET work_mem = '256MB';

  CREATE INDEX IF NOT EXISTS idx_patient_id_pat_id ON public.patient_id(pat_id);
  CREATE INDEX IF NOT EXISTS idx_patient_id_patient_fk ON public.patient_id(patient_fk);
  CREATE INDEX IF NOT EXISTS idx_patient_id_entity_id ON public.patient_id(entity_id);
  CREATE INDEX IF NOT EXISTS idx_patient_id_pat_id_patient_fk ON public.patient_id(pat_id, patient_fk);
  CREATE INDEX IF NOT EXISTS idx_study_patient_fk ON public.study(patient_fk);

  ANALYZE public.patient_id;
  ANALYZE public.patient;
  ANALYZE public.study;

  LOOP
    DROP TABLE IF EXISTS _pat_needs_fix;
    CREATE TEMP TABLE _pat_needs_fix ON COMMIT DROP AS
    SELECT pat_id
    FROM (
      SELECT pid.pat_id,
             COUNT(DISTINCT pid.patient_fk) AS distinct_patients,
             COUNT(*) FILTER (WHERE COALESCE(pid.entity_id,'') <> 'elvasoft') AS non_elva_ids
      FROM public.patient_id pid
      GROUP BY pid.pat_id
    ) x
    WHERE distinct_patients > 1 OR non_elva_ids > 0;

    SELECT count(*) INTO v_batch_actual FROM _pat_needs_fix;
    IF v_batch_actual = 0 THEN
      PERFORM pg_notify('cleanup_progress', '{"pct":100,"done":true}'::text);
      RETURN;
    END IF;

    IF v_first_round THEN
      v_total_estimated := v_batch_actual;
      v_first_round := false;
    END IF;

    DROP TABLE IF EXISTS _batch;
    CREATE TEMP TABLE _batch ON COMMIT DROP AS
    SELECT pat_id FROM _pat_needs_fix LIMIT p_batch_size;

    SELECT count(*) INTO v_batch_actual FROM _batch;

    DROP TABLE IF EXISTS _pat_stats;
    CREATE TEMP TABLE _pat_stats ON COMMIT DROP AS
    SELECT
      pid.pat_id,
      pid.patient_fk,
      MAX((pid.entity_id = 'elvasoft')::int) AS has_elvasoft,
      COALESCE(p.num_studies, 0) AS num_studies,
      p.updated_time
    FROM public.patient_id pid
    JOIN public.patient p ON p.pk = pid.patient_fk
    WHERE pid.pat_id IN (SELECT pat_id FROM _batch)
    GROUP BY pid.pat_id, pid.patient_fk, p.num_studies, p.updated_time;

    DROP TABLE IF EXISTS _canonical;
    CREATE TEMP TABLE _canonical ON COMMIT DROP AS
    WITH ranked AS (
      SELECT
        s.pat_id,
        s.patient_fk,
        ROW_NUMBER() OVER (
          PARTITION BY s.pat_id
          ORDER BY s.has_elvasoft DESC, s.num_studies DESC, s.updated_time DESC, s.patient_fk ASC
        ) AS rn
      FROM _pat_stats s
    )
    SELECT pat_id, patient_fk FROM ranked WHERE rn = 1;

    UPDATE public.study st
    SET patient_fk = c.patient_fk
    FROM _canonical c
    WHERE st.patient_fk IN (
      SELECT ps.patient_fk
      FROM _pat_stats ps
      WHERE ps.pat_id = c.pat_id AND ps.patient_fk <> c.patient_fk
    );

    UPDATE public.patient_id pid
    SET patient_fk = c.patient_fk,
        entity_id  = 'elvasoft',
        version    = COALESCE(pid.version, 0)
    FROM _canonical c
    WHERE pid.pat_id = c.pat_id
      AND (pid.patient_fk <> c.patient_fk OR COALESCE(pid.entity_id,'') <> 'elvasoft');

    WITH affected_fk AS (
      SELECT patient_fk FROM _canonical
      UNION
      SELECT patient_fk FROM _pat_stats
    ),
    d AS (
      SELECT pid.pk,
             ROW_NUMBER() OVER (
               PARTITION BY pid.patient_fk, pid.pat_id,
                            COALESCE(pid.entity_id,''), COALESCE(pid.entity_uid,''),
                            COALESCE(pid.entity_uid_type,''), COALESCE(pid.pat_id_type_code,'')
               ORDER BY pid.pk
             ) AS rn
      FROM public.patient_id pid
      WHERE pid.patient_fk IN (SELECT patient_fk FROM affected_fk)
    )
    DELETE FROM public.patient_id p
    USING d
    WHERE p.pk = d.pk AND d.rn > 1;

    DELETE FROM public.patient_id pid
    USING _canonical c
    WHERE pid.pat_id = c.pat_id
      AND COALESCE(pid.entity_id,'') <> 'elvasoft';

    UPDATE public.patient p
    SET num_studies = COALESCE(cnt.c, 0)
    FROM (
      SELECT patient_fk AS pk FROM _pat_stats
      UNION
      SELECT patient_fk AS pk FROM _canonical
    ) affected
    LEFT JOIN (
      SELECT s.patient_fk AS pk, count(*)::int AS c
      FROM public.study s
      GROUP BY s.patient_fk
    ) cnt ON cnt.pk = affected.pk
    WHERE p.pk = affected.pk;

    DROP TABLE IF EXISTS _del_patients;
    CREATE TEMP TABLE _del_patients ON COMMIT DROP AS
    SELECT p.pk
    FROM public.patient p
    LEFT JOIN public.patient_id pid ON pid.patient_fk = p.pk
    WHERE p.num_studies = 0 AND pid.patient_fk IS NULL;

    <<block6b>>
    DECLARE
      r RECORD;
    BEGIN
      FOR r IN
        SELECT n.nspname AS sch, c.relname AS tbl, a.attname AS col
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN unnest(con.conkey) k(attnum) ON true
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
        WHERE con.contype = 'f' AND con.confrelid = 'public.patient'::regclass
      LOOP
        EXECUTE format(
          'DELETE FROM _del_patients dp WHERE EXISTS (SELECT 1 FROM %I.%I ch WHERE ch.%I = dp.pk)',
          r.sch, r.tbl, r.col
        );
      END LOOP;
    END block6b;

    DELETE FROM public.patient p
    WHERE p.pk IN (SELECT pk FROM _del_patients);

    IF p_dry_run THEN
      ROLLBACK;
      v_processed_so_far := v_processed_so_far + v_batch_actual;
      v_batch_num := v_batch_num + 1;
      v_pct := LEAST(100, ROUND(100.0 * v_processed_so_far / NULLIF(v_total_estimated, 0), 1));
      PERFORM pg_notify('cleanup_progress', json_build_object('batch', v_batch_num, 'processed', v_processed_so_far, 'total', v_total_estimated, 'pct', v_pct, 'dry_run', true)::text);
      PERFORM pg_notify('cleanup_progress', '{"pct":100,"done":true,"dry_run":true}'::text);
      RETURN;
    ELSE
      COMMIT;
    END IF;

    v_processed_so_far := v_processed_so_far + v_batch_actual;
    v_batch_num := v_batch_num + 1;
    v_pct := LEAST(100, ROUND(100.0 * v_processed_so_far / NULLIF(v_total_estimated, 0), 1));
    PERFORM pg_notify('cleanup_progress', json_build_object('batch', v_batch_num, 'processed', v_processed_so_far, 'total', v_total_estimated, 'pct', v_pct)::text);

  END LOOP;

  PERFORM pg_notify('cleanup_progress', '{"pct":100,"done":true}'::text);
END;
$$;

-- DRY RUN: satu batch lalu ROLLBACK (tidak ada perubahan data)
CALL public.patient_merge_cleanup_batched(500, true);
