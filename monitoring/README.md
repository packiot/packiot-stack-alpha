# monitoring/ — Prometheus + Loki + Promtail configs

- `prometheus/prometheus.yml` — 15s scrape, `env=staging` external
  label. Scrape jobs: itself · `oeecloud-worker:9101` (with a
  routing-key→tenant relabel) · `mirror-worker-go:9102` ·
  `edge-transformer:9102` (calc_*/outbox_*/shadowpub_*/mqtt_*) ·
  `shadow-mirror:9103` (scraped since 2026-07-06; disappears at the
  flip, R1).
- `loki/loki-local-config.yaml` — single-binary Loki, filesystem
  storage, :3100.
- `promtail/promtail-config.yaml` — Docker service discovery → Loki;
  relabels on compose project "stack".

- `prometheus/rules.yml` — 5 alerting rules (scrape down, engine
  error streak, engine stalled, ingest silent, write path dry) —
  added 2026-07-07 (roadmap B1). Alerts surface in Prometheus
  `/alerts` + Grafana. **Open human choice**: push routing
  (Alertmanager → ntfy/email) — wire it only when someone commits to
  reading it; the 09-board named-cause ritual remains the correctness
  alarm.

- **Production** (compose.production.yml, since 2026-10-16) has its own
  `prometheus/prometheus.production.yml` (`env=production`; profile-gated
  services discovered by DNS, so a disabled profile is not a down target),
  `prometheus/rules.production.yml` (the subset of rules.yml that applies;
  keep shared rules in sync) and `alertmanager/alertmanager.production.yml`
  (Slack, titled ":factory: PRODUCTION"). Secrets are files on the host,
  written by deploy-production.yml: `packiot/production/app.slack_api_url`
  → /opt/packiot/alerting/slack_api_url and
  `packiot/production/postgres-exporter-db-creds.password` →
  /opt/packiot/postgres-exporter/password (role: db/migrations/t-postgres-exporter-role).
