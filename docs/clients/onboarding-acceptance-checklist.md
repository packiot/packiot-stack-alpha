# New-stack customer onboarding — acceptance checklist (go / no-go)

**Purpose.** A repeatable, hardproof-only pass/fail gate for onboarding a manufacturing
customer onto the new stack (`packiot_analytics`, Cognito auth, medallion schemas). It turns
"looks onboarded" into "**provably** onboarded" — the difference that #253 exposed: a tenant
can have every row wired and still emit garbage OEE because its **PLC counters aren't
correctly mapped**.

**The bar is Bispharma.** Bispharma is the reference *proper* onboarding — it runs with **0
clamps firing** (no totalizer-spike clamp, no net>gross, no OEE-factor bound tripped). CPACK
is the counter-class hard case (real factory data, per-line register mapping still in
progress — see [cpack-unresolved-counter-registers.md](cpack-unresolved-counter-registers.md)).
**A customer is "cut over" only when it is Bispharma-clean, not merely wired.**

**Scope.** New stack only. Nothing here touches `packiot40` / legacy. Run every probe against
staging `packiot_analytics` (box `i-064bb36d1c454d861`, `docker exec timescaledb psql`) with
the tenant's `id_enterprise`.

---

## How to use

Each gate has an **intent**, a **hardproof** (a runnable probe), and a **pass condition**.
Replace `:ENT` with the tenant's `id_enterprise` and `:SOAK` with a window covering ≥ 2
producing shifts. **All eight gates must be green.** A red Gate 5 is the most common and most
dangerous failure — it produces *plausible-looking* dashboards with wrong numbers.

Result classes:
- ✅ **Bispharma-clean** — all gates green, 0 clamps firing → **GO** (cut over).
- 🟡 **Wired but dirty** — Gates 1–4,6–8 green, Gate 5 red → **NO-GO**. Needs per-line
  register mapping (the CPACK path) before cutover. Data is live but not trustworthy.
- 🔴 **Not wired** — any of Gates 1–4 red → **NO-GO**. Onboarding incomplete.

---

## Gate 1 — Identity & tenant (auth plane)

