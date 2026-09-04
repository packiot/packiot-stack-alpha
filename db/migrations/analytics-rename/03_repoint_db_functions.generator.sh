#!/usr/bin/env bash
set -uo pipefail
echo "cy9cYmVxdWlwbWVudF9ydW50aW1lX3NoaWZ0XzFtb250aFxiL2VxdWlwbWVudF9vZWVfc2hpZnRfbW9udGhseS9nOwpzL1xidW5zX2VxdWlwbWVudF9jdXJyZW50X21ldHJpY3NcYi9lcXVpcG1lbnRfbGl2ZV9tZXRyaWNzL2c7CnMvXGJlcXVpcG1lbnRfcnVudGltZV9zaGlmdF8xd2Vla1xiL2VxdWlwbWVudF9vZWVfc2hpZnRfd2Vla2x5L2c7CnMvXGJ1bnNfZXF1aXBtZW50X2N1cnJlbnRfc2hpZnRcYi9lcXVpcG1lbnRfbGl2ZV9zaGlmdC9nOwpzL1xidW5zX2VxdWlwbWVudF9jdXJyZW50X21vbnRoXGIvZXF1aXBtZW50X2xpdmVfbW9udGgvZzsKcy9cYnVuc19lcXVpcG1lbnRfY3VycmVudF93ZWVrXGIvZXF1aXBtZW50X2xpdmVfd2Vlay9nOwpzL1xidW5zX2VxdWlwbWVudF9jdXJyZW50X2hvdXJcYi9lcXVpcG1lbnRfbGl2ZV9ob3VyL2c7CnMvXGJ1bnNfZXF1aXBtZW50X2N1cnJlbnRfam9iXGIvZXF1aXBtZW50X2xpdmVfam9iL2c7CnMvXGJ1bnNfZXF1aXBtZW50X2N1cnJlbnRfZGF5XGIvZXF1aXBtZW50X2xpdmVfZGF5L2c7CnMvXGJlcXVpcG1lbnRfcnVudGltZV8xbW9udGhcYi9lcXVpcG1lbnRfb2VlX21vbnRobHkvZzsKcy9cYmVxdWlwbWVudF9ydW50aW1lX3NoaWZ0XGIvZXF1aXBtZW50X29lZV9zaGlmdC9nOwpzL1xiZXF1aXBtZW50X3J1bnRpbWVfMXdlZWtcYi9lcXVpcG1lbnRfb2VlX3dlZWtseS9nOwpzL1xiZXF1aXBtZW50X3J1bnRpbWVfMWhvdXJcYi9lcXVpcG1lbnRfb2VlX2hvdXJseS9nOwpzL1xidW5zX3NpdGVfY3VycmVudF9tb250aFxiL3NpdGVfbGl2ZV9tb250aC9nOwpzL1xidW5zX2FyZWFfY3VycmVudF9zaGlmdFxiL2FyZWFfbGl2ZV9zaGlmdC9nOwpzL1xidW5zX2FyZWFfY3VycmVudF9tb250aFxiL2FyZWFfbGl2ZV9tb250aC9nOwpzL1xiZXF1aXBtZW50X3J1bnRpbWVfMWRheVxiL2VxdWlwbWVudF9vZWVfZGFpbHkvZzsKcy9cYnVuc19zaXRlX2N1cnJlbnRfd2Vla1xiL3NpdGVfbGl2ZV93ZWVrL2c7CnMvXGJ1bnNfc2l0ZV9jdXJyZW50X2hvdXJcYi9zaXRlX2xpdmVfaG91ci9nOwpzL1xidW5zX2FyZWFfY3VycmVudF93ZWVrXGIvYXJlYV9saXZlX3dlZWsvZzsKcy9cYnVuc19hcmVhX2N1cnJlbnRfaG91clxiL2FyZWFfbGl2ZV9ob3VyL2c7CnMvXGJ1bnNfc2l0ZV9jdXJyZW50X2RheVxiL3NpdGVfbGl2ZV9kYXkvZzsKcy9cYnVuc19hcmVhX2N1cnJlbnRfZGF5XGIvYXJlYV9saXZlX2RheS9nOwpzL1xic2l0ZV9ydW50aW1lXzFtb250aFxiL3NpdGVfb2VlX21vbnRobHkvZzsKcy9cYmFyZWFfcnVudGltZV8xbW9udGhcYi9hcmVhX29lZV9tb250aGx5L2c7CnMvXGJzaXRlX3J1bnRpbWVfc2hpZnRcYi9zaXRlX29lZV9zaGlmdC9nOwpzL1xic2l0ZV9ydW50aW1lXzF3ZWVrXGIvc2l0ZV9vZWVfd2Vla2x5L2c7CnMvXGJzaXRlX3J1bnRpbWVfMWhvdXJcYi9zaXRlX29lZV9ob3VybHkvZzsKcy9cYmFyZWFfcnVudGltZV9zaGlmdFxiL2FyZWFfb2VlX3NoaWZ0L2c7CnMvXGJhcmVhX3J1bnRpbWVfMXdlZWtcYi9hcmVhX29lZV93ZWVrbHkvZzsKcy9cYmFyZWFfcnVudGltZV8xaG91clxiL2FyZWFfb2VlX2hvdXJseS9nOwpzL1xic2l0ZV9ydW50aW1lXzFkYXlcYi9zaXRlX29lZV9kYWlseS9nOwpzL1xiYXJlYV9ydW50aW1lXzFkYXlcYi9hcmVhX29lZV9kYWlseS9nOwo=" | base64 -d > /tmp/repoint.pl
echo "ZXF1aXBtZW50X3J1bnRpbWVfc2hpZnRfMW1vbnRoCnVuc19lcXVpcG1lbnRfY3VycmVudF9tZXRyaWNzCmVxdWlwbWVudF9ydW50aW1lX3NoaWZ0XzF3ZWVrCnVuc19lcXVpcG1lbnRfY3VycmVudF9zaGlmdAp1bnNfZXF1aXBtZW50X2N1cnJlbnRfbW9udGgKdW5zX2VxdWlwbWVudF9jdXJyZW50X3dlZWsKdW5zX2VxdWlwbWVudF9jdXJyZW50X2hvdXIKdW5zX2VxdWlwbWVudF9jdXJyZW50X2pvYgp1bnNfZXF1aXBtZW50X2N1cnJlbnRfZGF5CmVxdWlwbWVudF9ydW50aW1lXzFtb250aAplcXVpcG1lbnRfcnVudGltZV9zaGlmdAplcXVpcG1lbnRfcnVudGltZV8xd2VlawplcXVpcG1lbnRfcnVudGltZV8xaG91cgp1bnNfc2l0ZV9jdXJyZW50X21vbnRoCnVuc19hcmVhX2N1cnJlbnRfc2hpZnQKdW5zX2FyZWFfY3VycmVudF9tb250aAplcXVpcG1lbnRfcnVudGltZV8xZGF5CnVuc19zaXRlX2N1cnJlbnRfd2Vlawp1bnNfc2l0ZV9jdXJyZW50X2hvdXIKdW5zX2FyZWFfY3VycmVudF93ZWVrCnVuc19hcmVhX2N1cnJlbnRfaG91cgp1bnNfc2l0ZV9jdXJyZW50X2RheQp1bnNfYXJlYV9jdXJyZW50X2RheQpzaXRlX3J1bnRpbWVfMW1vbnRoCmFyZWFfcnVudGltZV8xbW9udGgKc2l0ZV9ydW50aW1lX3NoaWZ0CnNpdGVfcnVudGltZV8xd2VlawpzaXRlX3J1bnRpbWVfMWhvdXIKYXJlYV9ydW50aW1lX3NoaWZ0CmFyZWFfcnVudGltZV8xd2VlawphcmVhX3J1bnRpbWVfMWhvdXIKc2l0ZV9ydW50aW1lXzFkYXkKYXJlYV9ydW50aW1lXzFkYXkK" | base64 -d > /tmp/oldnames.txt
Q(){ docker exec timescaledb psql -U postgres -d packiot_analytics -Atc "$1"; }
SEL='(equipment_runtime_|area_runtime_|site_runtime_|uns_equipment_current|uns_area_current|uns_site_current)'
Q "SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p') AND p.prosrc ~ '${SEL}'" > /tmp/oids.txt
echo "functions selected: $(wc -l < /tmp/oids.txt)"
printf 'BEGIN;\nSET LOCAL check_function_bodies=off;\n' > /tmp/repoint.sql
while read -r oid; do [ -z "$oid" ] && continue
  Q "SELECT pg_get_functiondef($oid)" | perl -p /tmp/repoint.pl >> /tmp/repoint.sql
  printf ';\n' >> /tmp/repoint.sql
