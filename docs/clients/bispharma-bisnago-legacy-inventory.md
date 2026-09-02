# Bispharma + Bisnago — legacy-production (tsp12 / packiot40) inventory

**Status:** Design input · **Date:** 2026-07-27 · **Task:** #54 onboarding ·
**Companion:** [`bispharma-bisnago-canonical-model.md`](bispharma-bisnago-canonical-model.md)
(Part B — the clean canonical model + translation layer built on these findings).

**Method.** Every fact below was read **SELECT-only** from legacy prod
`packiot40` (host tsp12), via SSM to App EC2 `i-06c9547a2c7091ab7`, each statement
wrapped `BEGIN TRANSACTION READ ONLY; … ROLLBACK;`. No mutation, no `pg_dump`.
Enterprise ids per the task brief: **bispharma = `id_enterprise` 4**, **bisnago =
`id_enterprise` 119**.

---

## 0. Headline — both tenants are GREENFIELD SHELLS in packiot40

Neither Bispharma (4) nor Bisnago (119) has *any* topology or production data in
the legacy prod DB. There is nothing to lift-and-shift; there is no messy legacy
topic set to migrate. This is the cleanest possible input for the "architect a
better stack" directive — the canonical model (Part B) is authored fresh, with
**zero legacy-register debt to reconcile**.

| Object | Bispharma (ent 4) | Bisnago (ent 119) |
|---|---|---|
| `enterprises` row | present, `active=t`, has `api_key` | present, `active=t`, has `api_key` |
| `sites` | **0** | **0** |
| `areas` | **0** | **0** |
| `equipments` (lines/sectors/machines) | **0 / 0 / 0** | **0 / 0 / 0** |
| `packml_register` (topics) | **0** | **0** |
| `equipment_values` (PLC time-series) | **0** | **0** |
| `scanned_boxes` | **0** | **0** |
| `production_orders` | **0** | **0** |
| `shifts` | **0** | **0** |
| `users` | **65** (see §2) | **0** |

---

## 1. Enterprise config (the only real rows that exist)

Both enterprise rows carry an identical operational profile — a strong signal
they are **one commercial group, two legal entities** (see §3, §4):

| Field | Bispharma (4) | Bisnago (119) |
|---|---|---|
| `nm_enterprise` | Bispharma | Bisnago |
| `active` | `t` | `t` |
| `api_key` | present (distinct per ent) | present (distinct per ent) |
| `timezone` | `America/Sao_Paulo` | `America/Sao_Paulo` |
| `week_begin` | `18000` (Mon 05:00) | `18000` |
| `day_begin` | `18000` | `18000` |
| `week_size` | `518400` (**6-day** week, 6×86400) | `518400` |
| `scrap_calc_type` | `1` | `1` |
| `language_packs` | pt-BR + en-US (byte-identical) | pt-BR + en-US (byte-identical) |

The 6-day `week_size` (not the usual 604800 = 7 days) and Mon-05:00 week start
are shared calendar facts to carry into shift config later — **not** required for
the first "does data flow + does OEE compute" validation.

---

## 2. Users — the auth-migration volume (Bispharma only)

Bispharma (ent 4) holds **65 users, all 65 with a Firebase UID** (`id_user_firebase
IS NOT NULL`), **58 active**, every one role `602`. Bisnago (ent 119) has **zero**
users. Email-domain breakdown (PII-safe — domains only, real UIDs/emails never
read out or committed):

| Domain | Count | Meaning |
|---|---|---|
| `bispharma.com.br` | 43 | Bispharma staff |
| **`bisnago.ind.br`** | **13** | **Bisnago staff — living under the Bispharma enterprise** |
| `packiot.com` | 9 | internal Packiot team |

> **The load-bearing user finding:** 13 `bisnago.ind.br` users sit under **ent 4**,
> not ent 119. The two enterprises share a user pool. Combined with the shared
> PubSub publisher (§3) and identical config (§1), this is the empirical basis for
> the one-group / two-tenant recommendation in Part B §4.

Auth-migration note: prod `users` has **no `id_user_cognito`** column and **no
`email`** column — the columns are `user_email` / `id_user_firebase` (Firebase
only). Any staging user seed reads `id_user_firebase` + `user_email`; the 65 exist
only under ent 4 today.

---

## 3. The Bisnago counter-id resolution — a COINCIDENTAL NEOPAC collision, NOT a mapping

