<!--
Thanks for opening a PR! Please fill out the relevant sections below.
Most sections can be deleted if not applicable — keep the PR focused.
-->

## Summary

<!-- 1-3 bullet points: what changed, why, what it unblocks. -->

-

## Type

<!-- Pick one or more. Delete the rest. -->

- [ ] `feat` — new functionality
- [ ] `fix` — bug fix
- [ ] `refactor` — internal restructure, no behavior change
- [ ] `chore` — repo hygiene (no code change to runtime behavior)
- [ ] `docs` — documentation only
- [ ] `ci` — CI/CD only
- [ ] `revert` — reverts a prior commit/PR

## Linked work

<!-- ADR, runbook, zettel, or issue this PR realizes/blocks/follows. -->

- ADR: 
- Issue:
- Follows PR: 

## Test plan

<!-- Concrete steps a reviewer (or future-you) can follow to verify.
     Per the recover-validate-then-merge zettel: if this changes runtime
     behavior, "ran it locally and it worked" is the minimum. -->

- [ ] 
- [ ] 

## Risk + rollback

<!-- What could break? How do you revert if it does? -->

**Risk:** 
**Rollback path:** 

## Per-tenant safety check (delete if not multi-tenant-affecting)

<!-- For changes to any service in services/ or anything touching
     edge.plc-normalized / oee / mirror-worker-go queues. -->

- [ ] New metrics have per-tenant labels (silent-metric-coverage-gap zettel)
- [ ] Queue/exchange names are tenant-namespaced where applicable
- [ ] AWS secret IDs follow the `packiot/<env>/...` convention

## Deploy ordering (delete if N/A)

<!-- For changes touching critical-path APIs across services. -->

- [ ] No deploy-ordering constraint, OR
- [ ] Deploy order documented: 1)  2)  3) 

## Durability review — ADR-0011 (delete N/A rows; do NOT delete the whole block)

<!--
Per ADR-0011 rule 6, every PR touching a Packiot-owned publisher, consumer,
or MQTT-receive path must address the rules explicitly. This is the fixed
reviewer checklist.

If none of the rows below apply, mark N/A on all of them. "Silent" is not
an option. See docs/consumer-idempotency-checklist.md for the depth on
rule 2.
-->

- [ ] **Rule 1 — publisher confirms**: N/A, or → PublishWithContext + wait for broker Ack; nack/timeout surfaces typed error + metric
- [ ] **Rule 2 — consumer idempotency**: N/A, or → business-key + `INSERT ON CONFLICT` / UPSERT / SELECT-then-write. See docs/consumer-idempotency-checklist.md.
      → Business key:
      → Duplicate-delivery test:
- [ ] **Rule 3 — MQTT receiver buffers to disk before ack** (once outbox lands, Phase 3): N/A / TODO / done
- [ ] **Rule 4 — /healthz surfaces degraded state**: N/A, or → new component registered with health.MultiSnapshotter with a Degraded() reason
- [ ] **Rule 5 — no silent loss**: every failure path logs ERROR/WARN + increments a metric (or is documented as intentional discard)

<!--
🤖 Generated with [Claude Code](https://claude.com/claude-code) — leave or remove this line at your discretion.
-->

## Porting (only if this PR ports legacy logic — see docs/PORTING.md)

- [ ] PORT CHECKLIST from docs/PORTING.md filled in this PR body
