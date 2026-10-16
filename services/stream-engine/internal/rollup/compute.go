// compute.go — po-runtime-compute (ledger name), ported from prod's
// piot_get_equipment_production_order_runtime_test ('_test' IS
// production — the plain generation is commented out in the
// dispatcher). Per-runtime-row two-phase pass, set-based.
//
// EQUIVALENCE ARGUMENT (each claim attackable):
//   - Phase A (value sums → gross/net/oee_q/speed): prod's aggregate
//     SELECT INTO always sets FOUND → ALWAYS updates (zero-fills
//     no-data rows, clears recalc_needed). Ported as eligible-set
//     LEFT JOIN + COALESCE — the exact lesson the harness taught on
//     recalc (bug class handled by design this time).
//   - Phase B (event overlap sums → running/stopped): prod's SELECT
//     has GROUP BY — zero groups when no overlapping events → FOUND
//     FALSE → update SKIPPED. Ported as INNER join: rows without
//     events keep their previous running/stopped. GENUINELY
//     CONDITIONAL — do not "fix" into a left join.
//   - Overlap math verbatim: epoch(least(coalesce(ee.ts_end,now()),
//     coalesce(upper,now())) - greatest(ts_event, lower)); running =
//     status 6; stopped = status IN (5,10,11).
//   - ideal_production_speed: prod computes it but every USE is
//     commented out — dead computation, not ported (documented).
//   - SET LOCAL TIME ZONE: same bounded divergence class as recalc —
//     only the now()-'1 month' boundary is tz-sensitive (≤1h edge
//     under DST); consistent-boundary behavior chosen.
//   - Tails verbatim: re-flag open ranges (upper IS NULL) + ranges
//     that ended within 48h.
//   - Ordering: prod's dispatcher runs compute THEN recalc each pass
//     with per-step fail-soft commits — preserved by LoopRefresh
//     (one job, ordered steps, drop-per-step).
//
// GUARDRAIL STATEMENT: updates production_orders_runtime metric
// columns + recalc_needed by (id_equipment, lower(runtime_timerange));
// reads equipment_values + equipment_events. No range writes — the
// EXCLUDE constraint is not in play.
package rollup

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// Phase A: value sums — ALWAYS updates eligible rows (see argument).
//
// SPLIT-INSTRUMENTATION (line-metered clients, e.g. ent5 Bispharma): a PO runs on
// a tp=3 LINE, but the line's counters are emitted by a MEMBER machine
// (equipments.gross_machine names it; NULL for self-metered equipment). Resolve
// the counter source as COALESCE(gross_machine, id_equipment) so a line-PO reads
// its member's counters instead of the (empty) line row. This MIRRORS
// line_lead.go's gross_id resolution, but at the PO-runtime grain and with a
// DIFFERENT fallback base: id_equipment, NOT lead_machine. This pass is
// PO-equipment-centric — a self-metered line (gross_machine NULL, lead_machine
// SET, incl. every CPACK line) must keep reading its OWN rows, so the COALESCE
// must never fall through to lead_machine. It is a byte-identical NO-OP wherever
// gross_machine IS NULL (all tp=1 machines + all self-metered lines).
const computeValuesSQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi,
	           eq.gross_machine,
	           COALESCE(eq.gross_machine, e.id_equipment) AS gross_src,
	           -- line-lead line in an opted-in enterprise: its counters are written by
	           -- computeLineLeadValuesSQL (lead-sourced, per-minute reconciled) — leave them.
	           (eq.tp_equipment = 3 AND COALESCE(eq.lead_machine, 0) > 0 AND %[6]s) AS line_lead
	      FROM %[4]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now())
	       AND e.recalc_needed
	), sums AS (
	    -- Per-PO LATERAL with OFFSET 0 (the line_lead.go #259 lesson): joining the
	    -- equipment_values hypertable on a non-constant id list keeps the planner from
	    -- pushing id_equipment + ts into each chunk, so every tick scanned a month of
	    -- raw rows (mean 23 s/tick, 11 pct of all DB time on 2026-09-27). As a
	    -- correlated scan each id is a runtime constant → an index range scan per PO
	    -- (same sums, 40.5 s → 1.0 s measured). n > 0 keeps the inner-join semantics.
	    SELECT el.id_equipment, el.lo, s.gross, s.net, s.speed
	      FROM eligible el
	      CROSS JOIN LATERAL (
	          SELECT sum(ca.gross_production_incr) AS gross,
	                 sum(ca.net_production_incr)   AS net,
	                 avg(ca.speed)                 AS speed,
	                 count(*)                      AS n
	            FROM %[3]s.equipment_values ca
	           WHERE ca.id_equipment = el.gross_src
	             AND ca.ts_value >= now() - $1::interval
	             AND ca.ts_value >= el.lo AND ca.ts_value < el.hi
	          OFFSET 0
	      ) s
	     WHERE s.n > 0
	)
	SELECT e.id_production_order_runtime AS pk, e.xmin::text AS xm, el.line_lead,
	       COALESCE(s.gross, 0)::double precision AS gross_production,
	       -- gross-only reconciliation (line_lead's "gross-only ⇒ net=gross"): a
	       -- split-instrumentation member emits the input counter only (no net), so
	       -- net falls back to gross (quality 1.0). GATED on gross_machine IS NOT NULL
	       -- so a self-metered PO with a genuine net=0 (e.g. an all-scrap run) is
	       -- left untouched — the reconciliation reaches ONLY line-metered lines.
	       CASE WHEN el.gross_machine IS NOT NULL AND COALESCE(s.net, 0) = 0
	            THEN COALESCE(s.gross, 0) ELSE COALESCE(s.net, 0) END::double precision AS net_production,
	       GREATEST(COALESCE(
	            (CASE WHEN el.gross_machine IS NOT NULL AND COALESCE(s.net, 0) = 0
	                  THEN COALESCE(s.gross, 0) ELSE COALESCE(s.net, 0) END)
	            / NULLIF(s.gross, 0), 0), 0)::double precision AS oee_q, -- uncapped since 2026-09-29
	       COALESCE(s.speed, 0)::double precision AS speed
	  FROM eligible el
	  LEFT JOIN sums s ON s.id_equipment = el.id_equipment AND s.lo = el.lo
	  JOIN %[4]s.production_orders_runtime e
	    ON e.id_equipment = el.id_equipment
	   AND lower(e.runtime_timerange) = el.lo`

// Phase A apply: line-lead rows keep the counters Phase A2 just wrote in this
// transaction (WHEN r.line_lead THEN e.net_production), every eligible row gets
// speed and recalc_needed    = false.
const applyValuesSQL = `
	UPDATE %[4]s.production_orders_runtime e SET
	       gross_production = CASE WHEN r.line_lead THEN e.gross_production ELSE r.gross_production END,
	       net_production   = CASE WHEN r.line_lead THEN e.net_production ELSE r.net_production END,
	       oee_q            = CASE WHEN r.line_lead THEN e.oee_q ELSE r.oee_q END,
	       speed            = r.speed,
	       recalc_needed    = false
	  FROM jsonb_to_recordset($1::jsonb) AS r(pk bigint, line_lead boolean, gross_production double precision,
	       net_production double precision, oee_q double precision, speed double precision)
	 WHERE e.id_production_order_runtime = r.pk
	   AND r.pk = ANY($2::bigint[])`

// Phase A2: LINE-LEAD PO counters (2026-09-25). A PO on a line-lead line used to read the
// line's OWN counters — for CPACK lines those are often gross-only (L4/L5: net 0 ⇒ the operator
// showed everything as SCRAP), net-only (CER400/SLEEVE: gross 0 ⇒ negative scrap) or absent
// (L3/L8: 0 production), while the hour/shift grains of the SAME line (line_lead.go) read the
// LEAD machine with the counter-role reconciliation. Here the PO grain does the same:
// gross/net/scrap from gross_machine/net_machine/scrap_machine, reconciled like line_lead.go,
// summed over the runtime. MUST run before Phase A (reads recalc_needed).
//
// RECONCILE GRAIN = the HOUR, like the hour and shift grains (2026-09-29). The minutes
// are first cut to the PO's runtime (a PO that starts mid-hour gets only its own
// minutes), then grouped per clock hour and reconciled per hour. It used to reconcile
// per MINUTE: a minute in which the infeed counted but the outfeed did not (units in
// transit, an outfeed that reports every few minutes) read as "net meter missing", so
// the identity fill set net = gross for that minute, while the next minute's outfeed
// count was taken as measured — the same units counted twice. The per-minute
// net <= gross clamp hid most of it; with the clamp gone (store raw, 2026-09-29) a
// recompute read L3/L4/L6 PO net 5-13 pct above the line's own hourly net. A meter is
// "missing" only when it is silent for the whole bucket the grains agree on: the hour.
// $1 = window, $2 = line-lead enterprises.
const computeLineLeadValuesSQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi,
	           eq.lead_machine AS lead_id,
	           COALESCE(eq.gross_machine, eq.lead_machine) AS gross_id,
	           COALESCE(eq.net_machine, eq.lead_machine) AS net_id,
	           eq.gross_counter AS gross_ctr,
	           eq.net_counter AS net_ctr,
	           eq.scrap_machine AS scrap_id,
	           -- false ⇒ report-by-exception totalizers: no identity fill (line_lead.go).
	           COALESCE(eq.fill_missing_meter, true) AS fill_missing
	      FROM %[4]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now())
	       AND e.recalc_needed
	       AND eq.tp_equipment = 3 AND COALESCE(eq.lead_machine, 0) > 0
	       AND %[6]s
	), bucket_counts AS (
	    -- Per-PO, per-source LATERALs with OFFSET 0 (the line_lead.go #259 lesson): the 1min
	    -- cagg is a REAL-TIME view; joining it on a non-constant id list keeps the planner from
	    -- pushing id_equipment into its raw branch (a 16-PO run did not finish in 240 s). As
	    -- correlated per-source scans each id is a runtime constant → index range scans.
	    SELECT el.id_equipment, el.lo, el.fill_missing, date_trunc('hour', x.ts_value) AS b,
	           sum(x.g) AS gross, sum(x.n) AS net, sum(x.s) AS scrap
	      FROM eligible el
	      CROSS JOIN LATERAL (
	          SELECT cg.ts_value, CASE WHEN el.gross_ctr = 'processed' THEN cg.net_production_incr ELSE cg.gross_production_incr END AS g, NULL::double precision AS n, NULL::double precision AS s
	            FROM %[3]s.equipment_categorical_1min cg
	           WHERE cg.id_equipment = el.gross_id
	             AND cg.ts_value >= date_trunc('minute', el.lo) AND cg.ts_value < el.hi
	          UNION ALL
	          SELECT cn.ts_value, NULL, CASE WHEN el.net_ctr = 'consumed' THEN cn.gross_production_incr ELSE cn.net_production_incr END, NULL
	            FROM %[3]s.equipment_categorical_1min cn
	           WHERE cn.id_equipment = el.net_id
	             AND cn.ts_value >= date_trunc('minute', el.lo) AND cn.ts_value < el.hi
	          UNION ALL
	          SELECT cs.ts_value, NULL, NULL, cs.scrap_incr
	            FROM %[3]s.equipment_categorical_1min cs
	           WHERE cs.id_equipment = el.scrap_id
	             AND cs.ts_value >= date_trunc('minute', el.lo) AND cs.ts_value < el.hi
	          OFFSET 0
	      ) x
	     GROUP BY el.id_equipment, el.lo, el.fill_missing, date_trunc('hour', x.ts_value)
	), reconciled AS MATERIALIZED (
	    SELECT id_equipment, lo,
	           CASE WHEN COALESCE(gross,0) > 0 THEN COALESCE(gross,0)
	                WHEN NOT fill_missing THEN 0
	                WHEN COALESCE(net,0) > 0 AND COALESCE(scrap,0) > 0 THEN COALESCE(net,0) + COALESCE(scrap,0)
	                WHEN COALESCE(net,0) > 0 THEN COALESCE(net,0)
	                ELSE 0 END AS eff_gross,
	           CASE WHEN COALESCE(net,0) > 0 THEN COALESCE(net,0)
	                WHEN NOT fill_missing THEN 0
	                WHEN COALESCE(gross,0) > 0 AND COALESCE(scrap,0) > 0 THEN COALESCE(gross,0) - COALESCE(scrap,0)
	                WHEN COALESCE(gross,0) > 0 THEN COALESCE(gross,0)
	                ELSE 0 END AS eff_net
	      FROM bucket_counts
	), totals AS MATERIALIZED (
	    SELECT el.id_equipment, el.lo,
	           COALESCE(sum(r.eff_gross), 0) AS gross,
	           COALESCE(sum(r.eff_net), 0) AS net  -- no net<=gross clamp (2026-09-29): transit is real
	      FROM eligible el
	      LEFT JOIN reconciled r ON r.id_equipment = el.id_equipment AND r.lo = el.lo
	     GROUP BY el.id_equipment, el.lo
	)
	SELECT e.id_production_order_runtime AS pk, e.xmin::text AS xm,
	       t.gross::double precision AS gross_production,
	       t.net::double precision   AS net_production,
	       GREATEST(COALESCE(t.net / NULLIF(t.gross, 0), 0), 0)::double precision AS oee_q
	  FROM totals t
	  JOIN %[4]s.production_orders_runtime e
	    ON e.id_equipment = t.id_equipment
	   AND lower(e.runtime_timerange) = t.lo`

const applyLineLeadValuesSQL = `
	UPDATE %[4]s.production_orders_runtime e SET
	       gross_production = r.gross_production,
	       net_production   = r.net_production,
	       oee_q            = r.oee_q
	  FROM jsonb_to_recordset($1::jsonb) AS r(pk bigint, gross_production double precision,
	       net_production double precision, oee_q double precision)
	 WHERE e.id_production_order_runtime = r.pk
	   AND r.pk = ANY($2::bigint[])`

// Phase B: event overlap sums — CONDITIONAL (inner join; prod's
// GROUP BY → FOUND false when no overlapping events).
// ev_src mirrors Phase A's gross_src: for a split-instrumented line-PO the
// availability events (the count-silence-derived stops, ADR-0010) land on the
// gross_machine MEMBER, not the empty line row — so read them from there. Reading
// a SINGLE member (not the whole line's interleaved member streams) also sidesteps
// the double-count the LEAST clamp below guards against. NO-OP where gross_machine
// IS NULL (self-metered lines read their own events, as before).
const computeEventsSQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, e.runtime_timerange,
	           lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi,
	           COALESCE(eq.gross_machine, e.id_equipment) AS ev_src
	      FROM %[4]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now())
	       AND e.recalc_needed
	), ev AS (
	    -- Per-PO LATERAL + OFFSET 0 (see computeValuesSQL): index range scan per PO on
	    -- the equipment_events hypertable. n > 0 keeps the inner-join semantics (a PO
	    -- with no overlapping event is not updated).
	    SELECT el.id_equipment, el.lo, x.running, x.stopped
	      FROM eligible el
	      CROSS JOIN LATERAL (
	          SELECT COALESCE(sum(CASE WHEN ee.status = 6 THEN
	                     extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi)
	                                       - greatest(ee.ts_event, el.lo))) END), 0) AS running,
	                 COALESCE(sum(CASE WHEN ee.status IN (5, 10, 11) THEN
	                     extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi)
	                                       - greatest(ee.ts_event, el.lo))) END), 0) AS stopped,
	                 count(*) AS n
	            FROM %[3]s.equipment_events ee
	           WHERE ee.id_equipment = el.ev_src
	             AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && el.runtime_timerange
	             AND ee.ts_event >= now() - $1::interval AND ee.ts_event < now()
	          OFFSET 0
	      ) x
	     WHERE x.n > 0
	)
	SELECT e.id_production_order_runtime AS pk, e.xmin::text AS xm,
	       -- #253: bound to the PO wall-clock span, matching hour.go/shift.go/line_lead.go
	       -- (LEAST(running, ts_total)). ev.running SUMS status=6 event
	       -- durations, which double-counts when a tp=3 line carries interleaved
	       -- member-machine event streams → running_time can exceed elapsed time (the
	       -- 34–78× overflow the F3 sentinel flags). running_time can never physically
	       -- exceed the PO's wall-clock span; this enforces that invariant in the
	       -- computation (NOT a DQ clamp). No-op on clean single-stream data.
	       LEAST(ev.running, GREATEST(extract(epoch FROM (COALESCE(upper(e.runtime_timerange), now()) - lower(e.runtime_timerange))), 0))::numeric AS running_time,
	       ev.stopped::numeric AS stopped_time
	  FROM ev
	  JOIN %[4]s.production_orders_runtime e
	    ON e.id_equipment = ev.id_equipment
	   AND lower(e.runtime_timerange) = ev.lo`

const applyEventsSQL = `
	UPDATE %[4]s.production_orders_runtime e SET
	       running_time = r.running_time,
	       stopped_time = r.stopped_time
	  FROM jsonb_to_recordset($1::jsonb) AS r(pk bigint, running_time numeric, stopped_time numeric)
	 WHERE e.id_production_order_runtime = r.pk
	   AND r.pk = ANY($2::bigint[])`

// Phase B2 (FU#8): the PO-grain availability write path. available_time and
// planned_downtime are NEVER written to production_orders_runtime by any code
// path — the legacy PL/pgSQL had these assignments COMMENTED OUT and the Go port
// reproduced it, so recalc.go sums NULLs and oee_a = running/available and oee_p's
// time factor both collapse to 0 platform-wide (the Jan-2024 PO-grain A/P gap).
//
// This mirrors hour.go's math onto the PO grain: ts_total = the PO's own
// runtime_timerange wall-clock span; available_time = ts_total − LEAST(planned,
// ts_total); planned_downtime = LEAST(planned, ts_total). The planned predicate
// (%[6]s = plannedDowntimeExpr) reads ee.planned_downtime — the PO grain uses the
// default (no R3c changeover reclassification, matching recalc.go's scope note).
// Events read from ev_src (gross_machine or self), identical to computeEventsSQL.
// ideal_production is intentionally NOT written: recalc.go's oee_p recomputes the
// ideal factor from production_orders.ideal_production_speed, not this column.
//
// Flag-gated (POAvailabilityEnabled, default OFF) → not run → available_time stays
// NULL → byte-identical to today (golden-fixture parity). Flip to activate.
const computeAvailabilitySQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, e.runtime_timerange,
	           lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi,
	           COALESCE(eq.gross_machine, e.id_equipment) AS ev_src/*EXCL_ELIG*/
	      FROM %[4]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now())
	       AND e.recalc_needed
	), ev AS (
	    -- Per-PO LATERAL + OFFSET 0 (see computeValuesSQL); n > 0 = inner-join semantics.
	    SELECT el.id_equipment, el.lo,
	           GREATEST(extract(epoch FROM (el.hi - el.lo)), 0) AS ts_total,
	           x.planned/*EXCL_SEL*/
	      FROM eligible el
	      CROSS JOIN LATERAL (
	          SELECT COALESCE(sum(CASE WHEN %[6]s THEN
	                     extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi)
	                                       - greatest(ee.ts_event, el.lo))) END), 0) AS planned,
	                 count(*) AS n
	            FROM %[3]s.equipment_events ee
	           WHERE ee.id_equipment = el.ev_src
	             AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && el.runtime_timerange
	             AND ee.ts_event >= now() - $1::interval AND ee.ts_event < now()
	          OFFSET 0
	      ) x/*EXCL_JOIN*/
	     WHERE x.n > 0
	)
	SELECT e.id_production_order_runtime AS pk, e.xmin::text AS xm,
	       GREATEST(ev.ts_total - LEAST(ev.planned, ev.ts_total)/*EXCL_TERM*/, 0)::int AS available_time,
	       LEAST(ev.planned, ev.ts_total)::int AS planned_downtime/*EXCL_SET*/
	  FROM ev
	  JOIN %[4]s.production_orders_runtime e
	    ON e.id_equipment = ev.id_equipment
	   AND lower(e.runtime_timerange) = ev.lo`

