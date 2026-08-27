#!/usr/bin/env bash
# Provision (or reset) the STAGING "SANDBOX-CPACK" tenant — a fake enterprise that
# clones staging's CPACK-Staging (ent 3) topology into a fresh, freely-mutable
# enterprise so CS Admin (and other features) can be tested without touching the
# real CPACK-Staging twin.
#
#   Source:  ent 3        (CPACK-Staging — staging's live CPACK twin)
#   Sandbox: ent 2000003  (SANDBOX-CPACK) — every intra-tenant id offset by +2,000,000
#                          (collision-free: max equipment id is <1e6), id_enterprise -> 2000003.
#
# What it clones (the CS Admin control plane):
#   enterprises, sites, areas, equipments, packml_register (kept INACTIVE — the
#   sandbox is not live-SparkPlug-routed), shifts, shift_hours, user_roles, users,
#   client_descriptors (the ADR-0045 PLC tag-map / onboarding SSoT — cloned +
#   remapped so csadmin sensor-config renders the tag map like the real client).
#   language_packs are GLOBAL (no id_enterprise) so they need no clone.
#   Time-series data (equipment_values / production_orders / …) is NOT cloned here
#   — CS Admin is a config plane. Add a data mirror separately for OEE-dashboard tests.
#
# Fidelity notes (why a fresh reset is a FULL twin, not a bare shell):
#   * equipments.id_parentequipment is offset (+$OFF) below so the sandbox line->
#     member hierarchy survives the clone (each machine keeps pointing at its line);
#     without it csadmin shows "0 members" per line.
#   * client_descriptors is deep-remapped by pg_temp.sbx_remap(): every id_equipment
#     /id_unit +$OFF, every CPACK string -> SBXCPACK (topics, device_keys, canonical
#     prefix, agent/tee ids, secret refs); status set to 'generated' so the wizard
#     renders as a provisioned tenant. The descriptor is a READ-ONLY MIRROR of the
#     real client edge (updated_by='sandbox-mirror:ent3') — there is no schema-level
#     read-only flag; treat edits as throwaway (a reset re-mirrors from ent 3).
#
# Idempotent-ish: use --reset to wipe + rebuild. Bare invocation fails if the
# sandbox already exists (so you don't silently double-insert).
#
#   ./provision-sandbox-tenant.sh            # create (errors if it already exists)
#   ./provision-sandbox-tenant.sh --reset    # delete + recreate from current ent 3
#   ./provision-sandbox-tenant.sh --delete   # just delete the sandbox
#
# RabbitMQ topology (task #22): stream-engine auto-declares this twin's own
# queue (stream-engine-q-sandbox-cpack + retry/failed) from packml_register at
# boot — no manual step needed for that. What IS still manual is the
# re-tenant FAN-OUT that makes the sandbox mirror CPACK's real live stream
# (services/oeecloud-fanout) — create/reset emits that twin's compose+.env
# config via scripts/emit-fanout-config.sh (see SOURCE_GROUP/TARGET_GROUP
# below). Emission is idempotent and templatable to any future twin — set
# SOURCE_GROUP/TARGET_GROUP env vars before invoking to point it at a
# different pair without editing this script.
#
# Runs against the staging DB via SSM -> staging app box -> dockerized psql
# (same path as scripts/reprovision-refactor-sandbox.sh and the stagingq helper).
set -euo pipefail

APP_INSTANCE="${APP_INSTANCE:-i-06c9547a2c7091ab7}"   # packiot-staging-app
REGION="${REGION:-us-east-1}"
OFF=2000000
SENT=2000003
SRC_ENT=3

# Fan-out twin identity (task #22) — the SparkPlug GroupIDs (tenant strings)
# emit-fanout-config.sh needs, kept separate from the numeric ent ids above
# because the fan-out operates on the RabbitMQ/decoded-envelope plane, not
# the DB plane. Overridable so this same script's fan-out-emission step can
# be pointed at a different pair without editing the file.
SOURCE_GROUP="${SOURCE_GROUP:-CPACK}"
TARGET_GROUP="${TARGET_GROUP:-SBXCPACK}"

MODE="create"
case "${1:-}" in
  --reset)  MODE="reset" ;;
  --delete) MODE="delete" ;;
  ""|--create) MODE="create" ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

