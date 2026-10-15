-- t-adr0065-p0-cold-export-gate — ADR-0065 P0: no partition is dropped without a verified cold copy (2026-10-15).
-- ops.partition_maintain() used to DETACH + DROP every partition past ops.retention_policy.keep. The historian's cold
-- copy is fed from LEGACY only, so a tenant without legacy history (Bispharma, data from 2026-09-02) would lose raw
-- rows for good when its first partition passes 90 days (~2026-12-01).
--
-- Gate (per relation, from the retention catalog's cold_copy):
--   cold_copy NULL or 'none'  → no cold copy by design → drop as before (bronze raw, plc link minutes today)
--   cold_copy set             → drop a partition only if EVERY (tenant, day) present in it has a VERIFIED row in
--                               ops.cold_export (tenants in ops.cold_export_exempt do not count — the sandbox twin
--                               mirrors CPACK). Otherwise keep it and record it in ops.partition_drop_blocked.
-- The lower catch-all (_pmin) is re-seated only when it is empty or passes the same gate.
-- P0 has no exporter yet (ADR-0065 P1), so for silver.equipment_values / equipment_events this BLOCKS every drop:
-- safe, the disk grows ~100 MB/day on staging (91 GB free).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS ops.cold_export (
  relation      text        NOT NULL,             -- hot relation, e.g. silver.equipment_values
  id_enterprise integer     NOT NULL,
  period_lo     timestamptz NOT NULL,             -- [period_lo, period_hi) covered by the file
  period_hi     timestamptz NOT NULL,
  uri           text        NOT NULL,             -- s3://… Parquet object
  rows          bigint      NOT NULL,
  sum_net       double precision,
  sum_gross     double precision,
  exported_at   timestamptz NOT NULL DEFAULT now(),
  verified_at   timestamptz,                      -- set only after the file was read back and matched the hot slice
  PRIMARY KEY (relation, id_enterprise, period_lo),
  CHECK (period_hi > period_lo)
);
COMMENT ON TABLE ops.cold_export IS
  'ADR-0065 manifest: one row per archived tenant-period file; verified_at NULL = written but not verified (does not open the drop gate)';

CREATE TABLE IF NOT EXISTS ops.cold_export_exempt (
  id_enterprise integer PRIMARY KEY,
  reason        text NOT NULL
);
COMMENT ON TABLE ops.cold_export_exempt IS 'ADR-0065: tenants whose hot rows may be dropped without a cold copy';
INSERT INTO ops.cold_export_exempt VALUES (2000003, 'SANDBOX-CPACK twin: a mirror of CPACK-Staging (ent 3), rebuilt by heal')
ON CONFLICT (id_enterprise) DO NOTHING;

CREATE TABLE IF NOT EXISTS ops.partition_drop_blocked (
  relation        text        NOT NULL,
  part            text        NOT NULL,
  lo              timestamptz,
  hi              timestamptz,
  uncovered       integer     NOT NULL,           -- tenant-days without a verified export
  sample          text,                           -- a few "ent:day" keys
  first_blocked   timestamptz NOT NULL DEFAULT now(),
  last_checked    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (relation, part)
);
COMMENT ON TABLE ops.partition_drop_blocked IS 'ADR-0065: partitions past retention kept because their cold copy is missing/unverified';

-- tenant-days of one partition that lack a verified export
CREATE OR REPLACE FUNCTION ops.partition_uncovered(p_rel text, p_part regclass, p_time_col text)
RETURNS TABLE (id_enterprise integer, d date)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
  RETURN QUERY EXECUTE format(
    $q$SELECT x.id_enterprise, x.d FROM (SELECT DISTINCT t.id_enterprise, (t.%1$I AT TIME ZONE 'UTC')::date AS d FROM %2$s t) x
        WHERE x.id_enterprise IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM ops.cold_export_exempt e WHERE e.id_enterprise = x.id_enterprise)
          AND NOT EXISTS (SELECT 1 FROM ops.cold_export c
                           WHERE c.relation = %3$L AND c.id_enterprise = x.id_enterprise AND c.verified_at IS NOT NULL
                             AND c.period_lo <= (x.d::timestamp AT TIME ZONE 'UTC')
                             AND c.period_hi >= ((x.d + 1)::timestamp AT TIME ZONE 'UTC'))
        ORDER BY 2, 1$q$, p_time_col, p_part, p_rel);
END $fn$;

-- the return type gains `blocked` → drop + recreate (pg_cron calls SELECT * FROM ops.partition_maintain())
DROP FUNCTION IF EXISTS ops.partition_maintain(interval);
CREATE FUNCTION ops.partition_maintain(p_ahead interval DEFAULT interval '60 days')
RETURNS TABLE (rel text, created integer, dropped integer, blocked integer)
LANGUAGE plpgsql AS $f$
DECLARE s record; r record; keep interval; cold text; first_lo timestamptz; minpart regclass; sch text; nm text;
        n_unc integer; smp text; pname text;