done < /tmp/oids.txt
echo "COMMIT;" >> /tmp/repoint.sql
echo "defs generated: $(grep -c 'CREATE OR REPLACE' /tmp/repoint.sql)"
# whole-word old TABLE names remaining in generated SQL (grep -w: _ is word char, so proc names & _1week compounds excluded)
REM=$(grep -woFf /tmp/oldnames.txt /tmp/repoint.sql | sort | uniq -c)
echo "=== whole-word old table names remaining in generated defs (expect empty) ==="; echo "$REM"
echo "=== proc names preserved (sample) ==="; grep -woE 'piot_(create|get)_[a-z_]*runtime[a-z0-9_]*' /tmp/repoint.sql | sort -u | head -3
if [ "${APPLY:-0}" = "1" ]; then
  echo "=== APPLYING ==="
  docker exec -i timescaledb psql -U postgres -d packiot_analytics -v ON_ERROR_STOP=1 < /tmp/repoint.sql 2>&1 | tail -3
  echo "post-apply: functions whose body still has any whole-word old name:"
  Q "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosrc ~ '${SEL}'" 
  echo "(that count includes proc-name self-refs like piot_create_equipment_runtime_shift which are EXPECTED to remain)"
else
  echo "=== DRY-RUN parse (rolled back) ==="
  (echo "BEGIN;"; echo "SET LOCAL check_function_bodies=off;"; sed '1,2d;$d' /tmp/repoint.sql; echo "ROLLBACK;") \
    | docker exec -i timescaledb psql -U postgres -d packiot_analytics -v ON_ERROR_STOP=1 2>&1 | grep -icE 'CREATE (FUNCTION|PROCEDURE)' | xargs echo "defs that parsed OK:"
  (echo "BEGIN;"; echo "SET LOCAL check_function_bodies=off;"; sed '1,2d;$d' /tmp/repoint.sql; echo "ROLLBACK;") \
    | docker exec -i timescaledb psql -U postgres -d packiot_analytics -v ON_ERROR_STOP=1 2>&1 | grep -iE 'ERROR' | head -3
fi
