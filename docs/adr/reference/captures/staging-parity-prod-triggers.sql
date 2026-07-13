-- Staging parity — prod triggers missing on staging
--
-- Captured 2026-07-02 from prod tsp12/packiot40 (pg_get_triggerdef +
-- prosrc, SELECT-only) after docs/prod-staging-3flow-comparison
-- Findings B/C. Behavior must match prod exactly, so definitions are
-- verbatim.
--
-- Mechanism note (the last_update_* family): these are AFTER UPDATE
-- row triggers whose function runs a SELF-UPDATE setting last_update =
-- current_timestamp. The recursion terminates at depth 2 because
-- current_timestamp is constant within a transaction: the second pass
-- writes the same value, so WHEN (old.* IS DISTINCT FROM new.*) is
-- false. Cost: one extra row version per real UPDATE — prod pays it,
-- so staging pays it (parity over elegance; the ADR-0014 answer is to
-- have Go writers set last_update explicitly and retire these, done
-- deliberately for prod+staging together, not as a staging-only edit).
--
-- The equipments triggers are STATEMENT-level, calling piot functions
-- that already exist on staging with byte-identical sizes
-- (piot_trig_upsert_packml_topics 85, piot_update_super_users 982,
-- piot_trig_uns_upsert_features 84).
--
-- NOT included here (deliberate): prod's equipment_values triggers
-- (ts_insert_blocker, ts_cagg_invalidation_trigger,
-- feed_invalidation_log) — they are TimescaleDB hypertable/CAgg
-- machinery and arrive with the CAgg-layer adoption, not standalone.
-- UPDATE 2026-07-13: piot_set_shift_before_insert is RETIRED. The
-- ADR-0014 P2 bake completed (168h zero divergence); the trigger was
-- dropped from staging public.equipment_values (and packiot_shadow
-- public — DBA verified ZERO triggers on both live). The oeecloud-worker
-- Go shiftresolver is now the SOLE writer of id_shift/id_shift_hour/
-- ts_value_production on ALL schemas and flows.

-- ── last_update trigger functions (verbatim prod bodies) ────────────
CREATE OR REPLACE FUNCTION public.last_update_to_now() RETURNS trigger
LANGUAGE plpgsql AS $fn$
begin
	UPDATE equipment_events
	SET last_update = current_timestamp
	where id_equipment_event = old.id_equipment_event;
return null;
end
$fn$;

CREATE OR REPLACE FUNCTION public.last_update_to_now_in_equipment_events_man() RETURNS trigger
LANGUAGE plpgsql AS $fn$
begin
	UPDATE equipment_events_man
	SET last_update = current_timestamp
	where id_equipment_event = old.id_equipment_event;
return null;
end
$fn$;

CREATE OR REPLACE FUNCTION public.last_update_to_now_in_production_orders() RETURNS trigger
LANGUAGE plpgsql AS $fn$
begin
	UPDATE production_orders
	SET last_update = current_timestamp
	where id_production_order = old.id_production_order;
return null;
end
$fn$;

-- ── Triggers (verbatim prod pg_get_triggerdef) ──────────────────────
DROP TRIGGER IF EXISTS update_last_update_on_equipment_events ON public.equipment_events;
CREATE TRIGGER update_last_update_on_equipment_events AFTER UPDATE ON public.equipment_events FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION last_update_to_now();

DROP TRIGGER IF EXISTS update_last_update_on_equipment_events_man ON public.equipment_events_man;
CREATE TRIGGER update_last_update_on_equipment_events_man AFTER UPDATE ON public.equipment_events_man FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION last_update_to_now_in_equipment_events_man();

DROP TRIGGER IF EXISTS update_last_update_on_production_orders ON public.production_orders;
CREATE TRIGGER update_last_update_on_production_orders AFTER UPDATE ON public.production_orders FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION last_update_to_now_in_production_orders();

DROP TRIGGER IF EXISTS "Create packml topics" ON public.equipments;
CREATE TRIGGER "Create packml topics" AFTER INSERT OR UPDATE ON public.equipments FOR EACH STATEMENT EXECUTE FUNCTION piot_trig_upsert_packml_topics();

DROP TRIGGER IF EXISTS "Update super users" ON public.equipments;
CREATE TRIGGER "Update super users" AFTER INSERT OR UPDATE ON public.equipments FOR EACH STATEMENT EXECUTE FUNCTION piot_update_super_users();

DROP TRIGGER IF EXISTS upsert_to_uns ON public.equipments;
CREATE TRIGGER upsert_to_uns AFTER INSERT ON public.equipments FOR EACH STATEMENT EXECUTE FUNCTION piot_trig_uns_upsert_features();

\echo '=== staging triggers after apply ==='
SELECT c.relname || ' | ' || t.tgname FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
WHERE NOT t.tgisinternal AND c.relname IN ('equipment_events','equipment_events_man','production_orders','equipments','equipment_values')
ORDER BY 1;
