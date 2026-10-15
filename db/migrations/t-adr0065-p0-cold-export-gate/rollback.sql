-- Restores the ungated ops.partition_maintain (retention drops without a cold-copy check) and removes the P0 objects.
\set ON_ERROR_STOP 1
BEGIN;
DROP FUNCTION IF EXISTS ops.partition_maintain(interval);
CREATE FUNCTION ops.partition_maintain(p_ahead interval DEFAULT interval '60 days')
RETURNS TABLE (rel text, created integer, dropped integer)
LANGUAGE plpgsql AS $f$
DECLARE s record; r record; keep interval; first_lo timestamptz; minpart regclass; sch text; nm text;
BEGIN
  FOR s IN SELECT * FROM ops.pc_state WHERE swapped_at IS NOT NULL LOOP
    rel := s.rel; dropped := 0; sch := split_part(s.rel, '.', 1); nm := split_part(s.rel, '.', 2);
    created := ops.pc_add_partitions(s.rel::regclass, s.step, now(), now() + p_ahead);
    SELECT rp.keep INTO keep FROM ops.retention_policy rp WHERE rp.relation = s.rel;
    IF keep IS NOT NULL THEN
      FOR r IN SELECT i.inhrelid::regclass AS part, b.hi FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b
                WHERE i.inhparent = s.rel::regclass AND NOT b.lo_min AND NOT b.hi_max LOOP
        IF r.hi <= now() - keep THEN
          EXECUTE format('ALTER TABLE %s DETACH PARTITION %s', s.rel, r.part);
          EXECUTE format('DROP TABLE %s', r.part);
          dropped := dropped + 1;
        END IF;
      END LOOP;
      IF dropped > 0 THEN
        SELECT min(b.lo) INTO first_lo FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b
         WHERE i.inhparent = s.rel::regclass AND NOT b.lo_min AND NOT b.hi_max;
        SELECT i.inhrelid::regclass INTO minpart FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b
         WHERE i.inhparent = s.rel::regclass AND b.lo_min;
        IF minpart IS NOT NULL THEN
          EXECUTE format('ALTER TABLE %s DETACH PARTITION %s', s.rel, minpart);
          EXECUTE format('DROP TABLE %s', minpart);
        END IF;
        IF first_lo IS NOT NULL THEN
          EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (MINVALUE) TO (%L)', sch, nm || '_pmin', s.rel, first_lo);
        END IF;
      END IF;
    END IF;
    RETURN NEXT;
  END LOOP;
END $f$;
DROP FUNCTION IF EXISTS ops.partition_uncovered(text, regclass, text);
DROP TABLE IF EXISTS ops.partition_drop_blocked, ops.cold_export_exempt, ops.cold_export;
COMMIT;