// applyAvailabilitySQL — /*EXCL_COLS*/ and /*EXCL_APPLY*/ are filled by
// withPOExclusions (no_data_time / out_of_service_time) when exclusions are on.
const applyAvailabilitySQL = `
	UPDATE %[4]s.production_orders_runtime e SET
	       available_time   = r.available_time,
	       planned_downtime = r.planned_downtime/*EXCL_APPLY*/
	  FROM jsonb_to_recordset($1::jsonb) AS r(pk bigint, available_time int, planned_downtime int/*EXCL_COLS*/)
	 WHERE e.id_production_order_runtime = r.pk
	   AND r.pk = ANY($2::bigint[])`

// NOTE (phase order): prod runs phase A (which CLEARS recalc_needed)
// before phase B reads its own eligible set — but prod's loop
// evaluates BOTH phases per row from the SAME loop selection. The
// set-based port therefore snapshots eligibility ONCE per pass (the
// compute snapshot below) and applies phase B before phase A, so the
// flag-clear cannot shrink its set. Outputs identical; order of column
// writes within a pass is not observable between passes.

// Re-flags run in the short apply transaction. SKIP LOCKED: a row another writer
// holds right now (edge-api closing the PO) is left alone — that writer flags it
// itself, and the next pass re-flags it anyway. `recalc_needed IS NOT TRUE` skips
// the no-op rewrite of rows that are already flagged.
const computeReflagOpenSQL = `
	UPDATE %[4]s.production_orders_runtime SET recalc_needed = true
	 WHERE id_production_order_runtime IN (
	       SELECT id_production_order_runtime FROM %[4]s.production_orders_runtime
	        WHERE upper(runtime_timerange) IS NULL AND recalc_needed IS NOT TRUE
	          FOR UPDATE SKIP LOCKED)`

