# Overnight report — #190 prod-branch READY (2026-09-07)

**TL;DR:** The production branch's *safe-now* forward-port is **done and hard-proven**
on branch `forward-port/prod-ready` (pushed, 4 commits, **NOT merged, NOT deployed**).
`deploy-production.yml` fires only on push to `production`, so nothing shipped. Only
the genuinely cutover-gated steps (live-DB snapshot regen, terraform apply, DNS,
traffic) remain — deliberately left for you. One real latent bug was caught + fixed.

## What I did (each hard-proven, no assertions)

| Increment | What | Commit | Proof |
|---|---|---|---|
| 1 | Clean pins + compose config (rollup backfill, line-lead=3, super-admin on) | `27c74e33` | prior |
| 2+3 | edge-api rebase pin **corrected** + 4 service-dir renames + compose repoint + drop 2 dead dirs | `db290876` | `go build ./...` green ×6; `docker compose config -q` VALID; all pins fetchable + faithful to staging |
| 4a | historian-gateway added **inline** (your D3 "add for parity") | `16d305ce` | `docker compose config -q` VALID; 25 svcs, no dup IP |
| 4b | F3 snapshot: required `15` supplement + MANIFEST 307 (D4) + cutover tooling | `7f07ef3a` | D4 zero-caller grep; no dual-`00` |

## The bug I caught (this is why "hardproof only" matters)
The edge-api submodule pin set in the earlier increment was `39840a8393af…` — but the
**actual pushed commit is `39840a8ecb27…`**. Same 7-char prefix, *different commit*;
the full SHA I'd pinned **did not exist on any remote**, so CI's `submodule update`
would have failed the very first prod deploy. Found by verifying every pin is a real,
fetchable commit (not by trusting the plan's abbreviated SHA). Corrected in `db290876`
and re-verified against `origin/prod-forward-port`.

## Decisions I made (and why)
- **D4 (drop 3 `h_piot_*` fns from MANIFEST): CONFIRMED safe.** read-api calls the
  `_uns`/`_uns_N` variants; the dropped non-uns base forms have **zero** code callers
  (word-boundary grep across `services/` + `edge-api/src`). MANIFEST 310→307.
- **Observability (`monitoring/`, `grafana/`) → deferred to #180.** Hard-proof
  revealed staging's prometheus scrapes the *renamed* service keys (`stream-engine:9101`)
  while I kept prod's compose keys as the old names (`oeecloud-worker`). Adopting
  staging's configs now would break prod scraping. The key-rename + nginx-upstream +
  scrape/dashboard reconciliation is a coherent unit that belongs in #180, not an
  autonomous overnight edit. Prod's current observability stays internally consistent.
- **Compose service KEYS kept old; only build *contexts* repointed.** The proven
  *code* is forward-ported (builds `./services/stream-engine` etc.); renaming the keys
  ripples into nginx/depends_on/monitoring, so it rides with #180.
- **Snapshot: adopted staging's coherent placeholder set + the required `15`.** Both
  staging's committed `00` **and** its MANIFEST are pre-rename (`runtime_*`, frozen
  2026-08-20) — I verified this rather than assume they were current. So the
  post-rename schema genuinely requires the live regen (below); the committed set is a
  labelled placeholder + the parity gate is the backstop. Renamed the base
  `00-packiot_shadow-schema.sql → 00-packiot_analytics-schema.sql` so the cutover
  regen overwrites the same file (kills a dual-`00` double-apply bug in `db-schema-f3`).

## What is NOT done (cutover-gated — your call, needs live access)
1. **Regenerate the F3 snapshot** against live `packiot_analytics`
   (`CONFIRM=yes scripts/capture-f3-snapshot.sh`) → bakes in `oee_*` + #186. **Prod is
   NOT safe to seed until this runs** (parity-check enforces it).
2. `terraform plan/apply` from `origin/production` (NOT from
   `feat/prod-first-boot-hardening` — it would destroy WAF/certs).
3. Provision box `.env` (new `HIST_GW_*`/`HISTORIAN_*`/`HIST_AWS_*` — documented in
   `.env.example`).
4. **Merge `forward-port/prod-ready` → `production`** = the actual deploy trigger.
5. Post-deploy: DNS, first-client onboard/seed, `COGNITO_AUTH_ENABLED=true` flip.
6. Prod `DROP COLUMN users.operator_pw_hash` after prod edge-api carries #159.

Full ordered runbook: `docs/plans/prod-ready-forward-port.md` § CUTOVER RUNBOOK.

## Review it
Branch `forward-port/prod-ready` — open a PR at
`github.com/packiot/packiot-stack-alpha/pull/new/forward-port/prod-ready` (I did not
open one; merging it *is* the cutover, so that's your trigger).
