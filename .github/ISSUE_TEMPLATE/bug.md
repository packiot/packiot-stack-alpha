---
name: Bug report
about: Something broke in staging, production, or local dev
title: '[bug] '
labels: bug
assignees: ''
---

## What broke

<!-- One sentence. The observable symptom, not the suspected cause. -->


## Where

- [ ] Local dev (`make up`)
- [ ] Staging
- [ ] Production
- [ ] CI / GitHub Actions
- [ ] Documentation

**Service / file path:** 
**Tenant (if multi-tenant):** 
**Approximate time of first occurrence (UTC):** 

## Reproduction

<!-- Concrete steps. Logs > narrative. -->

```

```

## Expected vs actual

**Expected:** 
**Actual:** 

## Logs / metrics / screenshots

<details>
<summary>Relevant log lines / Grafana panel screenshots</summary>

```

```
</details>

## Suspected family

<!-- Optional. Helps prioritize. Refer to the zettel cluster in docs/INDEX.md. -->

- [ ] Bug-cascade pattern (multiple root causes per symptom)
- [ ] Silent-metric-coverage-gap (per-tenant label discipline)
- [ ] Stateful-config-loader (flow-manager / similar)
- [ ] Recover-validate-then-merge (recovered WIP that wasn't tested)
- [ ] Other / unknown
