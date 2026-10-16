-- Restore "status <> 6" in the same objects (the deriver's LinkHealth must be
-- off first, or status-20 spans show up again as uncategorised stops).
BEGIN;
DO $$
DECLARE r record; def text; new_def text; opts text;
  pat constant text := '(\m[a-z_]+\.)?status NOT IN \(6, 20\)';
BEGIN
  FOR r IN
    SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'serving' AND p.prokind = 'f'
       AND p.proname IN ('downtime_events', 'downtime_events_v2', 'downtime_sync', 'events_timeline',
                         'events_timeline_by_po', 'overview_events', 'overview_events_v3',
                         'pending_downtime', 'refresh_downtime_events_resolved')
  LOOP
    def := pg_get_functiondef(r.oid);
    new_def := regexp_replace(def, pat, '\1status <> 6', 'g');
    IF new_def <> def THEN EXECUTE new_def; END IF;
  END LOOP;
  FOR r IN
    SELECT c.oid, n.nspname, c.relname, c.reloptions FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'v' AND (n.nspname, c.relname) IN
           (('bi', 'downtimes'), ('serving', 'v_events_2'), ('serving', 'v_operator_po_details_3'))
  LOOP
    def := pg_get_viewdef(r.oid);
    new_def := regexp_replace(def, pat, '\1status <> 6', 'g');
    IF new_def <> def THEN
      opts := CASE WHEN r.reloptions IS NULL THEN '' ELSE ' WITH (' || array_to_string(r.reloptions, ', ') || ')' END;
      EXECUTE format('CREATE OR REPLACE VIEW %I.%I%s AS %s', r.nspname, r.relname, opts, new_def);
    END IF;
  END LOOP;
END $$;
COMMIT;