const computeReflagRecentSQL = `
	UPDATE %[4]s.production_orders_runtime SET recalc_needed = true
	 WHERE id_production_order_runtime IN (
	       SELECT id_production_order_runtime FROM %[4]s.production_orders_runtime
	        WHERE upper(runtime_timerange) > now() - interval '48 hours' AND recalc_needed IS NOT TRUE
	          FOR UPDATE SKIP LOCKED)`

// lockSnapshotRowsSQL — the optimistic-concurrency gate of the apply transaction.
// It locks only the runtime rows that are STILL the version the compute snapshot
// read (same xmin = no writer has touched the row since) and that nobody holds now
// (SKIP LOCKED). A row changed or held by another writer is left out of the apply:
// it keeps its recalc_needed flag and the next pass computes it from fresh data.
// $1 = [{pk, xm}] from the snapshot.
const lockSnapshotRowsSQL = `
	SELECT e.id_production_order_runtime
	  FROM %[4]s.production_orders_runtime e
	  JOIN jsonb_to_recordset($1::jsonb) AS s(pk bigint, xm text)
	    ON e.id_production_order_runtime = s.pk
	 WHERE e.xmin = s.xm::xid
	   FOR UPDATE OF e SKIP LOCKED`

// computePropagateHeadersSQL — a PO header is the SUM of its runtime rows
// (recalc.go), so whenever a runtime row is about to be recomputed its header
// must be re-summed AFTER it. Runs first in the refresh pass, while the runtime
// rows still carry recalc_needed (Phase A clears it); recalc runs after compute in
// the same pass, so the header sees the fresh values.
//
// Why (2026-09-29, CPACK PO audit): the header is re-flagged only while running
// (status 2) or for 48 h after ts_START (recalc.go) — a runtime row recomputed any
// other way (a re-flag after a fix, a window closed late by the replicator or the
// reconciler, the sweep below) updated gold but left core.production_orders with
// the stale sum. Excluded enterprises (recalc's own list) are never touched: their
// header is owned by another chain. $1 = window, $2 = excluded enterprises.
const computePropagateHeadersSQL = `
	UPDATE %[2]s.production_orders p SET recalc_needed = true
	 WHERE NOT p.recalc_needed AND p.status > 1
	   AND NOT (p.id_enterprise = ANY($2::int[]))
	   AND p.id_production_order IN (
	       SELECT e.id_production_order FROM %[4]s.production_orders_runtime e
	        WHERE e.recalc_needed
	          AND e.runtime_timerange && tstzrange(now() - $1::interval, now()))`

