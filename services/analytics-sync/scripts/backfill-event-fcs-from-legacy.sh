set -e
# One-off (applied 2026-09-25 on staging): copy equipment_events.forced_creation_system
# from legacy (ent 1) onto CPACK ent 3 and its +2M sandbox twin for events since
# 2026-05-01, matched by (packml topic -> equipment, ts_event). MODE=dry (default,
# ROLLBACK) or MODE=apply. Run on the staging app host (reaches both DBs).
# Result: 256,306 flags fixed; running POs with operator downtime > 0: 0/16 -> 14/16.
MODE="${MODE:-dry}"
S=$(aws secretsmanager get-secret-value --region us-east-1 --secret-id databaseCredentials --query SecretString --output text)
eval "$(echo "$S" | python3 -c 'import json,sys,shlex; d=json.load(sys.stdin); [print(f"export {k}={shlex.quote(str(v))}") for k,v in d.items() if k in ("DB_HOST","DB_PORT","DB_USER","DB_NAME","DB_PASSWORD")]')"
AU=$(grep -m1 '^POSTGRES_USER=' /opt/packiot/.env | cut -d= -f2-); AP=$(grep -m1 '^POSTGRES_PASSWORD=' /opt/packiot/.env | cut -d= -f2-)
IMG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -m1 -E '^(postgres|timescale/timescaledb)' || true); IMG=${IMG:-postgres:16-alpine}
W=/tmp/fcs-backfill; mkdir -p $W
docker run --rm -e PGPASSWORD="$DB_PASSWORD" $IMG psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -At -c "BEGIN READ ONLY" -c "COPY (SELECT replace(pr.packml_topic,'C-PACK','CPACK'), to_char(ee.ts_event AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.USZ'), ee.forced_creation_system FROM equipment_events ee JOIN (SELECT DISTINCT ON (id_equipment) id_equipment, packml_topic FROM packml_register WHERE id_enterprise=1 AND active AND id_equipment IS NOT NULL ORDER BY id_equipment, packml_topic) pr USING (id_equipment) WHERE ee.id_enterprise=1 AND ee.ts_event >= '2026-05-01') TO STDOUT WITH CSV" -c "COMMIT" | grep -v '^BEGIN$\|^COMMIT$' > $W/leg.csv
echo "legacy rows: $(wc -l < $W/leg.csv)"
END=ROLLBACK; [ "$MODE" = apply ] && END=COMMIT
{ cat <<SQL
\set ON_ERROR_STOP 1
\timing on
BEGIN;
CREATE TEMP TABLE leg (topic text, ts timestamptz, fcs boolean);
\copy leg FROM STDIN WITH CSV
SQL
cat $W/leg.csv; echo '\.'
cat <<SQL
CREATE TEMP TABLE map AS SELECT DISTINCT ON (id_enterprise, packml_topic) id_enterprise, packml_topic, id_equipment FROM core.packml_register WHERE id_enterprise = 3 AND active AND id_equipment IS NOT NULL ORDER BY id_enterprise, packml_topic, id_equipment;
INSERT INTO map SELECT 2000003, m.packml_topic, m.id_equipment + 2000000 FROM map m JOIN core.equipments s ON s.id_equipment = m.id_equipment + 2000000 AND s.id_enterprise = 2000003;
SELECT 'legacy topics unmapped', count(DISTINCT l.topic) FROM leg l WHERE NOT EXISTS (SELECT 1 FROM map m WHERE m.packml_topic=l.topic AND m.id_enterprise=3);
SELECT 'matched rows', m.id_enterprise, count(*), count(*) FILTER (WHERE ev.forced_creation_system IS DISTINCT FROM l.fcs) to_change, count(*) FILTER (WHERE NOT l.fcs AND ev.forced_creation_system) true_to_false, count(*) FILTER (WHERE l.fcs AND NOT ev.forced_creation_system) false_to_true
  FROM leg l JOIN map m ON m.packml_topic=l.topic JOIN silver.equipment_events ev ON ev.id_equipment=m.id_equipment AND ev.ts_event=l.ts AND ev.id_enterprise=m.id_enterprise GROUP BY m.id_enterprise;
UPDATE silver.equipment_events ev SET forced_creation_system = l.fcs, last_update = now()
  FROM leg l JOIN map m ON m.packml_topic=l.topic
 WHERE ev.id_equipment=m.id_equipment AND ev.ts_event=l.ts AND ev.id_enterprise=m.id_enterprise AND ev.forced_creation_system IS DISTINCT FROM l.fcs;
SELECT 'po downtime ent3 running', count(*), count(*) FILTER (WHERE downtime > 0) FROM serving.v_operator_po_details_3 d JOIN core.production_orders po USING (id_production_order) WHERE d.id_enterprise=3 AND po.status=2;
SELECT 'po downtime sbx running', count(*), count(*) FILTER (WHERE downtime > 0) FROM serving.v_operator_po_details_3 d JOIN core.production_orders po USING (id_production_order) WHERE d.id_enterprise=2000003 AND po.status=2;
$END;
SQL
} | docker run --rm -i -e PGPASSWORD="$AP" $IMG psql -h 10.10.10.89 -U "$AU" -d packiot_analytics -At -F'|' 2>&1 | grep -vE '^\s*$|^BEGIN|^SELECT [0-9]|^CREATE|^COPY'
