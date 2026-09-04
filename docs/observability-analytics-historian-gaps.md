# Observability: analytics + historian — status & remaining config (#180)

Audited 2026-09-04. **Traces + metrics for the analytics DB are correctly wired**
(otelpgx spans → Tempo; postgres-exporter auto-discovers `packiot_analytics`,
cagg-lag/job/hypertable metrics in `monitoring/postgres-exporter/queries.yaml`).
**Applied now:** P3 cagg-freshness + TS-job-failure alerts (`monitoring/prometheus/rules.yml`,
using the already-flowing `pg_timescaledb_cagg/jobs` metrics — hot-reloaded by the deploy).

## Remaining gaps (ready-to-apply, deferred because they need infra changes)

### P1 — analytics DB logs → Loki (dark at 4 layers, highest value)
The `db-agent.alloy` comment claims postgres logs flow to Loki; the path is broken:
1. **No source logs** — `terraform/staging/user_data/db_init.sh:88` runs timescaledb
   without `log_min_duration_statement`/`auto_explain`. Add to the `-c` flags:
   `shared_preload_libraries=...,auto_explain`, `log_min_duration_statement=3000`,
   `log_destination=stderr`, `auto_explain.log_min_duration=3000`. **Needs container
   recreate (not restart).**
2. **No agent deployed** — `monitoring/alloy/db-agent.alloy` is referenced by nothing;
   deploy it on the DB box (append to `db_init.sh` after the pg_isready wait) with
   `ALLOY_LOKI_GATEWAY=http://<app_private_ip>:3101/loki/api/v1/push`.
3. **Receiver on loopback** — gateway `:3101` binds `${ALLOY_GATEWAY_BIND:-127.0.0.1}`,
   set nowhere; set `ALLOY_GATEWAY_BIND=<app_private_ip>` in `app_init.sh` `.env`.
4. **No view** — add a `{job="postgres",container="timescaledb"}` logs panel to
   `grafana/dashboards/08-logs.json`.
Deferred: requires DB-box replacement (terraform user_data) — not forced on a live box.

### P2 — historian gateway liveness metric (blackbox tcp)
Add a `blackbox-historian` scrape (`monitoring/prometheus/prometheus.yml`, tcp_connect
to `hist-gateway:5432`). **Blocked on verifying** hist-gateway shares the `packiot-net`
stack network with blackbox-exporter (it's a separate compose file). Verify network
reachability first, else the probe false-alarms.

### P4 — historian S3/Athena cost metrics (CloudWatch)
Add a Grafana CloudWatch datasource (`grafana/provisioning/datasources/cloudwatch.yml`,
region us-east-1, app-box instance-role IAM incl. `cloudwatch:GetMetricData`) + a small
dashboard reading `AWS/S3 BucketSizeBytes` + `AWS/Athena ProcessedBytes`. Needs an IAM
decision; deferred (historian cost is <$0.30/mo anyway — low urgency).
