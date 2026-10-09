# Observability startup flags (APPLIED via container recreate)

`packiot-postgres:local` reads settings from the postmaster `-c` command line
(overrides ALTER SYSTEM). The timescaledb container was recreated (bind-mounted
PGDATA persists) with:

```
-c shared_preload_libraries=timescaledb,pg_cron,pg_stat_statements,auto_explain   # timescaledb MUST stay first
-c cron.database_name=packiot
-c pg_stat_statements.max=10000
-c pg_stat_statements.track=all
-c auto_explain.log_min_duration=3000
-c auto_explain.log_analyze=on
-c auto_explain.log_nested_statements=on
-c log_min_duration_statement=3000
-c track_io_timing=on
-c log_checkpoints=on
-c log_lock_waits=on
-c log_autovacuum_min_duration=0
-c "log_line_prefix=%m [%p] %u@%d %a "
```

Also applied: `ALTER DATABASE packiot_analytics SET track_functions='pl';`
Codify these into the container launch (db_init.sh / the deploy that `docker run`s
`packiot-postgres:local`) so a redeploy keeps them. Backup of the pre-change
container config: `/root/ts-restart-backup/` on the DB box.

Remaining for full tracing: Alloy/OTel collector + OTLP spans from read-api /
edge-api / stream-engine -> Tempo (app code); postgres_exporter for the gateway;
Athena query metrics for the historian.
