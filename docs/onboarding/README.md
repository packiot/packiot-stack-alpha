# Client Onboarding Runbook (ADR-0045)

**Audience:** Customer Success engineers onboarding a new factory client onto the
Packiot stack. **You do not need to write Go, edit YAML by hand across four
files, or touch the database directly.** You author *one* descriptor and drive
*one* tool — `onboard` — through five gated stages.

This runbook is the operational companion to
[ADR-0045](../adr/0045-client-onboarding-architecture.md) (the architecture) and
its build PRs: **P1** (the generator, `cmd/onboard-gen`), **P2** (the live-tee
capture tool, `cmd/onboard-capture`), and **P3** (this orchestrator,
`cmd/onboard`).

---

## The mental model

A client's raw PLC topics differ from the platform's **canonical** topic model in
ways that are partly *knowable* (a `C-PACK/` → `CPACK/` prefix fixup, a
`CurMachSpeed` → `MachSpeed` rename) and partly **unknowable** — most importantly
each machine's **count index**, the arbitrary PLC channel number embedded in
`…/ProdProcessedCount/<IDX>/Unit`. That index is *not derivable from any table*
(CPACK's `BREYER1` emits index `26` while its `id_equipment` is `340`); it can
only be **observed on a live tee**.

So onboarding has two kinds of work:

1. **Describe** the knowable facts once, in a descriptor. A generator turns them
   into every downstream artifact — *you never hand-edit the artifacts*.
2. **Capture** the unknowable facts (count indices) by watching the client's live
   data, and **confirm** them. **No tenant cuts over on inferred (guessed) data.**

The orchestrator makes that a checklist you cannot accidentally skip.

---

## The five stages

```
① DESCRIBE  ──▶ ② GENERATE ──▶ ③ CAPTURE ──▶ ④ VALIDATE ──▶ ⑤ CUT OVER
   author        emit 4          observe        readiness       print the
   the SSoT      artifacts       the live tee    gate            checklist
                                 → confirm       (all confirmed  (never
                                   indices        + builds +      executes)
                                                  Mode-A parity)
```

Every command records progress in a per-client manifest,
`<tenant>.onboard.json`, next to the descriptor. Run `onboard status
--descriptor …` any time to see where you are.

The build tool:

```bash
cd services/edge-transformer
go build -o /usr/local/bin/onboard ./cmd/onboard    # or `go run ./cmd/onboard <cmd> …`
```

---

### ① DESCRIBE — author (or scaffold) the descriptor

Start a brand-new client from a template:

```bash
onboard describe --descriptor docs/clients/acme.descriptor.yaml \
    --init --tenant ACME --enterprise 42 --prefix ACME/PLANT
```

This writes a commented starter descriptor. **Fill in the `equipment:` block**
(one row per line `tp_equipment: 3` and per member `tp_equipment: 1`) and any
`mapping:` quirks (prefix fixups, metric aliases). For each member, set
`count_index: {value: <best guess>, confidence: inferred}` — you will confirm the
real value in stage ③.

Then validate it:

```bash
onboard describe --descriptor docs/clients/acme.descriptor.yaml
```

The command **refuses an invalid descriptor** (that is the gate) and, on success,
reports how many indices are still inferred:

```
describe: OK — tenant=ACME enterprise=42, 12 equipment, 5 member(s) inferred.
  5 count index(es) still inferred — a CAPTURE will be required before cutover.
next: onboard generate
```

---

### ② GENERATE — emit the four artifacts

```bash
onboard generate --descriptor docs/clients/acme.descriptor.yaml --out gen/acme
```

Writes, to `gen/acme/`, the four artifacts you would otherwise hand-build:

| file | what it is |
|---|---|
| `acme-profile.yaml` | tenant conversion profile (prefix/alias/param/count-index) |
| `acme-register.sql` | `packml_register` INSERT (topic ↔ `id_equipment`), idempotent |
| `acme-agent.yaml` | sparkplug-agent `client.yaml` (register-derived tag map) |
| `acme-tee-node.json` | the Node-RED Tier-1 raw-forwarder flow |

Generation is always **draft/observe** here — everything is emitted so you can
deploy the agent in an *observe posture*. Cutover-readiness is stage ④'s job.

---

### ③ CAPTURE — observe the live tee, confirm the indices

Deploy the generated agent + import the tee snippet into the client's Node-RED,
with the agent running verbose (`AGENT_UNMAPPED_VERBOSE=true`) so its `/healthz`
enumerates every topic the tee sent that the map did not cover. Let it run long
enough to see every machine produce.

Then reconcile observed-vs-expected and **write the confirmed indices back into
the descriptor**:

```bash
onboard capture --descriptor docs/clients/acme.descriptor.yaml \
    --agent-url https://acme-agent:9102 --insecure \
    --accepted accepted.txt \
    --apply
```

(`accepted.txt` is the agent's mapped-metric set, e.g. from its SparkPlug NBIRTH:
`mosquitto_sub -h <broker> -t 'spBv1.0/ACME/NBIRTH/#' -C 1 | jq -r '.metrics[].name'`.
Offline, use `--healthz path/to/healthz.json` instead of `--agent-url`.)

The reconciler decides one of four verdicts per member:

| verdict | meaning | effect |
|---|---|---|
| `CONFIRMED` | the expected index was observed on the wire | eligible |
| `MISMATCH` | a **different** index is on the wire — the real one is captured | `--apply` rewrites it → confirmed |
| `MISSING` | opted-in but no count observed (dormant / not seen) | stays inferred — **blocks cutover** |
| `UNMAPPED` | an observed index maps to no member (orphan) | flagged — **blocks cutover** |

With `--apply`, the orchestrator rewrites the descriptor's `count_index` rows in
place (a **surgical, comment-preserving** edit — only the changed lines move), so
the next stages see confirmed data. Without `--apply` it prints a paste-back
fragment (dry-run). Scope a noisy plant with `--only L8`.

---

### ④ VALIDATE — the readiness gate

```bash
onboard validate --descriptor docs/clients/acme.descriptor.yaml \
    --agent-url https://acme-agent:9102 --insecure --accepted accepted.txt
```

Three gates, all must pass for **GREEN**:

1. **all count indices confirmed** — zero inferred (the ADR-0045 §2.4b rule).
2. **cutover-ready config builds** — the same refusal the generator enforces.
3. **Mode-A parity** (only when `--agent-url`/`--healthz` is supplied) — the
   descriptor reconciles cutover-ready against the live wire (no MISMATCH /
   MISSING / orphan).

```
validate: tenant=ACME
  [PASS] all count indices confirmed (0 inferred)
  [PASS] cutover-ready config builds
  [PASS] Mode-A capture parity (reconciles cutover-ready on the wire)

validate: GREEN — next: onboard cutover (prints the checklist; does not execute).
```

A RED gate names exactly what is missing. Go back to ③, capture the remaining
indices, re-validate.

---

### ⑤ CUT OVER — the checklist (never executed)

```bash
onboard cutover --descriptor docs/clients/acme.descriptor.yaml
```

This **prints an ordered, gated cutover checklist** and *executes nothing*.
Cutover is a deliberate, reviewed, **reversible** action — a gated PR that flips
`AGENT_TAGMAP_FROM_REGISTER` (+ `AGENT_PARAM_DECOMPOSITION` if used); flipping the
flag back OFF restores static behaviour byte-for-byte.

The command is **hard-gated**: it refuses unless the descriptor is all-confirmed,
the cutover config builds, **and** `onboard validate` has passed green. A stale
manifest cannot open the gate — readiness is re-derived live each time.

---

## The guided one-shot

`onboard run` walks describe → generate → (capture, if you pass observations) →
validate in one command, stopping before the human-gated cutover:

```bash
onboard run --descriptor docs/clients/acme.descriptor.yaml --out gen/acme \
    --agent-url https://acme-agent:9102 --insecure --accepted accepted.txt --apply
```

---

## CPACK — the worked example

CPACK is the reference tenant (`docs/clients/cpack.descriptor.yaml`, 62
equipment: 20 lines + 42 members). It shows the flow's whole point:

- **describe/generate** are pure config — the generated profile is proven
  byte-equivalent to the hand-built one (`clientdescriptor_test.go` golden).
- **capture** resolves the real story: CPACK L8's members send counts at indices
  `511/512/513` while the descriptor *guessed* `219/220/221` (a `MISMATCH` that
  the old silent-drop hid); `L8/GLUER` is an **orphan** (a machine not yet in the
  descriptor); `L8/TEXA` is **dormant** (`MISSING`). Run:

  ```bash
  cd services/edge-transformer
  go run ./cmd/onboard capture \
      --descriptor ../../docs/clients/cpack.descriptor.yaml \
      --healthz internal/agent/capture/testdata/healthz-cpack.json \
      --accepted internal/agent/capture/testdata/accepted-cpack.txt \
      --only L8
  ```

  (drop `--only L8` for the whole plant; add `--apply` to write the fixes back).

- CPACK carries 20 inferred members today, so **cutover is correctly refused**
  until those indices are captured — exactly the guard-rail this tool exists to
  enforce.

---

## Safety properties (why this is trustworthy)

- **Read-only against the world.** The tool reads files + one HTTP `GET /healthz`.
  It writes only the manifest, the generated artifacts, and — with `--apply` —
  the descriptor's captured indices. **No DB writes, no broker writes, no
  cutover.**
- **One source of truth.** A quirk lives in exactly one place (the descriptor);
  the four artifacts are regenerated, never drifting.
- **No cutover on inferred data**, enforced in code at the validate→cutover seam
  — not left to discipline.
