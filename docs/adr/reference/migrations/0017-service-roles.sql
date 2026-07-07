-- ADR-0017 §3 — per-service least-privilege DB roles (PREPARED).
-- Apply on the CONSOLIDATED DB at Phase E (process split), when each
-- service gets its own Secrets Manager entry. Do NOT apply while all
-- services share the postgres login — half-wired auth is worse than
-- none. Passwords: generate at apply time, store as
-- packiot/staging/db-<service>; never in this file.
--
-- Verification after wiring (the privilege-escalation test, D4):
-- each service run MUST FAIL on a table outside its grant set.

-- ingest-worker: raw writes only
CREATE ROLE ingest_worker_rw LOGIN PASSWORD :'ingest_pw';
GRANT USAGE ON SCHEMA public TO ingest_worker_rw;
GRANT SELECT ON public.packml_register, public.equipments,
                public.enterprises, public.shifts, public.shift_hours
  TO ingest_worker_rw;
GRANT INSERT, SELECT, UPDATE ON public.equipment_values,
                public.uns_metrics, public.uns_equipment_current_metrics
  TO ingest_worker_rw;

-- engine-worker: grain/runtime tables + the raw it reads
CREATE ROLE engine_worker_rw LOGIN PASSWORD :'engine_pw';
GRANT USAGE ON SCHEMA public TO engine_worker_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO engine_worker_rw;
GRANT INSERT, UPDATE, DELETE ON public.production_orders_runtime,
  public.equipment_events, public.equipment_runtime_shift
  TO engine_worker_rw;
-- + the full runtime/uns grain matrix (enumerate from
--   flows/rollup/uns write sets at apply time — keep this list
--   generated from code, not hand-maintained):
-- GRANT INSERT, UPDATE, DELETE ON public.{equipment,area,site}_runtime_* ,
--   public.uns_*_current_* TO engine_worker_rw;

-- reports-worker: pool schemas + the reads the bodies make
CREATE ROLE reports_worker_rw LOGIN PASSWORD :'reports_pw';
GRANT USAGE ON SCHEMA public, customer_reports, customer_dashboards
  TO reports_worker_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO reports_worker_rw;
GRANT ALL ON ALL TABLES IN SCHEMA customer_reports, customer_dashboards
  TO reports_worker_rw;
GRANT UPDATE (txt_production_order_notes) ON public.production_orders
  TO reports_worker_rw;  -- speed33 secondary fn, if ever ported

-- refdata-api: read-only + its one config table
CREATE ROLE refdata_ro LOGIN PASSWORD :'refdata_pw';
GRANT USAGE ON SCHEMA public TO refdata_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO refdata_ro;
GRANT ALL ON public.user_screen_config TO refdata_ro;

-- default privileges so future tables inherit sanely
ALTER DEFAULT PRIVILEGES IN SCHEMA customer_reports
  GRANT ALL ON TABLES TO reports_worker_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO engine_worker_rw, reports_worker_rw, refdata_ro;
