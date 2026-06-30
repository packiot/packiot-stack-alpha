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

<!--
🤖 Generated with [Claude Code](https://claude.com/claude-code) — leave or remove this line at your discretion.
-->