# ── SQL fragments ─────────────────────────────────────────────────────────────
# DELETE in child->parent order. session_replication_role=replica skips FK/trigger
# side-effects during the bulk op (referential integrity is guaranteed by clearing
# the whole tenant at once).
read -r -d '' SQL_DELETE <<SQL || true
SET session_replication_role = replica;
DELETE FROM client_descriptors WHERE id_enterprise = $SENT;
DELETE FROM shift_hours     WHERE id_enterprise = $SENT;
DELETE FROM shifts          WHERE id_enterprise = $SENT;
DELETE FROM packml_register WHERE id_enterprise = $SENT;
DELETE FROM users           WHERE id_enterprise = $SENT;
DELETE FROM user_roles      WHERE id_enterprise = $SENT;
DELETE FROM equipments      WHERE id_enterprise = $SENT;
DELETE FROM areas           WHERE id_enterprise = $SENT;
DELETE FROM sites           WHERE id_enterprise = $SENT;
DELETE FROM enterprises     WHERE id_enterprise = $SENT;
SET session_replication_role = DEFAULT;
SQL

# CREATE. jsonb-override clone: to_jsonb(row) || overrides, then json_populate_record
# (portable, column-order-independent). Only the verified intra-tenant id keys are
# offset; every other column (jsonb config, flags, NULL soft-refs) passes through.
read -r -d '' SQL_CREATE <<SQL || true
SET session_replication_role = replica;  -- suppress the "Create packml topics" trigger

INSERT INTO enterprises SELECT (json_populate_record(NULL::enterprises,
  (to_jsonb(e) || jsonb_build_object('id_enterprise',$SENT)
   || jsonb_build_object('nm_enterprise','SANDBOX-CPACK')
   || jsonb_build_object('api_key', gen_random_uuid()::text))::json)).*
FROM enterprises e WHERE id_enterprise=$SRC_ENT;

INSERT INTO sites SELECT (json_populate_record(NULL::sites,
  (to_jsonb(s) || jsonb_build_object('id_site',s.id_site+$OFF)
   || jsonb_build_object('id_enterprise',$SENT))::json)).*
FROM sites s WHERE id_enterprise=$SRC_ENT;

INSERT INTO areas SELECT (json_populate_record(NULL::areas,
  (to_jsonb(a) || jsonb_build_object('id_area',a.id_area+$OFF)
   || jsonb_build_object('id_site',a.id_site+$OFF)
   || jsonb_build_object('id_enterprise',$SENT)
   || jsonb_build_object('id_infeedcounter',a.id_infeedcounter+$OFF)
   || jsonb_build_object('id_outfeedcounter',a.id_outfeedcounter+$OFF)
   || jsonb_build_object('id_rejectscounter',a.id_rejectscounter+$OFF))::json)).*
FROM areas a WHERE id_enterprise=$SRC_ENT;

INSERT INTO equipments SELECT (json_populate_record(NULL::equipments,
  (to_jsonb(e) || jsonb_build_object('id_equipment',e.id_equipment+$OFF)
   || jsonb_build_object('id_area',e.id_area+$OFF)
   || jsonb_build_object('id_site',e.id_site+$OFF)
   || jsonb_build_object('id_enterprise',$SENT)
   || jsonb_build_object('id_parentequipment',e.id_parentequipment+$OFF)  -- keeps line->member hierarchy (NULL stays NULL)
   || jsonb_build_object('lead_machine',e.lead_machine+$OFF)
   || jsonb_build_object('gross_machine',e.gross_machine+$OFF)
   || jsonb_build_object('scrap_machine',e.scrap_machine+$OFF)
   || jsonb_build_object('sector_equipment_infeed',e.sector_equipment_infeed+$OFF)
   || jsonb_build_object('sector_equipment_outfeed',e.sector_equipment_outfeed+$OFF)
   || jsonb_build_object('id_packed_counter',e.id_packed_counter+$OFF)
   || jsonb_build_object('id_equipment_status_mirror',e.id_equipment_status_mirror+$OFF))::json)).*
FROM equipments e WHERE id_enterprise=$SRC_ENT;

INSERT INTO packml_register SELECT (json_populate_record(NULL::packml_register,
  (to_jsonb(p) || jsonb_build_object('id_packml_register',p.id_packml_register+$OFF)
   || jsonb_build_object('id_equipment',p.id_equipment+$OFF)
   || jsonb_build_object('id_unit',p.id_unit+$OFF)
   || jsonb_build_object('id_site',p.id_site+$OFF)
   || jsonb_build_object('id_area',p.id_area+$OFF)
   || jsonb_build_object('id_enterprise',$SENT)
   || jsonb_build_object('id_infeedcounter',p.id_infeedcounter+$OFF)
   || jsonb_build_object('id_outfeedcounter',p.id_outfeedcounter+$OFF)
   || jsonb_build_object('active',false))::json)).*  -- mirror-fed, not live-routed