BEGIN
  FOR s IN SELECT * FROM ops.pc_state WHERE swapped_at IS NOT NULL LOOP
    rel := s.rel; dropped := 0; blocked := 0; sch := split_part(s.rel, '.', 1); nm := split_part(s.rel, '.', 2);
    created := ops.pc_add_partitions(s.rel::regclass, s.step, now(), now() + p_ahead);
    SELECT rp.keep, nullif(rp.cold_copy, 'none') INTO keep, cold FROM ops.retention_policy rp WHERE rp.relation = s.rel;
    IF keep IS NOT NULL THEN
      -- regular partitions only: a catch-all (MINVALUE/MAXVALUE bound) is never dropped by retention
      FOR r IN SELECT i.inhrelid::regclass AS part, b.lo, b.hi FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b
                WHERE i.inhparent = s.rel::regclass AND NOT b.lo_min AND NOT b.hi_max ORDER BY b.lo LOOP
        CONTINUE WHEN r.hi > now() - keep;
        IF cold IS NOT NULL THEN
          SELECT count(*), string_agg(u.id_enterprise || ':' || u.d, ' ' ORDER BY u.d, u.id_enterprise) FILTER (WHERE u.rn <= 5)
            INTO n_unc, smp
            FROM (SELECT x.*, row_number() OVER () AS rn FROM ops.partition_uncovered(s.rel, r.part, s.time_col) x) u;
          IF n_unc > 0 THEN
            INSERT INTO ops.partition_drop_blocked (relation, part, lo, hi, uncovered, sample)
            VALUES (s.rel, r.part::text, r.lo, r.hi, n_unc, smp)
            ON CONFLICT (relation, part) DO UPDATE SET uncovered = EXCLUDED.uncovered, sample = EXCLUDED.sample, last_checked = now();
            blocked := blocked + 1;
            -- retention stays contiguous from the bottom: dropping a newer partition while an older one is kept
            -- would leave a hole no row can be inserted into
            EXIT;
          END IF;
        END IF;
        -- the name as text BEFORE the drop: a dropped table's regclass renders as a bare OID afterwards
        pname := r.part::text;
        EXECUTE format('ALTER TABLE %s DETACH PARTITION %s', s.rel, r.part);
        EXECUTE format('DROP TABLE %s', r.part);
        DELETE FROM ops.partition_drop_blocked WHERE relation = s.rel AND part = pname;
        dropped := dropped + 1;
      END LOOP;
      IF dropped > 0 THEN
        -- re-seat the lower catch-all at the oldest remaining partition, or old-dated inserts into the gap
        -- would fail (2026-10-15); its rows are older than anything kept → same gate before it is dropped
        SELECT min(b.lo) INTO first_lo FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b
         WHERE i.inhparent = s.rel::regclass AND NOT b.lo_min AND NOT b.hi_max;
        SELECT i.inhrelid::regclass INTO minpart FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b
         WHERE i.inhparent = s.rel::regclass AND b.lo_min;
        n_unc := 0;
        IF minpart IS NOT NULL AND cold IS NOT NULL THEN
          SELECT count(*) INTO n_unc FROM ops.partition_uncovered(s.rel, minpart, s.time_col);
        END IF;
        IF n_unc > 0 THEN
          INSERT INTO ops.partition_drop_blocked (relation, part, lo, hi, uncovered, sample)
          VALUES (s.rel, minpart::text, NULL, first_lo, n_unc, 'lower catch-all')
          ON CONFLICT (relation, part) DO UPDATE SET uncovered = EXCLUDED.uncovered, last_checked = now();
          blocked := blocked + 1;
        ELSE
          IF minpart IS NOT NULL THEN
            pname := minpart::text;
            EXECUTE format('ALTER TABLE %s DETACH PARTITION %s', s.rel, minpart);
            EXECUTE format('DROP TABLE %s', minpart);
            DELETE FROM ops.partition_drop_blocked WHERE relation = s.rel AND part = pname;
          END IF;
          IF first_lo IS NOT NULL THEN
            EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (MINVALUE) TO (%L)', sch, nm || '_pmin', s.rel, first_lo);
          END IF;
        END IF;
      END IF;
    END IF;
    RETURN NEXT;
  END LOOP;
END $f$;
COMMENT ON FUNCTION ops.partition_maintain(interval) IS
  'Partitions ahead + retention drops; ADR-0065 gate: a partition of a relation with a cold_copy is dropped only when every tenant-day in it has a verified ops.cold_export row';

COMMIT;
