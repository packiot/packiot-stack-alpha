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

**Known gap (deliberate, on the ledger): no alerting or recording
rules.** Alarm discipline today is human: the 09-bake board's
named-cause rule + dashboard expiry dates (see `overview/06`). If you
add `rule_files`, wire alerts to something a human reads — an alert
nobody routes is worse than the current explicit "check 09 daily".
