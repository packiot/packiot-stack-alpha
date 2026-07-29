# Bispharma prod go-live — execution runbook (re-cut GO)

**Status:** EXECUTION runbook · **Date:** 2026-07-27 · **Task:** #37 ·
**Design of record:** [`production-buildout-roadmap.md`](../adr/reference/production-buildout-roadmap.md)
(branch `feat/task13-bispharma-descriptor-fill`) · **Prod branch:** `production` · **EC2:** `i-02d255a1c21fb1da3`

> USER said **GO** on the prod re-cut (2026-07-27). This runbook is the ordered
> execution sequence. It separates **what I can do now** (reversible, PR-only, no prod
> mutation) from **what needs USER input** (irreversible / external — secrets, certs,
> egress, `terraform apply`). Nothing customer-visible flips until the bake gate passes.
> Legacy EB prod (`edge.api4.packiot.com`) is out of scope and untouched throughout.

---

## 0. Built already (gated PRs, nothing applied) — from session 89

| Wave | PR | What |
|---|---|---|
| W1 compose parity | #627 | 8 migrated services into `compose.production.yml` (config only) |
| W1.4 F3 schema + gate | #628 | F3-schema-as-`public` + parity gate (`F3_MISSING=0` proven; caggs timescale-aware) |
| W1.5 knex reconcile | #631 | fake-baseline: prod `public` = F3 ∪ edge-api-operational (`CLOBBER=0`) |
| W2 ingest | #626 | mTLS :8883 front-door + r7g DB instance |
| W3 read plane | #629 | refdata + front4 re-point plan (refdata vhost bypasses Authentik; boot health-gate) |
| edge mTLS | #624 | edge-container mTLS |

**Boot order (health-gated):** `postgres → db-schema-f3 → db-knex-baseline → db-migrate → edge-api`.
**Still to build:** W1.6 dry-run boot (needs a deploy — rides the re-cut).

---

## 1. Execution sequence

```
S1  Re-cut production ← staging        (erase 568-commit gap)      [ME, reversible]
      ▼
S2  Merge gated PRs #624/#626/#627/#628/#629/#631                  [ME, PR-only]
      ▼
S3  Provide gated inputs  ─────────────────────────────────────── [USER — see §2]
    (egress /32 · bispharma mTLS cert · packiot/production/* secrets · users seed)
      ▼
S4  terraform apply (r7g DB split + SG 8883 + front-door)         [USER-gated apply]
      ▼
S5  Deploy production → self-hosted runner → compose up            [ME drives, USER go]
      ▼
S6  Boot gates green: F3_MISSING=0 · CLOBBER=0 · health-gate OK    [ME verify]
      ▼
S7  Dark-launch bispharma tee → agent (observe posture)            [ME + USER tee node]
      ▼
S8  BAKE window (real bispharma data, not customer-visible)        [GATE]
      ▼
S9  First client cutover  ← own sign-off                           [USER]
```

---

## 2. What I need from USER to execute (the gated checklist)

These are the only true blockers on my side — each is irreversible or a secret I cannot
fabricate. Everything else I proceed on.

- [ ] **Egress `/32`** — bispharma factory public IP for the ingest SG allow-rule.
- [ ] **bispharma mTLS client cert** — one `CN` (`bispharma-tee`); I generate the CSR, you
      approve issuance. (Two-tenant model → bisnago gets its own later.)
- [ ] **`packiot/production/*` secrets** — confirm/rotate: `db`, `app`, `hasura`,
      **`rabbitmq` (NEW — did not exist in dry-run shell)**, `authentik`. I scaffold the
      secret *names/refs*; you set the *values* in Secrets Manager.
- [ ] **Users seed** — 43 `bispharma.com.br` + 9 `packiot.com` under bispharma ent;
      13 `bisnago.ind.br` **split to bisnago ent** (per canonical-model §4). Firebase→Cognito
      JIT migration Lambda (#615) handles the auth swap; seed reads `id_user_firebase` +
      `user_email` (prod has no `email`/`cognito` columns).
- [ ] **`terraform apply` go** (S4) — r7g DB instance + SG 8883 + front-door. Plan/validate
      is done; `apply` is the first irreversible infra step.
- [ ] **Bispharma tee node** (S7) — the counterData→POST /v1/counters tee on the factory
      edge (like the CPACK/Incoplast tee nodes you added).

## 3. What I proceed on now (no further ask)

- S1 re-cut `production ← staging` (reversible; branch op).
- S2 land the gated PRs onto `production` (PR-only, no deploy).
- W1.6 dry-run boot compose block.
- CSR generation for the bispharma cert (you approve issuance).
- Secret-name scaffolding in compose + a `packiot/production/*` manifest for you to fill.

## 4. Risks carried from the roadmap (§0)

1. **front4 read-plane re-point** — can blank dashboards if F3 read surface incomplete first
   → refdata-on-F3 must be verified before the front4 flip. **bispharma is greenfield** → no
   parallel-run, so this risk is *lower* than for a live tenant, but still gate refdata first.
2. **DB sizing** — the local-container `t4g.medium` swaps under real load (staging proved it)
   → the r7g split (#626) is non-negotiable before real bispharma volume.
3. **Fresh-start F3 DDL correctness** — wrong schema = silently-wrong OEE. Mitigated by the
   `F3_MISSING=0` parity gate (#628) + `CLOBBER=0` knex reconcile (#631) — both must stay green.

---

## 5. Coupling to the OEE-mapping fix

The prod stack builds and bakes independently of the OEE-mapping fix
([`bispharma-oee-mapping-fix.md`](bispharma-oee-mapping-fix.md)). With the **provisional
p95-throughput speed inference** (fix §2b), rated speed is **no longer a hard go-live
blocker** — the bake self-calibrates an ideal speed, so S9 can show a real (self-calibrated)
OEE. The client's nameplate speeds + §3 semantics confirmations then *refine* it post-launch
(OEE will adjust down when nameplate lands — see the fix's semantic caveat).