// computeSweepSQL — the CLOSED-row recompute sweep. The compute pass only sees a
// runtime row while it is flagged, and it is flagged only while open or for 48 h
// after it closed (the two re-flags above). Everything computed before that is
// frozen: when the code that computed it was wrong, the data it read was late, or a
// repair script edited it, a closed PO kept the bad number forever — the audit found
// 43 CPACK POs (SLEEVE1/2, CER400, ISIMAT: runtime net 0 while the line's hourly
// matched legacy) whose rows had been computed from the line's own counters before
// the line-lead pass existed, then zeroed by a one-off net<=gross clamp, and never
// recomputed by the code that would get them right.
//
// Each tick re-flags the closed rows of a few SLICES (id modulo $2), so every
// closed row inside the window is recomputed once per sweep period, spread evenly
// (~ rows/slices per tick) instead of one burst. $1 = window, $2 = slice count,
// $3 = the slices due this tick.
const computeSweepSQL = `
	UPDATE %[4]s.production_orders_runtime SET recalc_needed = true
	 WHERE NOT recalc_needed
	   AND upper(runtime_timerange) IS NOT NULL
	   AND runtime_timerange && tstzrange(now() - $1::interval, now())
	   AND (id_production_order_runtime %% $2::bigint) = ANY($3::bigint[])`