FROM packml_register p WHERE id_enterprise=$SRC_ENT;

INSERT INTO shifts SELECT (json_populate_record(NULL::shifts,
  (to_jsonb(sh) || jsonb_build_object('id_shift',sh.id_shift+$OFF)
   || jsonb_build_object('id_enterprise',$SENT)
   || jsonb_build_object('id_site',sh.id_site+$OFF)
   || jsonb_build_object('id_area',sh.id_area+$OFF)
   || jsonb_build_object('id_equipment',sh.id_equipment+$OFF))::json)).*
FROM shifts sh WHERE id_enterprise=$SRC_ENT;

INSERT INTO shift_hours SELECT (json_populate_record(NULL::shift_hours,
  (to_jsonb(h) || jsonb_build_object('id_shift_hour',h.id_shift_hour+$OFF)
   || jsonb_build_object('id_shift',h.id_shift+$OFF)
   || jsonb_build_object('id_enterprise',$SENT)
   || jsonb_build_object('id_site',h.id_site+$OFF)
   || jsonb_build_object('id_area',h.id_area+$OFF)
   || jsonb_build_object('id_equipment',h.id_equipment+$OFF))::json)).*
FROM shift_hours h WHERE id_enterprise=$SRC_ENT;

INSERT INTO user_roles SELECT (json_populate_record(NULL::user_roles,
  (to_jsonb(r) || jsonb_build_object('id_user_role',r.id_user_role+$OFF)
   || jsonb_build_object('id_enterprise',$SENT))::json)).*
FROM user_roles r WHERE id_enterprise=$SRC_ENT;

INSERT INTO users SELECT (json_populate_record(NULL::users,
  (to_jsonb(u) || jsonb_build_object('id_user',u.id_user+$OFF)
   || jsonb_build_object('id_enterprise',$SENT)
   || jsonb_build_object('user_roles',u.user_roles+$OFF)
   || jsonb_build_object('id_user_firebase','sbx-'||(u.id_user+$OFF)::text)
   || jsonb_build_object('id_user_cognito',NULL))::json)).*
FROM users u WHERE id_enterprise=$SRC_ENT;

-- client_descriptors: deep-remapped MIRROR of the real client edge (ADR-0045).
-- A recursive jsonb walker offsets every id_equipment/id_unit by $OFF and rewrites
-- every CPACK string -> SBXCPACK (topics, device_keys, canonical prefix, agent/tee
-- ids, secret refs). enterprise_id + tenant are set explicitly. status='generated'
-- so csadmin's onboarding wizard + sensor-config render it as a provisioned tenant
-- (a bare draft renders an EMPTY tag map). artifacts/validation are left NULL — a
-- derived cache; run the onboarding "generate" step for tenant-correct artifacts.
CREATE OR REPLACE FUNCTION pg_temp.sbx_remap(j jsonb) RETURNS jsonb AS \$f\$
DECLARE result jsonb; k text; v jsonb; elem jsonb; arr jsonb;
BEGIN
  IF jsonb_typeof(j)='object' THEN
    result := '{}'::jsonb;
    FOR k, v IN SELECT * FROM jsonb_each(j) LOOP
      IF k IN ('id_equipment','id_unit') AND jsonb_typeof(v)='number' THEN
        result := result || jsonb_build_object(k, (v::int + $OFF));
      ELSE
        result := result || jsonb_build_object(k, pg_temp.sbx_remap(v));
      END IF;
    END LOOP;
    RETURN result;
  ELSIF jsonb_typeof(j)='array' THEN
    arr := '[]'::jsonb;
    FOR elem IN SELECT * FROM jsonb_array_elements(j) LOOP
      arr := arr || jsonb_build_array(pg_temp.sbx_remap(elem));
    END LOOP;
    RETURN arr;
  ELSIF jsonb_typeof(j)='string' THEN
    RETURN to_jsonb(replace(replace(j #>> '{}', 'CPACK','SBXCPACK'),'cpack','sbxcpack'));
  ELSE RETURN j;
  END IF;
END \$f\$ LANGUAGE plpgsql;

INSERT INTO client_descriptors
  (id_enterprise, tenant_code, descriptor, version, status, artifacts, validation, created_by, updated_by)
SELECT $SENT, 'SBXCPACK',
  jsonb_set(jsonb_set(pg_temp.sbx_remap(descriptor),'{enterprise_id}',to_jsonb($SENT)),'{tenant}','"SBXCPACK"'),
  version, 'generated', NULL, NULL, 'sandbox-mirror:ent'||$SRC_ENT, 'sandbox-mirror:ent'||$SRC_ENT
FROM client_descriptors WHERE id_enterprise=$SRC_ENT;

SET session_replication_role = DEFAULT;

SELECT 'SANDBOX-CPACK ready: ent '||$SENT AS status,
  (SELECT count(*) FROM equipments WHERE id_enterprise=$SENT) AS equipments,
  (SELECT count(*) FROM equipments WHERE id_enterprise=$SENT AND id_parentequipment IS NOT NULL) AS members_linked,
  (SELECT count(*) FROM users WHERE id_enterprise=$SENT) AS users,
  (SELECT (descriptor->'plc'->'s7_tag_map') IS NOT NULL FROM client_descriptors WHERE id_enterprise=$SENT) AS descriptor_has_plc;
SQL

# ── Assemble the run per mode ─────────────────────────────────────────────────
case "$MODE" in
  delete) SQL="BEGIN; $SQL_DELETE COMMIT;" ;;
  reset)  SQL="BEGIN; $SQL_DELETE $SQL_CREATE COMMIT;" ;;
  create) SQL="BEGIN; $SQL_CREATE COMMIT;" ;;
