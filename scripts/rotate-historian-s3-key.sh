#!/usr/bin/env bash
# rotate-historian-s3-key.sh — rotate the svc-historian-gateway S3 read key (pg_duckdb cold
# archive) with ZERO secret exposure: the new secret goes IAM → Secrets Manager → box and is
# never printed, never in an SSM command body, never in TF state.
#
#   1. create a new access key → packiot/staging/historian-gateway-s3 {key_id, secret}
#   2. box (SSM): rewrite HIST_AWS_KEY/SECRET in /opt/packiot/.env.historian-gateway (only
#      used on a FRESH gateway volume) + ALTER USER MAPPING postgres@simple_s3_secret (the
#      LIVE credential) + historian/apply-hardening.sh (re-clones it for historian_svc —
#      pg_duckdb S3 secrets are PER-ROLE user mappings)
#   3. verify cold reads as postgres AND historian_svc
#   4. deactivate the old key, recycle gateway client backends (pg_duckdb loads the secret
#      once per backend — pooled read-api/Superset sessions keep the old one), verify again
#   5. delete the old key
# Usage (workstation with AWS creds):  scripts/rotate-historian-s3-key.sh
set -euo pipefail
USER_NAME=svc-historian-gateway; SECRET_ID=packiot/staging/historian-gateway-s3
APP="${APP_INSTANCE:-i-06c9547a2c7091ab7}"; REGION=us-east-1
run(){ local id; id=$(aws ssm send-command --region $REGION --instance-ids "$APP" --document-name AWS-RunShellScript \
  --parameters "$(jq -nc --arg c "$1" '{commands:[$c]}')" --query Command.CommandId --output text)
  aws ssm wait command-executed --region $REGION --command-id "$id" --instance-id "$APP" 2>/dev/null || true
  aws ssm get-command-invocation --region $REGION --command-id "$id" --instance-id "$APP" --query '[Status,StandardOutputContent,StandardErrorContent]' --output text; }
VERIFY='G(){ docker exec -i hist-gateway psql -U postgres -d packiot_historian -At "$@"; }
PW=$(grep -hE "^HIST_GW_SVC_PASSWORD=" /opt/packiot/.env /opt/packiot/.env.historian-gateway | head -1 | cut -d= -f2-)
a=$(G -c "SET statement_timeout=\x2760s\x27; SELECT count(*) FROM cold.production_orders" 2>&1 | tail -1)
b=$(docker exec -i -e PGPASSWORD="$PW" hist-gateway psql -h 127.0.0.1 -U historian_svc -d packiot_historian -At -c "SELECT count(*) FROM cold.production_orders" 2>&1 | tail -1)
echo "postgres=$a historian_svc=$b"; [ "$a" -gt 0 ] && [ "$a" = "$b" ]'
VERIFY=$(printf '%b' "$VERIFY")

N=$(aws iam list-access-keys --user-name $USER_NAME --query 'length(AccessKeyMetadata)' --output text)
[ "$N" -lt 2 ] || { echo "user already has 2 keys — finish/clean a previous rotation first"; exit 1; }
OLD=$(aws iam list-access-keys --user-name $USER_NAME --query 'AccessKeyMetadata[0].AccessKeyId' --output text)
NEWJSON=$(aws iam create-access-key --user-name $USER_NAME --output json | jq -c '{key_id:.AccessKey.AccessKeyId, secret:.AccessKey.SecretAccessKey}')
if aws secretsmanager describe-secret --region $REGION --secret-id $SECRET_ID >/dev/null 2>&1; then
  printf '%s' "$NEWJSON" | aws secretsmanager put-secret-value --region $REGION --secret-id $SECRET_ID --secret-string file:///dev/stdin >/dev/null
else
  printf '%s' "$NEWJSON" | aws secretsmanager create-secret --region $REGION --name $SECRET_ID --secret-string file:///dev/stdin >/dev/null
fi
unset NEWJSON; echo "[1] new key stored in $SECRET_ID"

BOX=$(cat <<'B'
set -euo pipefail
F=/opt/packiot/.env.historian-gateway
J=$(aws secretsmanager get-secret-value --region us-east-1 --secret-id packiot/staging/historian-gateway-s3 --query SecretString --output text)
export NK=$(printf '%s' "$J" | jq -r .key_id) NS=$(printf '%s' "$J" | jq -r .secret); unset J
cp -p $F $F.bak-$(date +%s); chmod 600 $F.bak-*
awk 'BEGIN{k=ENVIRON["NK"]; s=ENVIRON["NS"]} /^HIST_AWS_KEY=/{print "HIST_AWS_KEY=" k; next} /^HIST_AWS_SECRET=/{print "HIST_AWS_SECRET=" s; next} {print}' $F > $F.new
chmod --reference=$F $F.new; chown --reference=$F $F.new; mv $F.new $F
docker exec -i -e NK -e NS hist-gateway sh -c 'psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -q -v k="$NK" -v s="$NS"' <<'SQL'
ALTER USER MAPPING FOR postgres SERVER simple_s3_secret OPTIONS (SET key_id :'k', SET secret :'s');
SQL
unset NK NS
export HIST_GW_SVC_PASSWORD=$(grep -hE '^HIST_GW_SVC_PASSWORD=' /opt/packiot/.env $F | head -1 | cut -d= -f2-)
bash /opt/packiot/historian/apply-hardening.sh 2>&1 | grep -vi password | tail -2
B
)
run "$BOX"; echo "[2] box updated"
run "$VERIFY" | grep -q "postgres=" && echo "[3] reads OK with both keys active"
aws iam update-access-key --user-name $USER_NAME --access-key-id "$OLD" --status Inactive
run "docker exec hist-gateway psql -U postgres -d packiot_historian -At -c \"SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE backend_type='client backend' AND pid<>pg_backend_pid() AND usename IN ('historian_svc','postgres','cloudbeaver_histro')\"; sleep 10; $VERIFY" \
  | tee /dev/stderr | grep -q "^Success" || { echo "VERIFY FAILED with old key inactive — reactivating old key"; aws iam update-access-key --user-name $USER_NAME --access-key-id "$OLD" --status Active; exit 1; }
echo "[4] reads OK with old key INACTIVE"
aws iam delete-access-key --user-name $USER_NAME --access-key-id "$OLD"; echo "[5] old key deleted"
