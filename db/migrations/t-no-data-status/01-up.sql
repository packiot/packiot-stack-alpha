-- t-no-data-status — equipment_events status 20 = NO DATA (2026-10-01)
--
-- Availability policy (agreed 2026-10-01): time the PLC could not be read is NO
-- DATA — neither running nor stopped. The live Bispharma stop deriver
-- (stream-engine cpac_deriver.go, LinkHealth) now writes a status-20 transition
-- at the start of each PLC-link gap instead of a count-silence stop (the L58
-- 15-day phantom stop). An event row is still needed: without a boundary the
-- closer would stretch the preceding RUNNING row across the gap.
--
-- Every serving function/view that reads equipment_events as "downtime =
-- status <> 6" would list a status-20 span as an uncategorised stop. This
-- migration rewrites exactly that predicate to status NOT IN (6, 20) in the
-- serving functions + views that read equipment_events (verified list below),
-- keeping each view's reloptions (CREATE OR REPLACE VIEW would reset them).
-- Stopped-set readers (status IN (5,10,11) / = 10) already exclude 20.
--
-- NOTE for anyone re-applying an OLDER migration that CREATE OR REPLACEs one of
-- these objects: re-apply this one afterwards (it is idempotent).
BEGIN;

INSERT INTO silver.machine_state VALUES
  (20, 'no_data', false, false,
   'NO DATA: the PLC could not be read (silver.plc_link_minutes) — neither running nor stopped. Written by the link-aware stop deriver; excluded from downtime lists and from availability.')
ON CONFLICT DO NOTHING;

DO $$
DECLARE
  r record; def text; new_def text; opts text; n int := 0;
  pat constant text := '(\m[a-z_]+\.)?status\s*(<>|!=)\s*6\M';
BEGIN
  FOR r IN
    SELECT p.oid, n.nspname, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'serving' AND p.prokind = 'f'
       AND p.proname IN ('downtime_events', 'downtime_events_v2', 'downtime_sync', 'events_timeline',
                         'events_timeline_by_po', 'overview_events', 'overview_events_v3',
                         'pending_downtime', 'refresh_downtime_events_resolved')
  LOOP
    def := pg_get_functiondef(r.oid);
    new_def := regexp_replace(def, pat, '\1status NOT IN (6, 20)', 'g');
    IF new_def <> def THEN EXECUTE new_def; n := n + 1; END IF;
  END LOOP;

  FOR r IN
    SELECT c.oid, n.nspname, c.relname, c.reloptions FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'v' AND (n.nspname, c.relname) IN
           (('bi', 'downtimes'), ('serving', 'v_events_2'), ('serving', 'v_operator_po_details_3'))
  LOOP
    def := pg_get_viewdef(r.oid);
    new_def := regexp_replace(def, pat, '\1status NOT IN (6, 20)', 'g');
    IF new_def <> def THEN
      opts := CASE WHEN r.reloptions IS NULL THEN '' ELSE ' WITH (' || array_to_string(r.reloptions, ', ') || ')' END;
      EXECUTE format('CREATE OR REPLACE VIEW %I.%I%s AS %s', r.nspname, r.relname, opts, new_def);
      n := n + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 't-no-data-status: rewrote % objects', n;
END $$;

-- Guard: nothing in scope still reads "status <> 6".
DO $$
DECLARE left_over int;
BEGIN
  SELECT count(*) INTO left_over FROM (
    SELECT pg_get_functiondef(p.oid) AS d FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'serving' AND p.prokind = 'f' AND pg_get_functiondef(p.oid) ILIKE '%equipment_events%'
    UNION ALL
    SELECT pg_get_viewdef(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'v' AND (n.nspname, c.relname) IN
           (('bi', 'downtimes'), ('serving', 'v_events_2'), ('serving', 'v_operator_po_details_3'))
  ) x WHERE x.d ~ '(\m[a-z_]+\.)?status\s*(<>|!=)\s*6\M';
  IF left_over > 0 THEN RAISE EXCEPTION 't-no-data-status: % objects still read status <> 6', left_over; END IF;
END $$;

COMMIT;
