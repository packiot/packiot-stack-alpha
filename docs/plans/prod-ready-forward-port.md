# Plan — get the `production` branch READY (forward-port proven staging stack, no live cutover)

**Status:** IN PROGRESS (2026-09-07). Task #190. Scope: make `production` deployable
and current with the proven staging stack. NO live data/traffic cutover.

## Context
Prod is a **greenfield F3-native** deployment: single `packiot` DB whose `public`
schema = the F3 layout (seeded from a schema-only snapshot of staging's
`packiot_analytics`); Cognito-native; `REFDATA_FLOW=f3`; deploy-production.yml
deploys `compose.production.yml` on push to `production` via a self-hosted prod
runner. It is NOT an old-stack migration.

`origin/production` is +58 (prod-specific: compose.production.yml, terraform/
production, superset/historian/WAF infra) and −498 (all staging hardening) vs
staging. Service **code** on production is pre-rename (merge-base ddd489c4/#811).
A raw `git merge staging` is the WRONG tool (submodule + terraform conflicts,
brings renamed dirs as ADDs without repointing compose). → **targeted forward-port
on a branch off `origin/production`.**

## CORRECTNESS CRUX (cutover-gated)
The F3 schema snapshot (`db/init-f3/snapshot/`) still uses `runtime_*` table names
(173 refs, 0 `oee_*`), but the proven services read `oee_*`. The
`db/migrations/analytics-rename/` migrations exist only on staging and are NOT in
prod's db-init. A greenfield prod seeded today ends at `runtime_*` and its services
break. **Fix = regenerate the snapshot via `scripts/capture-f3-snapshot.sh` against
current `packiot_analytics` (DB EC2 i-064bb36d…, BEGIN READ ONLY) so the rename +
#186 grain drops bake in; validate with `scripts/prod-f3-schema-parity-check.sh`.**
Needs live DB access → cutover-gated. Until done, prod is NOT safe to seed.

## SAFE NOW (branch/config readiness — no live effect)
1. **Submodule pin bumps (clean forward-ports):**
   - operator → `4fd78c936acace2c44564a5da3bc44658af83ca6`
   - edge-node-red → `5e84ae9a4888354ac522d5d2db8e8cc6445b14e3`
   - csadmin → `e761114af503ac000423d62fc200d8c31b79f679`
2. **edge-api (DIVERGENT — rebase, not bump):** new commit = staging
   `85dc2320` (carries #159 + #188 + rename repoints) + re-apply the 2 prod-specific
   commits `b6b1b6f` (superset-embed origin-lock/CSRF) + `c373041` (CORS
   front.prod.packiot.app); then re-pin. Verify the retired set-operator-password is
   gone + no operator_pw_hash refs remain.
3. **Shared service-code sync + compose build-context repoint** (prod builds the OLD
   dir names): adopt staging's renamed dirs and repoint `compose.production.yml`:
   `oeecloud-worker`→`stream-engine`, `edge-transformer`→`sparkplug-decoder`,
   `refdata-api`→`read-api`, `operator-adapter`→`operator-gateway`,
   `shadow-mirror`→`analytics-sync`; remove the old dirs (clean-trails). Carries
   #186/#187/T6/backfill/allowlist code.
4. **Observability/config dirs** (staging-strictly-ahead, low risk): `monitoring/`,
   `grafana/` (note `dashboards-v2`→`dashboards`), `scripts/`.
5. **Snapshot files** (structural, still need regen per crux): add
   `db/init-f3/snapshot/15-f3-read-api-composite-type-fixes.sql` (REQUIRED — 9
   read-api /v1/query datasets 500 without it); update `05-*.sql`, `10-*.sql` to
   staging; adopt staging `MANIFEST.f3-target` (307, drops 3 unused h_piot_* — verify D4).
6. **compose.production.yml config (client-agnostic forward-ports):**
   - `ROLLUP_BACKFILL_ENABLED: "true"` + `ROLLUP_BACKFILL_INTERVAL_SECONDS: "7"`
     (coupled to stream-engine/internal/rollup/backfill.go).
   - Tenant/decision-dependent keys: see Decisions.

## CUTOVER-GATED (needs live access / traffic — separate, human-triggered)
- **Snapshot regeneration** (the crux) — live `packiot_analytics` read.
- **`terraform plan`** from `origin/production` (NOT from `feat/prod-first-boot-
  hardening` — that branch would destroy WAF/certs) → review → apply.
- DNS, first-client data seed/onboard, `COGNITO_AUTH_ENABLED=true` runtime flip,
  traffic cutover.

## HUMAN DECISIONS
- **D1 — which tenants will prod host?** Drives `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES`
  (`"3"` vs `"3,5"`…), and whether `EVENTS_CLOSE_STALE_*` (status_type=0 tenant),
  `COUNTERS_ONLY_AVAILABILITY_*`, `SAP13_*` apply. Greenfield default = per-client at
  onboarding.
- **D2 — enable `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` in prod?**
- **D3 — adopt the historian hot/cold gateway in prod** (add
  `compose.historian-gateway.yml` + `HIST_GW_*` + the dir)? Prod has `historian.tf`
  infra but no gateway service.
- **D4 — confirm the 3 dropped `h_piot_*` fns unused** before adopting the leaner MANIFEST.
- **D5 — snapshot-regen ownership** (who/when runs capture against live analytics).

## Risk surface
edge-api rebase (don't lose the 2 prod commits / re-introduce operator-password);
snapshot↔service name mismatch (silent-wrong-OEE if seeded pre-regen — parity gate is
the backstop); terraform diverged prod-specifically (do NOT merge staging's over it);
do not `terraform apply` from feat/prod-first-boot-hardening.