**Intent.** The tenant exists, has an API key, and its users authenticate through Cognito and
actually receive data (no silent data-plane 401 — the failure mode of #162/#166).

```sql
-- 1a. enterprise + api_key present
SELECT id_enterprise, nm_enterprise, (api_key IS NOT NULL) AS has_key, active
FROM core.enterprises WHERE id_enterprise = :ENT;

-- 1b. every active CUSTOMER user is Cognito-linked. Split internal/service accounts out:
--     operator/service/admin accounts (internal_user = true) self-heal id_user_cognito on
--     first login (read-api/edge-api single-row self-heal), so unlinked-internal is benign.
--     An unlinked NON-internal customer user is the real Gate-1 failure — they 401 on the
--     data-plane until linked. (Do NOT manually force-link: a dup-email across enterprises
--     will re-trigger the multi-row self-heal bug — let login self-heal, single-row.)
SELECT count(*) FILTER (WHERE NOT COALESCE(internal_user,false)) AS unlinked_customer_users,
       count(*) FILTER (WHERE COALESCE(internal_user,false))     AS unlinked_service_accts
FROM identity.users
WHERE id_enterprise = :ENT AND active AND id_user_cognito IS NULL;

-- 1c. the authz view returns rows for the tenant's users (front4 data-plane will 401 if 0)
SELECT count(*) AS authz_rows
FROM serving.v_entities_per_user_role WHERE id_enterprise = :ENT;
```

**Pass:** `has_key=true`, `active=true`; `unlinked_customer_users = 0` (service accounts may
be unlinked — they self-heal on login); `authz_rows > 0`. Then confirm a real front4/operator
login lands data (no 401 on `/v1/query`).

---

## Gate 2 — Hierarchy (dimension plane)

**Intent.** enterprise → sites → areas → equipment fully populated, with `tp_equipment`,
`lead_machine`, `id_unit` set, and **no same-named areas that the UI can't disambiguate**
(the operator LINHAS bug, #161/#201).

```sql
-- 2a. hierarchy counts
SELECT
  (SELECT count(*) FROM core.sites      WHERE id_enterprise=:ENT AND active) AS sites,
  (SELECT count(*) FROM core.areas      WHERE id_enterprise=:ENT AND active) AS areas,
  (SELECT count(*) FROM core.equipments WHERE id_enterprise=:ENT AND active) AS equipment;

-- 2b. every PRODUCING tp=3 line must have a lead_machine (the machine that emits its
--     downtimes). A line with NO lead_machine AND no production is a dormant/undefined
--     skeleton, NOT a fault — the reference tenant (Bispharma) has 8 such dormant lines
--     and is still clean. So scope the check to lines that actually produced in the window;
--     0 rows = pass. (There is no id_unit column on the new stack — the legacy id_unit
--     concept is not modeled in core.equipments.)
SELECT eq.id_equipment, eq.nm_equipment
FROM core.equipments eq
WHERE eq.id_enterprise=:ENT AND eq.tp_equipment=3 AND eq.active AND eq.lead_machine IS NULL
  AND EXISTS (SELECT 1 FROM gold.equipment_oee_shift s
              WHERE s.id_equipment=eq.id_equipment
                AND s.ts_value > now() - :SOAK::interval AND s.gross > 0);

-- 2c. same-named AREAS across different sites (the #161/#201 duplicate-LINHAS bug — the
--     UI must disambiguate by site suffix). Area names live on core.areas.nm_area, NOT on
--     equipments.
SELECT nm_area, count(DISTINCT id_site) AS sites_sharing_name
FROM core.areas WHERE id_enterprise=:ENT AND active
GROUP BY nm_area HAVING count(DISTINCT id_site) > 1;
```

**Pass:** counts match the intake sheet; 2b returns 0 rows (every *producing* line has a
lead_machine — dormant lines with no production may be NULL); 2c either returns 0 rows OR the
front4/operator selector is confirmed to show the site suffix.

---

## Gate 3 — Shifts (calendar plane)

**Intent.** Shifts are defined and expanded to `shift_hours` (area-first, site-fallback), so
OEE has a denominator. `begin_time/end_time` are integer seconds from `week_begin`, NOT clock
times — a common intake mistake.

```sql
SELECT
  (SELECT count(*) FROM core.shifts      WHERE id_enterprise=:ENT) AS shifts,
  (SELECT count(*) FROM core.shift_hours sh JOIN core.shifts s USING (id_shift)
     WHERE s.id_enterprise=:ENT) AS shift_hours;
-- sanity: begin/end within a week in seconds (0..604800-ish, week_begin may be negative)
SELECT min(begin_time), max(end_time) FROM core.shift_hours sh
JOIN core.shifts s USING (id_shift) WHERE s.id_enterprise=:ENT;
```

**Pass:** `shifts > 0`, `shift_hours > 0` (≈ shifts × active weekdays); begin/end are integer
second offsets, not clock values like 800/1730.

---

## Gate 4 — Topic routing (packml_register)

**Intent.** Every SparkPlug topic the edge emits maps to an `id_equipment`, is `active=true`,
and **no count-index is left UNRESOLVED**. This is where the CPACK register gap lives.

```sql
-- 4a. active routes exist and resolve to equipment
SELECT count(*) AS routes,
       count(*) FILTER (WHERE active) AS active_routes,
       count(*) FILTER (WHERE id_equipment IS NULL) AS unrouted
FROM core.topic_routing WHERE id_enterprise = :ENT;   -- packml_register (renamed)

-- 4b. tp=3 lines: counter roles resolved. Two models coexist on the new stack, and a tenant
--     may use either:
--       (i)  AREA-level roles: core.areas.{id_infeedcounter,id_outfeedcounter,id_rejectscounter}
--            (note the plural 'rejects'). This is where a reject role lives IF used.
--       (ii) LINE-level count-indices: core.topic_routing.{id_infeedcounter,id_outfeedcounter}
--            (no reject column here).
--     Bispharma uses NEITHER — its lines carry a lead_machine (2b) and scrap is co-located
--     (ProdDefectiveCount) / flow-derived (***TRIG_CS), resolved by the decoder's name+TRIG
--     convention. So "roles all NULL" is valid when the co-located convention is in use.
SELECT e.id_equipment, e.nm_equipment, e.lead_machine,
       a.id_infeedcounter AS area_infeed, a.id_outfeedcounter AS area_outfeed,
       a.id_rejectscounter AS area_reject
FROM core.equipments e
JOIN core.areas a ON a.id_area = e.id_area
WHERE e.id_enterprise=:ENT AND e.tp_equipment=3 AND e.active;
```

**Pass:** `unrouted = 0`, `active_routes > 0`; every tp=3 line either has infeed/outfeed
count-indices set **or** its scrap is co-located and resolved by the decoder's `Prod*Count` +
`***TRIG` convention (document which model the tenant uses — see the CPACK reject-counter
analysis for the two-mechanism explanation). No `UNRESOLVED` register comment remains in the
tenant's PLC descriptor.

---

## Gate 5 — Counters clean (THE Bispharma bar — 0 clamps)

**Intent.** Over a real producing window, the physics holds: `net ≤ gross`, scrap ≥ 0, no
totalizer spike, and every OEE factor ∈ [0,1]. **This is the gate that separates "wired" from
"cut over."** A red result here means the PLC register mapping is wrong even though everything
upstream looks fine.

```sql
-- 5a. net>gross (negative scrap) at shift grain — MUST be 0
SELECT count(*) AS neg_scrap_shifts
FROM gold.equipment_oee_shift r JOIN core.equipments e USING (id_equipment)
WHERE e.id_enterprise=:ENT AND r.ts_value > now() - :SOAK::interval
  AND r.net > r.gross;

-- 5b. totalizer spike: per-line gross wildly above its own PRODUCING-shift median
--     (mis-mapped / unbound register). Median is taken over gross>0 shifts only —
--     idle padding (many zero-gross shifts) would otherwise sink the median to 0 and
--     hide the spike. (percentile_cont is an ordered-set aggregate: use GROUP BY + join,
--     NOT a window — `OVER` is rejected for it.)
WITH med AS (
  SELECT r.id_equipment,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY r.gross)
           FILTER (WHERE r.gross > 0) AS med_gross
  FROM gold.equipment_oee_shift r JOIN core.equipments e USING (id_equipment)
  WHERE e.id_enterprise=:ENT AND e.tp_equipment=3 AND r.ts_value > now() - :SOAK::interval
  GROUP BY r.id_equipment
)
SELECT r.id_equipment, count(*) AS spike_shifts,
       max(r.gross) AS max_gross, max(m.med_gross)::bigint AS producing_median
FROM gold.equipment_oee_shift r JOIN core.equipments e USING (id_equipment)
JOIN med m USING (id_equipment)
WHERE e.id_enterprise=:ENT AND e.tp_equipment=3 AND r.ts_value > now() - :SOAK::interval
  AND m.med_gross > 0 AND r.gross > m.med_gross * 10
GROUP BY r.id_equipment ORDER BY spike_shifts DESC;

-- 5c. OEE factors in range; OEE <= 1
SELECT count(*) FILTER (WHERE oee_a < 0 OR oee_a > 1) AS bad_a,
       count(*) FILTER (WHERE oee_p < 0 OR oee_p > 1) AS bad_p,
       count(*) FILTER (WHERE oee_q < 0 OR oee_q > 1) AS bad_q,
       count(*) FILTER (WHERE oee   < 0 OR oee   > 1) AS bad_oee
FROM gold.equipment_oee_shift r JOIN core.equipments e USING (id_equipment)
WHERE e.id_enterprise=:ENT AND r.ts_value > now() - :SOAK::interval;

-- 5d. structural Q=1 lines (single-meter) — must be LABELLED "no scrap data", not "100%"
SELECT e.id_equipment, e.cd_equipment
FROM gold.equipment_oee_shift r JOIN core.equipments e USING (id_equipment)
WHERE e.id_enterprise=:ENT AND e.tp_equipment=3 AND r.ts_value > now() - :SOAK::interval
GROUP BY 1,2 HAVING sum(r.scrap)=0 AND bool_and(r.net = r.gross);
```

**Pass:** `neg_scrap_shifts = 0`; `spike_shifts` empty (or every spike explained by a real
production event, cross-checked against the oracle/expected); `bad_* = 0`; and any 5d
single-meter line is confirmed to render "no scrap data" in front4/Superset, not a misleading
"100% Quality". **Also cross-check the log:** 0 totalizer-spike clamp fires and 0
`--identity-sentinel` overflow warnings over the soak.

> Bispharma passes 5a–5d clean. CPACK currently fails 5b on L5 (gross spike, unbound
> registers) → 🟡 wired-but-dirty until its capture completes.

---

## Gate 6 — Barcode / scanned boxes (if the tenant scans)

**Intent.** The Bronze→Gold box ledger is gapless, idempotent, and tenant-fenced.

```sql
-- gapless label_seq per PO (0 gaps = pass)
SELECT id_production_order,
       max(label_seq) - count(*) AS seq_gap,   -- 0 when 1..N contiguous
       count(DISTINCT scan_uuid) AS distinct_scans
FROM bronze.box_scans WHERE id_enterprise=:ENT
GROUP BY 1 HAVING max(label_seq) - count(*) <> 0;
```

Plus the live-API hardproof (run once against `edge-api`): POST `/api/scanned-boxes` →
gapless `label_seq`, replay same `scanUuid` → 200 `replayed:true` (no new row), validate wrong
seq → 409 `label_seq_gap`, cross-tenant PO → 403 `tenant_mismatch`, and
`list-scanned-boxes` returns enriched totals. **Pass:** query returns 0 rows (no gaps) and all
five API behaviors hold. (Skip if the tenant does not use barcode.)

---

## Gate 7 — Historian (hot ∪ cold)

**Intent.** Historical data is loaded and the time-range selector reaches it, tenant-isolated.

```sql
-- hot side present for the tenant
SELECT count(*) AS hot_rows, max(ts_value) AS latest
FROM silver.equipment_values ev JOIN core.equipments e USING (id_equipment)
WHERE e.id_enterprise=:ENT AND ev.ts_value > now() - interval '1 day';
```

**Pass:** hot rows present with a fresh `latest`; and the gateway `ev_all` returns this
tenant's cold history under its `id_enterprise` RLS literal (prove one cold year via
read-api `/v1/historian/production-series`). Isolation: another tenant's key sees 0 of these
rows.

---

## Gate 8 — Freshness & rollup health

**Intent.** OEE is actually being computed and isn't silently stale — the #196 failure mode
(a real-time cagg with a frozen watermark → rollup re-aggregates all raw → 300s timeout →
stale OEE). Every cagg must have a refresh policy (#206).

```sql
-- 8a. OEE freshness: latest computed shift row is recent
SELECT max(computed_at) AS last_computed, now() - max(computed_at) AS lag
FROM gold.equipment_oee_shift r JOIN core.equipments e USING (id_equipment)
WHERE e.id_enterprise=:ENT;

-- 8b. recalc backlog not piling up. EXCLUDE child meters (id_parentequipment IS NOT NULL):
--     they are leaf physical meters that never compute their own OEE, so a rollup asymmetry
--     leaves them transiently flagged — counting them inflates the backlog with phantom rows
--     that no client ever sees (proven: 0 ever-computed rows for child meters). The honest
--     backlog is the flag count on OEE-computing equipment (lines + standalone machines) only.
SELECT count(*) AS real_recalc_backlog
FROM gold.equipment_oee_shift r JOIN core.equipments e USING (id_equipment)
WHERE e.id_enterprise=:ENT AND r.recalc_needed AND e.id_parentequipment IS NULL;
```

**Pass:** `lag` within one shift; `recalc_backlog` bounded (not monotonically growing).
Confirm the tenant's caggs each have an attached refresh policy (no frozen watermark).

---

## Sign-off

| Gate | Green? | Evidence (query result / run link) |
|------|:------:|------------------------------------|
| 1 Identity & tenant | ☐ | |
| 2 Hierarchy | ☐ | |
| 3 Shifts | ☐ | |
| 4 Topic routing | ☐ | |
| 5 **Counters clean (0 clamps)** | ☐ | |
| 6 Barcode (if used) | ☐ | |
| 7 Historian | ☐ | |
| 8 Freshness & rollup | ☐ | |

**Verdict:** ✅ Bispharma-clean (GO) · 🟡 wired-but-dirty (NO-GO, needs register work) ·
🔴 not wired (NO-GO).

At scale (828 legacy customers, #225), this checklist is the **per-customer definition of
done** — a customer is not "migrated" until it signs off ✅, the same way Bispharma does.

---

### Related
- [cpack-unresolved-counter-registers.md](cpack-unresolved-counter-registers.md) — the Gate-5 register-capture target list for CPACK.
- `docs/clients/cpack-reject-counter-role-analysis.md` — the two co-located scrap mechanisms (why `id_rejectcounter` stays NULL for CPACK).
- `docs/clients/cpack-legacy-oracle-line-meters.md` — the differential-oracle method to prove a line meter.
- `docs/clients/bispharma-staging-validation.md` — the reference clean onboarding.
- Task #225 — packiot40 → new-stack cutover (this checklist is its per-tenant gate).
