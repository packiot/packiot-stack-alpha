# `equipment_events_man.forced_creation_system=true` is NOT pollution

**Date:** 2026-08-27
**Verdict:** No cleanup warranted. The rows are genuine replicated operator downtimes. Do **not** delete or relocate them.

## The false premise

PR #940 (legacy-replicator split-target fix) noted that the twin's
`equipment_events_man` carried "163 forced twin `_man` rows vs legacy's `_man`
being 100% non-forced genuine manual events" and deferred a "reversible
remediation" to relocate them into `equipment_events`. Read at face value this
implied: *`forced_creation_system=true` ⇒ system-created ⇒ misfiled in the
manual table ⇒ should be moved out.*

A full investigation against the live `packiot_analytics` DB **and** the legacy
oracle proved that premise wrong.

## What the evidence actually showed

1. **`forced=true` is a replication artifact, not a "system-created" marker.**
   The shadow-mirror replicator hard-codes `forced_creation_system=true` in
   `manual_event_created.go:126` and `event_splitted.go:73` as a deliberate
   **bypass of the `piot_trig_equipment_events` dedup trigger** when replaying
   *genuine* legacy operator actions. It is stamped on real manual downtimes,
   not on machine-generated events.

2. **The whole twin `_man` table is replicator-authored.** All 91,566 rows are
   `forced=true`, zero `forced=false`. By contrast legacy `equipment_events_man`
   is ~97% `forced=false` genuine manual + ~3% `forced=true`. Same events,
   different flag semantics on the twin — the twin does not mirror legacy's flag
   composition, by design of the bypass.

3. **Zero misfiled split-segments under oracle-gated classification.** The
   correct discriminator for a *misfiled* row is: present in legacy
   `equipment_events` **and** absent from legacy `equipment_events_man`
   (legacy routes split segments to `equipment_events` per
   `edge-api/.../downtimes-dao.ts:195 ::split`; genuine manual → `_man`).
   Applied to the 980 scoped twin/sandbox rows (ent 3/4/2000003, Aug 14–27),
   **0 rows** qualify. They carry real operator text
   (*"Setup, troca de cliche e cor"*, *"Parada final de semana"*) — genuine
   downtimes legacy keeps in `_man`.

4. **The local oracle is frozen.** Legacy `packiot` (F1) is frozen at
   2026-08-13 20:08 for CPACK (the Aug-13 cutover incident). All 980 scoped
   rows are *after* the freeze, so legacy row-presence returns "absent" for
   reasons of **staleness, not provenance** — it cannot classify these rows.

## Why deleting would have been the bug

Relocating or deleting these rows would have **destroyed genuine operator
downtime data** and **diverged the twin from the legacy oracle** — the opposite
of the intended cleanup. Consumers of `_man` are display-only
(`v_events_2`, `v_report_downtimes`, `h_piot_*`); there are **no triggers** on
the table and the OEE pipeline reads `equipment_values`, so there is no
correctness pressure forcing a change either.

## If a real misfile ever needs remediation

The gated path (not needed today): point a `dblink()` classification at a
**live** legacy oracle (not the Aug-13-frozen local `packiot`), confirm the
misfiling mechanism against the actual handler, and move **only** the
oracle-classified misfiled set (snapshot → move → gated delete → reverse).
Under the current evidence that set is empty.

## Separate note — simulator fixtures (not real-tenant data)

ents **0** (sentinel) + **2** (Simulator Corp) hold ~90,586 `forced=true`
synthetic test rows (`"Manual via NR"`, `"Split-B via NR"`) authored by
`simulator/simulator.py`. These are test fixtures, not real-tenant pollution,
and are out of scope of any twin cleanup. Purge-as-test-data is a separate
optional hygiene decision, deliberately left untaken.

## The lesson

A boolean flag's *name* (`forced_creation_system`) is not its *contract*. Here
it meant "trigger-bypass on replay," not "system-created." Before treating rows
as garbage, confirm what the discriminating column actually means in the code
that writes it — and classify against the oracle, not against an assumption.