esac

# ── Execute via SSM -> staging app box -> dockerized psql ─────────────────────
sql_b64=$(printf '%s' "$SQL" | base64 -w0)
remote=$(cat <<REMOTE
set -e
set -a; . /opt/packiot/.env; set +a
tmp=\$(mktemp /tmp/sbx.XXXXXX.sql)
trap 'rm -f "\$tmp"' EXIT
echo $sql_b64 | base64 -d > "\$tmp"
docker run --rm -i --network stack_packiot-net -e PGPASSWORD="\$POSTGRES_PASSWORD" \
  -v "\$tmp":/q.sql:ro postgres:16-alpine \
  psql -h "\$POSTGRES_HOST_UPSTREAM" -p 5432 -U "\$POSTGRES_USER" -d "\$POSTGRES_DB" \
       -v ON_ERROR_STOP=1 -f /q.sql
REMOTE
)
remote_b64=$(printf '%s' "$remote" | base64 -w0)
echo "[$MODE] provisioning SANDBOX-CPACK (ent $SENT) on staging…"
script -qec "aws ssm start-session --target $APP_INSTANCE \
  --document-name AWS-StartNonInteractiveCommand \
  --parameters 'command=[\"bash -c echo\${IFS}$remote_b64|base64\${IFS}-d|sudo\${IFS}bash\"]' \
  --region $REGION" /dev/null 2>/dev/null \
  | tr -d '\r' | grep -av -e '^Starting session' -e '^Exiting session' || true

# ── RMQ topology: emit the twin's re-tenant fan-out config (task #22) ─────────
# stream-engine's queue for the sandbox needs no help (auto-declared from
# packml_register at boot). What create/reset DOES still need to hand off is
# the re-tenant fan-out that clones the SOURCE_GROUP's live stream onto
# TARGET_GROUP's routing key — emit (or re-emit) its compose+.env config here.
# Pure local file generation (no SSM, no DB) — safe to run every create/reset,
# deterministic overwrite, never touches anything that isn't this twin's own
# generated file.
if [ "$MODE" != "delete" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$SCRIPT_DIR/emit-fanout-config.sh" "$SOURCE_GROUP" "$TARGET_GROUP"
fi

# ── Operator-ACTION twin: nothing to emit here (codified in compose) ──────────
# The fan-out above only re-tenants the live TELEMETRY (counters). Operator
# ACTIONS (PO lifecycle / downtimes / justifications / manual events) reach the
# sandbox via the committed compose service `legacy-replicator-sbx` — a second
# instance of the legacy-replicator binary (SRC_ENTERPRISE=1 -> DST_ENTERPRISE=
# 2000003, CURSOR_SOURCE=legacy-sbxcpack), gated by REPLICATE_SBX_ENABLED=true in
# .env. It resolves the +2M sandbox equipment ids by packml base-topic (no id
# arithmetic) and writes idempotent natural-key upserts, so it survives a
# --reset with no action here: the cursor persists in mirror_replay_cursor and
# the loop simply continues. To activate on a fresh box: set
# REPLICATE_SBX_ENABLED=true and `docker compose up -d legacy-replicator-sbx`.
