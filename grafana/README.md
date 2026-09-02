# grafana/ — dashboards & provisioning

Dashboards are **file-provisioned** (`provisioning/dashboards/all.yml`,
provider `packiot-v2` → folder "Packiot v2", 10s reload; UI edits allowed
but files are the source of truth — export back to JSON or lose the change
on the next reload).

Datasources (`provisioning/datasources/`): `packiot-postgres` (**default**;
DB `packiot` — F1, the pre-flip source), `packiot-postgres-shadow` (DB
`packiot_analytics` — F3, the post-flip source of truth; uid kept as-is
across the F3 rename since every v2 panel references it by uid), `packiot-prometheus`,
`packiot-loki`, `packiot-tempo`.

**The board map, per-board audience, and the live-verified metric universe
live in [`dashboards-v2/README.md`](./dashboards-v2/README.md) and
[`dashboards-v2/_SPEC.md`](./dashboards-v2/_SPEC.md) — that's the canonical,
maintained doc.** This file used to describe a "Packiot" v1 board set
(`oee-pipeline`, `bake-flow-parity`, etc.) — that set was fully reviewed,
rebuilt as v2, and **deleted** in 2026-07 once v2 was blessed (see
`dashboards-v2/README.md`'s "Retiring v1" section). If you're reading old
docs/notes that reference v1 uids, they no longer exist; the v2 uid is
usually the same board renumbered — check the v2 README's board table.
