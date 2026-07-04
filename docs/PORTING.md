# PORTING.md — the port-action pattern (repo law)

Every PR that ports legacy logic (PL/pgSQL, Node-RED, per-customer
objects) to the refactored stack follows these nine steps and ships
the checklist below in its PR body. The pattern is the product: the
ports are consumables, the methodology is the asset.

## The nine steps

1. **Capture verbatim, file-safe.** `pg_get_functiondef` / prosrc to a
   FILE (never chunked stdout — tokens split at seams; bug 251).
   Commit the capture under `docs/adr/reference/`.
2. **Generation-verify.** The name an orchestrator calls is not
   necessarily what works, and `_test` can be production. Call-time
   verify on prod (READ ONLY) which generation actually runs and
   returns rows. List dead generations for the contract wave.
3. **Decode semantics before code.** Identify: transaction boundaries
   (per-step commits are LOAD-BEARING), selector columns (which
   row-class does this serve? — status_type lesson), session state
   (SET LOCAL), self-re-enqueue/flag protocols, hardcoded tenants.
4. **Port with a written equivalence argument.** The file header
   enumerates every claim (X is vestigial, Y == Z by construction)
   and every DIVERGENCE with its bound. Divergences without bounds
   are bugs. Choose strategy by shape:
   - zero-parameter body → verbatim embed (+ bit-identical-at-default
     tenant rendering)
   - loops reducible to set operations → set-based with argument
   - state machines → pure decision layer + command layer, statement
     order preserved
5. **Extract per the ledgers.** Tenant ids/windows/exclusions →
   config or descriptor rows (no-hardcoded-ids); names from
   naming-ledger.md — assigned BEFORE the code exists.
6. **Guard tests.** Fidelity strings pin formulas/windows/keys;
   bans pin what must NOT appear (tenant literals, dead generations,
   legacy warmups). The contract test (Handles-style) must trip on
   every scope extension — that is its job.
7. **Deploy flag-gated**, SourceType-gated where a legacy writer still
   owns Flow 1 (sole-writer rule).
8. **Verify with evidence**: synthetic injects / seeded rows for state
   machines; differential run vs the legacy engine where inputs are
   shared (see PORT-PARITY harness); prod-read fidelity for report
   writers. Gate DDL with state probes (relkind), never exit codes.
9. **Record**: as-executed notes, memory, bake panel where the port
   has a divergence surface.

## PR checklist (copy into the PR body)

```
PORT CHECKLIST (PORTING.md)
- [ ] capture committed (file-safe): docs/adr/reference/...
- [ ] generation call-time-verified on prod; dead gens listed
- [ ] semantics decoded: tx boundaries / selectors / session state / flags
- [ ] equivalence argument in file header; divergences BOUNDED
- [ ] tenant ids & windows → config/descriptors; ledger names used
- [ ] guard tests: fidelity pins + bans
- [ ] flag-gated (+ SourceType gate if legacy writer coexists)
- [ ] verification evidence linked (inject / differential / fidelity)
- [ ] memory + as-executed notes updated
```

## Companion tooling

- `scripts/ssm-psql.sh` — stdin-safe SQL execution on staging
- PORT-PARITY harness (differential legacy-vs-Go diff) — see
  `services/port-parity/` once landed
- Golden fixtures + property tests ride the harness's snapshot format