// computeOverflowDiagSQL mirrors computeEventsSQL's eligible+ev CTEs but,
// instead of updating, RETURNS the eligible rows whose computed running/
// stopped exceed a 32-bit integer — i.e. the exact rows that make the UPDATE
// raise SQLSTATE 22003 (running_time/stopped_time are int4). Run only on
// error, so an otherwise-opaque, intermittent overflow (a corrupt PO range or
// a far-future event ts_end producing an absurd interval) names the offending
// PO in the logs instead of vanishing. %[1]s=EvSchema, %[2]s=RefSchema;
// $1=window interval. int4 range: [-2147483648, 2147483647].
const computeOverflowDiagSQL = `
	WITH eligible AS (
	    SELECT e.id_equipment, e.runtime_timerange, lower(e.runtime_timerange) AS lo,
	           COALESCE(upper(e.runtime_timerange), now()) AS hi,
	           COALESCE(eq.gross_machine, e.id_equipment) AS ev_src
	      FROM %[4]s.production_orders_runtime e
	      JOIN %[2]s.equipments eq ON eq.id_equipment = e.id_equipment AND eq.id_site IS NOT NULL
	     WHERE e.runtime_timerange && tstzrange(now() - $1::interval, now()) AND e.recalc_needed
	), ev AS (
	    SELECT el.id_equipment, el.lo,
	           COALESCE(sum(CASE WHEN ee.status = 6 THEN extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi) - greatest(ee.ts_event, el.lo))) END), 0) AS running,
	           COALESCE(sum(CASE WHEN ee.status IN (5,10,11) THEN extract(epoch FROM (least(COALESCE(ee.ts_end, now()), el.hi) - greatest(ee.ts_event, el.lo))) END), 0) AS stopped
	      FROM eligible el
	      JOIN %[3]s.equipment_events ee ON ee.id_equipment = el.ev_src
	       AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && el.runtime_timerange
	       AND ee.ts_event >= now() - $1::interval AND ee.ts_event < now()
	     GROUP BY el.id_equipment, el.lo
	)
	SELECT id_equipment, lo, running, stopped
	  FROM ev
	 WHERE running > 2147483647 OR stopped > 2147483647 OR running < -2147483648 OR stopped < -2147483648
	 ORDER BY greatest(abs(running), abs(stopped)) DESC
	 LIMIT 5`