The bisnago legacy Node-RED flow (PR #632) emits **numeric counter ids 670–683**
(14 counters, 2 per line, 7 active lines L71/L72/L73/L56/L57/L58/L60) into a GCP
PubSub topic `bispharma_bisnago_publisher`. It builds **no** topic strings; the
counter-id → equipment mapping was expected to live in "the legacy ent-119 cloud
DB." **It does not exist there.** Resolving 670–683 in packiot40:

| Where 670–683 actually resolve | Result |
|---|---|
| `packml_register.id_infeedcounter / id_outfeedcounter / id_rejectcounter` ∈ 670–683 | **0 rows** |
| `equipments.id_packed_counter / id_counter_status` ∈ 670–683 | **0 rows** |
| `areas.id_infeedcounter/…` ∈ 670–683 | **0 rows** |
| `equipments.id_equipment` ∈ 670–683 | rows exist — **but they are NEOPAC** |
| `equipment_values.id_equipment` ∈ 670–683 | **LIVE data, today** — under **`id_enterprise` 13 = NEOPAC** (+ a few under 113 "Desativados") |

The ids 671–683 map to **NEOPAC** (`id_enterprise` 13, `Europe/Zurich`, site 13 /
area 29) — machines named `NH`, `Offset`, `RHM`, `SS`, `TL103`, `TL112` — a Swiss
tube-printing plant, **actively ingesting today** (`max(ts_value)` = 2026-07-27).
This is a **pure id-space collision**: NEOPAC's `id_equipment` surrogates happen to
occupy the same integer range as Bisnago's legacy PLC counter ids. They are
unrelated.

**Consequences (both feed Part B):**

1. **There is no Bisnago counter→equipment mapping to recover from tsp12.** The
   legacy `bispharma_bisnago_publisher` stream was **never ingested into packiot40
   under ent 119** (ent 119 has zero `equipment_values`). Bisnago is a true
   greenfield build — its topology comes from the **7 flow line-labels + client +
   a live-tee capture**, not from the DB.
2. **Bisnago MUST get a FRESH surrogate id block on the new stack.** Reusing
   670–683 is unsafe: those ids are occupied by a live tenant (NEOPAC). Had the
   legacy publisher ever been pointed at packiot40 with these ids, it would have
   corrupted NEOPAC's counters — a latent footgun the clean rebuild removes.
3. **The "2 ids per line" meaning is unresolved by any table** — no DB row explains
   whether the pair is (a) two machines on the line or (b) processed + consumed on
   one machine. This stays **NEEDS-CLIENT / live-tee** in Part B.

---

## 4. Totalizer verdict — COUNTERS-ONLY absolute totalizers (Bisnago); no telemetry for either in tsp12

- **Bisnago:** the counter values are **DINT (32-bit) ABSOLUTE TOTALIZERS** — an
  ever-increasing running total, from which the legacy flow derived a per-poll
  `increment` (delta, clamped to 0 on reset). Source: the flow (PR #632) — no data
  in tsp12 to sample. **COUNTERS-ONLY: no `MachSpeed` sensor, no `StateCurrent`
  signal on any Bisnago PLC.** The NEOPAC collision counters (§3) corroborate the
  *magnitude* — `equipment_values` counts in the 0.7M–2.8M range — i.e. the
  absolute-totalizer shape the new-stack Calc already expects (`plc-sim` sims
  absolute totalizers; `feedback_bug #15`). **Directly compatible** — forward the
  absolute `value`; the new stack recomputes its own delta.
- **Bispharma:** zero `equipment_values` in tsp12 — telemetry shape is determined
  from its Node-RED flow by the sibling extraction (SparkPlug-string model per the
  onboarding scaffold), not from prod data.
- **OEE implication for Bisnago (counters-only):** Performance needs a **rated/ideal
  speed per line** (`equipments.production_speed` — NEEDS-CLIENT); Availability is
  **inferred from counter activity** → every machine is **`status_type != 4`**
  (this gates EventMint: do **not** mint per-sample OPEN events, or `running_time`
  overflows — `feedback_bug_eventmint`). Quality needs a defective/consumed source,
  which only exists if the 2nd counter-id per line is a consumed/defective count
  (§3.3 — NEEDS-CLIENT).

---

## 5. Customization surface — none in tsp12

Neither tenant uses PO control, shifts, barcode/`scanned_boxes`, samples, or
downtime config in packiot40 (all **0 rows**, §0). The bisnago flow additionally
has **zero back4 / HTTP customization calls** (PR #632) — no anti-corruption shim
needed. Onboarding customization is therefore authored fresh from client intake,
not reverse-engineered.

---

## 6. What the mining settles (inputs to Part B)

1. Both tenants are greenfield → the canonical model is authored, not migrated;
   **no flow-vs-register discrepancy to reconcile** (register is empty).
2. Bisnago's numeric-counter ids **do not resolve** in tsp12 → fresh surrogate ids,
   topology from flow-labels + client + live tee.
3. Bisnago is **counters-only, absolute totalizer, no speed/state** → the
   counters-only OEE path (rated speed + inferred availability + `status_type≠4`).
4. Shared user pool + shared publisher + identical config → **one group, two
   enterprises** (see Part B §4 for the one-tenant-vs-two decision).
</content>
</invoke>