// diagnoseOverflow runs computeOverflowDiagSQL and logs the offending PO(s).
// Best-effort: any error here is itself logged and swallowed — this path only
// runs after a compute failure, to add context, never to change control flow.
func diagnoseOverflow(ctx context.Context, d flows.Dest, window string, logger *slog.Logger) {
	rows, err := d.Pool.Query(ctx, fmtRD(computeOverflowDiagSQL, d), window)
	if err != nil {
		logger.Warn("overflow diagnosis query failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
		return
	}
	defer rows.Close()
	found := false
	for rows.Next() {
		var idEquipment int
		var lo time.Time
		var running, stopped float64
		if err := rows.Scan(&idEquipment, &lo, &running, &stopped); err != nil {
			continue
		}
		found = true
		logger.Error("po-runtime-compute int overflow — offending PO row",
			slog.String("dest", d.Name),
			slog.Int("id_equipment", idEquipment),
			slog.Time("runtime_lo", lo),
			slog.Float64("running_sec", running),
			slog.Float64("stopped_sec", stopped))
	}
	if !found {
		// The overflow is intermittent — the bad row may have been corrected
		// by the legacy flow or aged out of the window between the failing
		// pass and this diagnosis. Note that so the gap isn't mistaken for a
		// bug in the diagnosis itself.
		logger.Warn("overflow diagnosis found no >int4 row (already cleared/aged out)", slog.String("dest", d.Name))
	}
}

// isIntOverflow reports whether err is a Postgres numeric-value-out-of-range
// error (SQLSTATE 22003).
func isIntOverflow(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "22003"
}

// computeStep is one phase of the pass: a read-only SELECT evaluated in the
// compute snapshot and the UPDATE that applies its rows.
type computeStep struct {
	name    string
	compute string // SELECT pk, xm, <values> — run in the snapshot
	apply   string // UPDATE ... FROM jsonb_to_recordset($1) ... WHERE pk = ANY($2)
	args    []any
	rows    string // the snapshot's rows as a JSON array (filled by the compute tx)
}

// RunCompute executes one compute pass for one destination. poAvail (FU#8) gates
// the PO-grain availability write path; default false ⇒ byte-identical parity.
//
// TWO TRANSACTIONS, SHORT LOCKS (2026-10-14). The pass used to be ONE repeatable-read
// transaction whose UPDATE statements each computed and wrote: the first phase's
// UPDATE row-locked every flagged runtime row — every OPEN PO of every line — and
// held the locks until COMMIT, through the 20–45 s of the remaining phases. A Change
// PO (edge-api setup) closes exactly that open row, so it queued behind the engine
// for 16–44 s ("process … still waiting for ShareLock … while updating tuple … in
// relation production_orders_runtime", staging Postgres log, 2026-10-14 17:04–17:13)
// and the operator tablet timed out at 12 s.
//
//  1. COMPUTE — a READ ONLY repeatable-read transaction runs every phase as a plain
//     SELECT over ONE snapshot (the 2026-09-30 one-snapshot rule: all phases see the
//     same eligible set). SELECTs take no row locks, so writers are never blocked by
//     the slow part. Each phase returns its rows (id + the row version it read, xmin).
//  2. APPLY — a short read-committed transaction locks the rows that are still the
//     version the snapshot read (same xmin) and not held by anyone (SKIP LOCKED),
//     then writes the computed values by primary key, phase by phase, in the old
//     order. A row another writer changed after the snapshot (a PO closed or a row
//     re-flagged mid-pass) is skipped: it keeps its flag and the next pass computes
//     it from fresh data — never a lost recompute, never a stale overwrite, and no
//     40001 that throws away the whole pass.
func RunCompute(ctx context.Context, d flows.Dest, window string, poAvail, poExcl bool, scope LineLeadScope) (int64, error) {
	ll := scope.Enterprises
	if ll == nil {
		ll = []int{}
	}
	pred := scope.Predicate("$2::int[]")
	// Apply order = the old statement order: Phase B (events), B2 (availability),
	// A2 (line-lead counters), A (values; reads A2's counters for line-lead rows and
	// clears recalc_needed).
	steps := []*computeStep{{name: "events", compute: fmtRD(computeEventsSQL, d), apply: fmtRD(applyEventsSQL, d), args: []any{window}}}
	if poAvail {
		// Phase B2 (FU#8). Off ⇒ skipped ⇒ available_time/planned_downtime stay NULL (parity).
		steps = append(steps, &computeStep{name: "availability",
			compute: fmtRD(withPOExclusions(computeAvailabilitySQL, poExcl, d.ConfigSchema), d, plannedDowntimeExpr(false)),
			apply:   fmtRD(withPOExclusions(applyAvailabilitySQL, poExcl, d.ConfigSchema), d),
			args:    []any{window}})
	}
	if scope.Any() {
		steps = append(steps, &computeStep{name: "line-lead values", compute: fmtRD(computeLineLeadValuesSQL, d, pred),
			apply: fmtRD(applyLineLeadValuesSQL, d), args: []any{window, ll}})
	}
	values := &computeStep{name: "values", compute: fmtRD(computeValuesSQL, d, pred), apply: fmtRD(applyValuesSQL, d), args: []any{window, ll}}
	steps = append(steps, values)

	snapshot, err := computeSnapshot(ctx, d, steps)
	if err != nil {
		return 0, err
	}
	if computeBetweenPhasesHook != nil {
		computeBetweenPhasesHook(ctx)
	}

	tx, err := d.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return 0, fmt.Errorf("compute apply begin: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after Commit
	locked := []int64{}
	if snapshot != "[]" {
		rows, err := tx.Query(ctx, fmtRD(lockSnapshotRowsSQL, d), snapshot)
		if err != nil {
			return 0, fmt.Errorf("compute lock: %w", err)
		}
		locked, err = pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return 0, fmt.Errorf("compute lock: %w", err)
		}
	}
	var affected int64
	if len(locked) > 0 {
		for _, st := range steps {
			if st.rows == "[]" {
				continue
			}
			tag, err := tx.Exec(ctx, st.apply, st.rows, locked)
			if err != nil {
				return 0, fmt.Errorf("compute %s: %w", st.name, err)
			}
			if st == values {
				affected = tag.RowsAffected()
			}
		}
	}
	if _, err := tx.Exec(ctx, fmtRD(computeReflagOpenSQL, d)); err != nil {
		return 0, fmt.Errorf("reflag open: %w", err)
	}
	if _, err := tx.Exec(ctx, fmtRD(computeReflagRecentSQL, d)); err != nil {
		return 0, fmt.Errorf("reflag recent: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("compute commit: %w", err)
	}
	return affected, nil
}

// computeSnapshot runs every step's SELECT in ONE read-only repeatable-read
// snapshot, stores each step's rows (JSON array) in st.rows and returns the union
// of the rows' {pk, xm} versions the apply transaction must find unchanged.
func computeSnapshot(ctx context.Context, d flows.Dest, steps []*computeStep) (string, error) {
	tx, err := d.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return "", fmt.Errorf("compute begin: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // read-only; Commit below ends it
	for _, st := range steps {
		q := "SELECT COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)::text FROM (" + st.compute + "\n) r"
		if err := tx.QueryRow(ctx, q, st.args...).Scan(&st.rows); err != nil {
			return "", fmt.Errorf("compute %s: %w", st.name, err)
		}
	}
	// The row versions every step read: one {pk, xm} per runtime row (all steps
	// read the same snapshot, so a row has the same xm in every step).
	var snapshot string
	if err := tx.QueryRow(ctx, `
		SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('pk', x.pk, 'xm', x.xm)), '[]'::jsonb)::text
		  FROM unnest($1::jsonb[]) AS a(rows), jsonb_to_recordset(a.rows) AS x(pk bigint, xm text)`,
		stepRows(steps)).Scan(&snapshot); err != nil {
		return "", fmt.Errorf("compute snapshot: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return "", fmt.Errorf("compute snapshot commit: %w", err)
	}
	return snapshot, nil
}

func stepRows(steps []*computeStep) []string {
	out := make([]string, 0, len(steps))
	for _, st := range steps {
		out = append(out, st.rows)
	}
	return out
}

// computeBetweenPhasesHook is a test seam: nil in production. It runs after the
// compute snapshot and before the apply transaction — where a concurrent writer's
// commit (a re-flag, a PO closed by edge-api) lands in real life.
var computeBetweenPhasesHook func(ctx context.Context)

// RunPropagateHeaders flags the header of every runtime row the next compute
// pass will recompute (computePropagateHeadersSQL). Call it BEFORE RunCompute.
func RunPropagateHeaders(ctx context.Context, d flows.Dest, window string, exclEnterprises []int) (int64, error) {
	if exclEnterprises == nil {
		exclEnterprises = []int{}
	}
	tag, err := d.Pool.Exec(ctx, fmtRD(computePropagateHeadersSQL, d), window, exclEnterprises)
	if err != nil {
		return 0, fmt.Errorf("propagate headers: %w", err)
	}
	return tag.RowsAffected(), nil
}

// RunSweep re-flags the closed runtime rows of the given slices (computeSweepSQL).
// A no-op when slices is empty or slicesTotal < 1.
func RunSweep(ctx context.Context, d flows.Dest, window string, slicesTotal int64, slices []int64) (int64, error) {
	if slicesTotal < 1 || len(slices) == 0 {
		return 0, nil
	}
	tag, err := d.Pool.Exec(ctx, fmtRD(computeSweepSQL, d), window, slicesTotal, slices)
	if err != nil {
		return 0, fmt.Errorf("sweep: %w", err)
	}
	return tag.RowsAffected(), nil
}

// sweepScheduler hands out the slices due at each tick: slice = tick number modulo
// the slice count, where a tick is one `every` interval of wall-clock time. Ticks
// that were skipped (a pass that ran longer than `every`) are caught up on the next
// call, capped at one full cycle, so no slice is starved by a regular overrun.
type sweepScheduler struct {
	total int64 // slices per sweep period (period / every), 0 = disabled
	every time.Duration
	last  int64 // last tick handed out; 0 = none yet
}

func newSweepScheduler(period, every time.Duration) *sweepScheduler {
	if period <= 0 || every <= 0 {
		return &sweepScheduler{}
	}
	n := int64(period / every)
	if n < 1 {
		n = 1
	}
	return &sweepScheduler{total: n, every: every}
}

func (s *sweepScheduler) due(now time.Time) []int64 {
	if s.total == 0 {
		return nil
	}
	cur := now.UnixNano() / int64(s.every)
	from := cur
	if s.last > 0 && s.last < cur {
		from = s.last + 1
		if cur-from+1 > s.total {
			from = cur - s.total + 1
		}
	} else if s.last >= cur {
		return nil // same tick already handed out
	}
	s.last = cur
	out := make([]int64, 0, cur-from+1)
	for t := from; t <= cur; t++ {
		out = append(out, t%s.total)
	}
	return out
}

// LoopRefresh = the dispatcher (ledger: po-runtime-refresh): header propagation,
// compute, recalc, then the closed-row sweep — ordered, drop-per-step (prod's
// fail-soft blocks). sweepPeriod 0 disables the sweep.
func LoopRefresh(ctx context.Context, dests []flows.Dest, window string, exclEnterprises []int, poAvail, poExcl bool, lineLead LineLeadScope, every, sweepPeriod time.Duration, logger *slog.Logger, obs jobs.Observer, extra func(context.Context, flows.Dest) error) {
	logger.Info("po-runtime-refresh started (P3b dispatcher: compute → recalc)", slog.Bool("po_availability", poAvail),
		slog.Duration("closed_row_sweep", sweepPeriod))
	sweep := newSweepScheduler(sweepPeriod, every)
	jobs.Loop(ctx, jobs.Job{Name: "po-runtime-refresh", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		slices := sweep.due(time.Now())
		for _, d := range dests {
			if _, err := RunPropagateHeaders(ctx, d, window, exclEnterprises); err != nil {
				logger.Warn("po-runtime-propagate failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
			if _, err := RunCompute(ctx, d, window, poAvail, poExcl, lineLead); err != nil {
				logger.Warn("po-runtime-compute failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				// An int-overflow (SQLSTATE 22003) here is an opaque,
				// intermittent failure — dump the offending PO row so it's
				// actionable rather than a recurring mystery in the logs.
				if isIntOverflow(err) {
					diagnoseOverflow(ctx, d, window, logger)
				}
				if firstErr == nil {
					firstErr = err
				}
			}
			if _, err := RunRecalc(ctx, d, window, exclEnterprises); err != nil {
				logger.Warn("po-runtime-recalc failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
			// Closed-row sweep: flags rows for the NEXT pass, whose propagation step
			// then flags their headers before compute, so recalc re-sums fresh values.
			if _, err := RunSweep(ctx, d, window, sweep.total, slices); err != nil {
				logger.Warn("po-runtime-sweep failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
			if extra != nil {
				// the dispatcher's third step (uns jobs), fail-soft
				if err := extra(ctx, d); err != nil {
					logger.Warn("po-refresh extra step failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
					if firstErr == nil {
						firstErr = err
					}
				}
			}
		}
		return firstErr
	}}, logger, obs)
}

// Parity accessors (single-source emission).
func ComputeValuesSQLForParity() string {
	return strings.Replace(computeValuesSQL, "%[6]s", LineLeadScope{}.Predicate("$2::int[]"), 1)
}
func ComputeEventsSQLForParity() string        { return computeEventsSQL }
func ComputeReflagOpenForParity() string       { return computeReflagOpenSQL }
func ComputeReflagRecentForParity() string     { return computeReflagRecentSQL }
func ComputeSweepSQLForParity() string         { return computeSweepSQL }
func ComputePropagateHeadersForParity() string { return computePropagateHeadersSQL }
