// line_lead.go — the LINE-FROM-LEAD OEE derivation for counter-only,
// line-metered clients (e.g. CPACK). Sibling of availability.go's counters-only
// Availability fallback; same idle-timeout sessionization machinery, different
// subject: here a tp=3 LINE with no counter stream of its own borrows its
// lead machine's stream wholesale.
//
// THE MODEL. A line-metered client puts its production counters on individual
// machines (tp=1) but reports OEE at the LINE (tp=3). The line has no own count
// series, so the ordinary rollup zero-fills it (gross/net 0 → oee 0) even while
// the floor is producing. The convention that resolves this: one designated
// machine — equipments.lead_machine — REPRESENTS the line. Everything the line
// grain needs is read off that lead machine's aggregates:
//
//   - gross / net / scrap ← sum of equipment_categorical_1hour buckets over the
//     grain window (the same _1hour cagg the machine grain sums). By default all
//     three come from lead_machine. A SPLIT-INSTRUMENTATION line puts its counters
//     on DIFFERENT machines: equipments.gross_machine names the gross/input source
//     and equipments.scrap_machine the scrap/defect source, while lead_machine stays
//     the net/output + availability source. When gross_machine/scrap_machine are
//     NULL, gross_id COALESCEs to lead_id and scrap_id is NULL (⇒ 0), so behaviour
//     is byte-identical to the single-lead pass. equipments.net_machine moves only
//     the NET source off the lead (net_id = COALESCE(net_machine, lead_machine)): a
//     line whose lead is its INFEED (CPACK: availability and live status follow the
//     first machine) but whose output is counted on the last machine (TEXA) sets it,
//     so gross = infeed and net = outfeed, as legacy meters the line.
//     COUNTER-ROLE MATRIX. The three counters obey the identity
//     gross = net + scrap (ProdConsumedCount = ProdProcessedCount +
//     ProdDefectiveCount). The reconciled CTE fills whichever counter a line does
//     not report from the two it does:
//       • G+N present    → take both as reported (scrap = gross − net).
//       • N+S, no gross  → gross = net + scrap  (e.g. an infeed with no consumed
//         counter but a measured defect stream).
//       • G+S, no net    → net = gross − scrap.
//       • net-only       → gross = net (quality 1.0, no scrap measured — L8/L10/SLEEVE).
//       • gross-only     → net = gross (quality 1.0).
//     With no scrap counter (s=0) every branch reduces to the pre-scrap G+N /
//     net-only logic byte-for-byte.
//   - availability   ← idle-timeout sessionization of the lead's
//     equipment_categorical_1min productive minutes (identical inference to
//     availability.go: order the productive minutes, an inter-minute gap beyond
//     the idle timeout closes a session; running = Σ session-seconds, each
//     session credited through last-count + idle-timeout, clipped to bucket end;
//     idle stretches book as stopped → Availability < 1).
//   - ideal_speed    ← the lead machine's equipments.production_speed (the line
//     itself carries no rated speed), falling back to the line row's own
//     ideal_speed then 0.
//   - oee back-solved ← oee = net / ideal_production ; oee_a = running / total ;
//     oee_q = net / gross ; oee_p = the residual that closes oee = a·p·q (shift
//     grain solves it inline; hour grain leaves it to hourOeePSQL, which runs
//     next off the just-cleared rows — matching hourCountsAvailSQL).
//
// AUTO-ENGAGE. Config-gated (CountersAvail.LineLeadEnabled +
// LineLeadEnterprises, plus a positive idle timeout — see engagedLineLead).
// The pass touches ONLY tp=3 lines with a non-null lead_machine in an opted-in
// enterprise, so a state-driven line is never disturbed even by accident.
//
// SINGLE WRITER / MUTUAL EXCLUSION. This pass writes the LINE rows (tp=3); the
// counters-only Availability fallback writes opted-in MACHINE rows (tp=1). Per
// client the two are mutually exclusive — a line-metered client engages
// line-lead, a machine-metered counters-only client engages counters-avail —
// so every equipment_runtime cell keeps exactly one writer (the #456
// two-writer lesson). Like the fallback, this pass is a SEPARATE step appended
// to RunHour / RunShift only when engagedLineLead(), and is NOT part of the
// *ForParity accessors the prod comparator diffs, so the flag-off statement
// stream stays byte-identical to the state-only rollup.
package rollup

import "strings"

// shiftLineLeadSQL — %[1]s=EvSchema, %[2]s=RefSchema, %[3]s=enterprise bigint[] literal, %[7]d=idle timeout secs.
var shiftLineLeadSQL = `
	WITH lines AS (
	    SELECT el.id_equipment AS line_id, el.ts_value,
	           LEAST(el.ts_end, now()) AS bend,
	           extract(epoch FROM (LEAST(el.ts_end, now()) - el.ts_value)) AS ts_total,
	           eq.lead_machine AS lead_id,
	           -- SPLIT-INSTRUMENTATION: gross may live on a different machine than
	           -- net. gross_machine names the input/gross source; NULL ⇒ single-lead
	           -- (gross_id == lead_id) so the COALESCE is a no-op for legacy lines.
	           COALESCE(eq.gross_machine, eq.lead_machine) AS gross_id,
	           -- NET source. net_machine names the output machine when it is NOT the
	           -- lead (CPACK: lead = infeed for availability, net on the outfeed TEXA).
	           -- NULL ⇒ net from lead_machine, byte-identical to before.
	           COALESCE(eq.net_machine, eq.lead_machine) AS net_id,
	           -- COUNTER ROLES. Which counter to read on the gross / net machine. NULL ⇒
	           -- gross from ProdConsumedCount, net from ProdProcessedCount (as before).
	           -- CPACK L3 counts the line's input as BREYER's PROCESSED counter and its
	           -- output as TEXA's CONSUMED counter, so it sets processed / consumed.
	           eq.gross_counter AS gross_ctr,
	           eq.net_counter AS net_ctr,
	           -- SCRAP source. scrap_machine names the machine whose ProdDefectiveCount
	           -- is this line's scrap/defect source. NULL (the default) ⇒ no scrap
	           -- counter ⇒ the scrap subquery returns NULL ⇒ s=0, so the reconciliation
	           -- CASEs reduce to the pre-scrap G+N / net-only behaviour byte-for-byte.
	           eq.scrap_machine AS scrap_id,
	           -- METER FILL (2026-10-01). NULL/true: a meter silent for a whole hour is
	           -- "missing" and filled from the other (identity below). false: the line's
	           -- meters are report-by-exception TOTALIZERS — a silent hour's units arrive
	           -- in the next report's delta, so filling counts them twice (Bispharma L90
	           -- 09-01..09-30: infeed 677k, outfeed 640k, filled gross 758k). Such lines
	           -- take each meter as measured, 0 when silent.
	           COALESCE(eq.fill_missing_meter, true) AS fill_missing,
	           (SELECT q.production_speed FROM %[2]s.equipments q WHERE q.id_equipment = eq.lead_machine) AS lead_ideal
	      FROM shift_elig el
	      JOIN %[2]s.equipments eq ON eq.id_equipment = el.id_equipment
	     WHERE eq.tp_equipment = 3 AND COALESCE(eq.lead_machine,0) > 0
	       AND %[6]s
	       -- #207: was a 2-day window — the live line-lead lookback.
	       -- RunShift drains its 30-day recalc_needed backlog oldest-first (bounded
	       -- LIMIT), but this 2-day filter capped the line-lead pass to the recent
	       -- tail, so a tp=3 LINE shift row stranded by an outage OLDER than 2 days
	       -- (e.g. the #196 Sept 1–5 CPACK gap, drained days later) never got its
	       -- lead-derived runtime — it kept the state-only zero-fill. Widen to the
	       -- 25-day window this pass already writes over (the final UPDATE guard
	       -- below) so the whole draining backlog is covered. Pure row-selection
	       -- (each row's math is anchored on its own ts_value/ts_end); the set is
	       -- still bounded by shift_elig + the LIMIT, so live ticks are unaffected
	       -- (no old rows are flagged in steady state). Not in the parity accessors.
	       AND el.ts_value >= now() - interval '25 day'
	), bucket_counts AS (
	    -- PER-HOUR counter sums (2026-09-25). Each hour bucket the shift covers (same
	    -- selection as before: ts_value in [shift start, bend)) gets its own GROSS/NET/
	    -- SCRAP from its own source machines. The counter-role reconciliation below then
	    -- runs PER BUCKET — like the hour grain — instead of on shift-level sums: when a
	    -- source reports only intermittently (Bispharma leads with gross in 4 of 11 hours,
	    -- net in 11 of 11) the shift sums read "G+N present" with net far above the
	    -- sparse gross, so net was clamped to that gross and the shift UNDERCOUNTED the
	    -- hours that only reported net (09-15 Bispharma: shift 1.18 M vs hourly 1.38 M).
	    SELECT l.line_id, l.ts_value, b.bts, l.fill_missing,
	           (SELECT sum(CASE WHEN l.gross_ctr = 'processed' THEN cg.net_production_incr ELSE cg.gross_production_incr END) FROM %[3]s.equipment_categorical_1hour cg
	             WHERE cg.id_equipment = l.gross_id AND cg.ts_value = b.bts) AS gross,
	           (SELECT sum(CASE WHEN l.net_ctr = 'consumed' THEN cn.gross_production_incr ELSE cn.net_production_incr END) FROM %[3]s.equipment_categorical_1hour cn
	             WHERE cn.id_equipment = l.net_id AND cn.ts_value = b.bts) AS net,
	           (SELECT sum(cs.scrap_incr) FROM %[3]s.equipment_categorical_1hour cs
	             WHERE cs.id_equipment = l.scrap_id AND cs.ts_value = b.bts) AS scrap
	      FROM lines l
	      CROSS JOIN LATERAL (
	          SELECT DISTINCT c.ts_value AS bts
	            FROM %[3]s.equipment_categorical_1hour c
	           WHERE c.id_equipment IN (l.gross_id, l.lead_id, l.net_id, l.scrap_id)
	             AND c.ts_value >= l.ts_value AND c.ts_value < l.bend
	           OFFSET 0
	      ) b
	), bucket_reconciled AS (
	    -- COUNTER-ROLE MATRIX via the identity gross = net + scrap (ProdConsumedCount
	    -- = ProdProcessedCount + ProdDefectiveCount), PER BUCKET. Reconcile whichever
	    -- pair of the three counters the bucket reports, filling the missing one:
	    --   G+N (+/- S): gross+net present ⇒ take both as measured (S ignored), even
	    --                when gross < net (transit / undercounting meter — shown, not fixed).
	    --   N+S  (no G): gross absent, net+scrap present ⇒ gross = net + scrap.
	    --   G+S  (no N): net absent, gross+scrap present ⇒ net = gross - scrap.
	    --   net-only    : only net ⇒ gross = net (quality 1.0, legacy convention).
	    --   gross-only  : only gross ⇒ net = gross (quality 1.0).
	    -- (Keep this const free of any literal percent sign: fmt.Sprintf format string.)
	    SELECT c.line_id, c.ts_value,
	           -- A MEASURED gross is stored as measured, also when it is below net
	           -- (2026-09-29, "no clamps distorting data"): within an hour that is
	           -- units in transit between the infeed and outfeed sensors, and over a
	           -- shift/day it exposes a meter that undercounts — both are facts the
	           -- data must show, not repair. (Replaces #1472's gross = net + scrap.)
	           -- Only a MISSING meter is filled, per the identity below.
	           CASE WHEN COALESCE(c.gross,0) > 0 THEN COALESCE(c.gross,0)
	                WHEN NOT c.fill_missing THEN 0
	                WHEN COALESCE(c.net,0) > 0 AND COALESCE(c.scrap,0) > 0 THEN COALESCE(c.net,0) + COALESCE(c.scrap,0)
	                WHEN COALESCE(c.net,0) > 0 THEN COALESCE(c.net,0)
	                ELSE 0 END AS eff_gross,
	           CASE WHEN COALESCE(c.net,0) > 0 THEN COALESCE(c.net,0)
	                WHEN NOT c.fill_missing THEN 0
	                WHEN COALESCE(c.gross,0) > 0 AND COALESCE(c.scrap,0) > 0 THEN COALESCE(c.gross,0) - COALESCE(c.scrap,0)
	                WHEN COALESCE(c.gross,0) > 0 THEN COALESCE(c.gross,0)
	                ELSE 0 END AS eff_net
	      FROM bucket_counts c
	), reconciled AS MATERIALIZED (
	    -- MATERIALIZED (and active below): each is referenced ONCE, so PG12+ inlines it into
	    -- the UPDATE's LEFT JOIN and re-runs the per-line counter subqueries for every outer
	    -- row: O(N^2). Measured 2026-09-24: 75-row shift batch 104-111 s -> 5-8 s, 50-row
	    -- hour backfill 22-58 s -> 7-9 s, output identical (the long line-lead ticks that
	    -- held equipment_oee_daily row locks and stalled the shift rollup).
	    -- Shift totals = SUM of the per-bucket reconciled values (no per-bucket net<=gross
	    -- clamp since 2026-09-29: it inflated gross and scrap over any period, because
	    -- transit only ever got corrected in one direction) → shift == sum of its served
	    -- hour rows. LEFT JOIN keeps a line with no buckets at 0 (as before).
	    SELECT l.line_id, l.ts_value,
	           COALESCE(sum(br.eff_gross), 0) AS eff_gross,
	           COALESCE(sum(br.eff_net), 0) AS eff_net
	      FROM lines l
	      LEFT JOIN bucket_reconciled br ON br.line_id = l.line_id AND br.ts_value = l.ts_value
	     GROUP BY l.line_id, l.ts_value
	), prod_raw AS (
	    SELECT l.line_id, l.ts_value, l.bend, m.ts_value AS mts, m.is_lead
	      FROM lines l
	      CROSS JOIN LATERAL (
	          -- #259 FIX: OFFSET 0 is an optimizer fence forcing PER-LINE correlated
	          -- execution, so id_equipment is a runtime constant and the real-time cagg's
	          -- raw scan uses the (id_equipment, ts_value) index. Without it the planner
	          -- decorrelates this into a hash join that materializes the WHOLE real-time
	          -- 1min aggregation of ALL machines (~1000x blowup → 300s tick rollback →
	          -- OEE stall). Result-identical to the prior JOIN (parity-proven).
	          -- Candidate productive minutes from the lead AND the line's gross/net
	          -- machines (same id for single-machine lines ⇒ same rows as before).
	          SELECT mm.ts_value, (mm.id_equipment = l.lead_id) AS is_lead
	            FROM %[3]s.equipment_categorical_1min mm
	           WHERE mm.id_equipment IN (l.lead_id, l.gross_id, l.net_id)
	             AND mm.ts_value >= l.ts_value AND mm.ts_value < l.bend
	             -- A minute is "productive" if the lead moved EITHER input (gross) or
	             -- output (net). A split-instrumentation line's lead is the net/output
	             -- machine and is NET-ONLY (gross=0), so a gross-only filter misses all
	             -- its activity → oee_a=0. For single-lead leads gross and net move
	             -- together, so this is equivalent (no change to working lines).
	             AND (mm.gross_production_incr > 0 OR mm.net_production_incr > 0 OR mm.scrap_incr > 0)
	           OFFSET 0
	      ) m
	), prod_sel AS (
	    -- LEAD-SILENT FALLBACK (2026-09-29). Running time follows the LEAD machine,
	    -- but when the lead has NO productive minute in an hour while the line's
	    -- gross/net machine is counting, the lead is dark (not the line stopped):
	    -- CPACK L5's lead BREYER published nothing real 09-15..09-23 while TEXA
	    -- counted ~600k → 18 shifts with production and running_time = 0. In such
	    -- hours only, the gross/net machines' productive minutes stand in. Hours
	    -- where the lead is active use the lead alone, exactly as before.
	    SELECT DISTINCT line_id, ts_value, bend, mts
	      FROM (SELECT p.*, bool_or(p.is_lead) OVER (
	                   PARTITION BY p.line_id, p.ts_value, date_trunc('hour', p.mts)) AS lead_hour
	              FROM prod_raw p) z
	     WHERE z.is_lead OR NOT z.lead_hour
	), prod_min AS (
	    SELECT line_id, ts_value, bend, mts,
	           extract(epoch FROM (mts - lag(mts) OVER (
	               PARTITION BY line_id, ts_value ORDER BY mts))) AS gap
	      FROM prod_sel
	), islanded AS (
	    SELECT line_id, ts_value, bend, mts,
	           sum(CASE WHEN gap IS NULL OR gap > %[7]d THEN 1 ELSE 0 END)
	               OVER (PARTITION BY line_id, ts_value ORDER BY mts) AS island
	      FROM prod_min
	), sessions AS (
	    SELECT line_id, ts_value,
	           extract(epoch FROM (LEAST(max(mts) + make_interval(secs => %[7]d), min(bend)) - min(mts))) AS span
	      FROM islanded
	     GROUP BY line_id, ts_value, island
	), active AS MATERIALIZED (
	    SELECT line_id, ts_value, sum(span) AS raw_running
	      FROM sessions GROUP BY line_id, ts_value
	)
	-- PLANNED DOWNTIME (regression fix 2026-09-28). This pass is the single writer
	-- of a line-lead row and used to hard-code planned_downtime = 0 and
	-- available_time = the whole bucket, discarding the planned stops the events
	-- step had just classified. Since CPACK moved onto line-lead (~2026-08-31)
	-- every planned stop counted as downtime and line OEE ran 10-50 pct low vs
	-- legacy. Planned time is the overlap of the LINE's planned events with the
	-- bucket. An event lasts until the NEXT event starts (legacy semantics);
	-- ts_end is only a fallback because the closer can truncate it.
	-- The event IN EFFECT at the scan bound is always included (see
	-- eventsInEffectSQL): an idle line's planned stop that began weeks before
	-- the batch still covers this bucket.
	, planned_ev AS MATERIALIZED (
	    SELECT ee.id_equipment, ee.ts_event, ee.ts_eff_end
	      FROM (
	        SELECT x.id_equipment, x.ts_event, x.planned_downtime, x.change_over,
	               LEAST(COALESCE(lead(x.ts_event) OVER (PARTITION BY x.id_equipment ORDER BY x.ts_event),
	                              x.ts_end, now()), now()) AS ts_eff_end
	          FROM ` + eventsInEffectSQL("%[1]s", "SELECT DISTINCT line_id FROM lines",
	"(SELECT min(ts_value) FROM lines) - interval '10 days'") + ` x
	      ) ee
	     WHERE ` + plannedPredToken + `
	), planned AS (
	    SELECT l.line_id, l.ts_value,
	           LEAST(COALESCE(sum(extract(epoch FROM (LEAST(p.ts_eff_end, l.bend) - GREATEST(p.ts_event, l.ts_value)))), 0), l.ts_total) AS ts_planned
	      FROM lines l
	      JOIN planned_ev p ON p.id_equipment = l.line_id AND p.ts_event < l.bend AND p.ts_eff_end > l.ts_value
	     GROUP BY l.line_id, l.ts_value, l.ts_total
	), lines_p AS (
	    -- ts_avail = planned production time (bucket minus planned stops): the
	    -- Availability denominator and the ideal-production basis, as in legacy.
	    SELECT l.*, COALESCE(p.ts_planned, 0) AS ts_planned,
	           l.ts_total - COALESCE(p.ts_planned, 0) AS ts_avail
	      FROM lines l
	      LEFT JOIN planned p ON p.line_id = l.line_id AND p.ts_value = l.ts_value
	)

	UPDATE %[4]s.equipment_oee_shift e SET
	       gross            = COALESCE(r.eff_gross, 0),
	       net              = COALESCE(r.eff_net, 0),
	       scrap            = COALESCE(r.eff_gross, 0) - COALESCE(r.eff_net, 0),  -- signed: negative = transit
	       available_time   = l.ts_avail,
	       running_time     = LEAST(COALESCE(a.raw_running, 0), l.ts_avail),
	       stopped_time     = l.ts_avail - LEAST(COALESCE(a.raw_running, 0), l.ts_avail),
	       planned_downtime = l.ts_planned,
	       downtime         = l.ts_avail - LEAST(COALESCE(a.raw_running, 0), l.ts_avail),
	       changeover_time  = 0,
	       ideal_speed      = COALESCE(l.lead_ideal, e.ideal_speed, 0),
	       ideal_production = COALESCE((l.ts_avail / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0),
	       recalc_needed    = false,
	       -- UNCAPPED since 2026-09-29 (*_oee_bounds now only lower-bounds oee/oee_p/
	       -- oee_q): P > 1 means the configured ideal speed is too low, hourly Q > 1
	       -- means units in transit — facts the UI shows. oee_a keeps [0,1] (running
	       -- time is already capped at the available time).
	       oee   = GREATEST(COALESCE(COALESCE(r.eff_net,0) / NULLIF((l.ts_avail / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0), 0), 0),
	       oee_a = GREATEST(LEAST(COALESCE(LEAST(COALESCE(a.raw_running, 0), l.ts_avail) / NULLIF(l.ts_avail, 0), 0), 1), 0),
	       oee_q = GREATEST(COALESCE(COALESCE(r.eff_net,0) / NULLIF(r.eff_gross, 0), 0), 0),
	       oee_p = GREATEST(COALESCE(
	             COALESCE(COALESCE(r.eff_net,0) / NULLIF((l.ts_avail / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0), 0)
	             / NULLIF(
	                 COALESCE(LEAST(COALESCE(a.raw_running, 0), l.ts_avail) / NULLIF(l.ts_avail, 0), 0)
	                 * COALESCE(COALESCE(r.eff_net,0) / NULLIF(r.eff_gross, 0), 0), 0), 0), 0)
	  FROM lines_p l
	  LEFT JOIN reconciled r ON r.line_id = l.line_id AND r.ts_value = l.ts_value
	  LEFT JOIN active a ON a.line_id = l.line_id AND a.ts_value = l.ts_value
	 WHERE e.id_equipment = l.line_id AND e.ts_value = l.ts_value
	   AND e.ts_value >= now() - interval '25 day'`

// hourLineLeadSQL — %[1]s=EvSchema, %[2]s=RefSchema, %[3]s=enterprise bigint[] literal, %[7]d=idle timeout secs.
// Leaves oee_p to hourOeePSQL (runs next off the just-cleared rows), matching hourCountsAvailSQL.
// Overwrites the events step's availability for these lines, exactly like the shift pass.
var hourLineLeadSQL = `
	WITH lines AS (
	    SELECT el.id_equipment AS line_id, el.ts_value,
	           LEAST(el.ts_value + interval '1 hour', now()) AS bend,
	           extract(epoch FROM (LEAST(el.ts_value + interval '1 hour', now()) - el.ts_value)) AS ts_total,
	           eq.lead_machine AS lead_id,
	           -- SPLIT-INSTRUMENTATION: gross may live on a different machine than
	           -- net. gross_machine names the input/gross source; NULL ⇒ single-lead
	           -- (gross_id == lead_id) so the COALESCE is a no-op for legacy lines.
	           COALESCE(eq.gross_machine, eq.lead_machine) AS gross_id,
	           -- NET source. net_machine names the output machine when it is NOT the
	           -- lead (CPACK: lead = infeed for availability, net on the outfeed TEXA).
	           -- NULL ⇒ net from lead_machine, byte-identical to before.
	           COALESCE(eq.net_machine, eq.lead_machine) AS net_id,
	           -- COUNTER ROLES. Which counter to read on the gross / net machine. NULL ⇒
	           -- gross from ProdConsumedCount, net from ProdProcessedCount (as before).
	           -- CPACK L3 counts the line's input as BREYER's PROCESSED counter and its
	           -- output as TEXA's CONSUMED counter, so it sets processed / consumed.
	           eq.gross_counter AS gross_ctr,
	           eq.net_counter AS net_ctr,
	           -- SCRAP source. scrap_machine names the machine whose ProdDefectiveCount
	           -- is this line's scrap/defect source. NULL (the default) ⇒ no scrap
	           -- counter ⇒ the scrap subquery returns NULL ⇒ s=0, so the reconciliation
	           -- CASEs reduce to the pre-scrap G+N / net-only behaviour byte-for-byte.
	           eq.scrap_machine AS scrap_id,
	           -- METER FILL (2026-10-01). NULL/true: a meter silent for a whole hour is
	           -- "missing" and filled from the other (identity below). false: the line's
	           -- meters are report-by-exception TOTALIZERS — a silent hour's units arrive
	           -- in the next report's delta, so filling counts them twice (Bispharma L90
	           -- 09-01..09-30: infeed 677k, outfeed 640k, filled gross 758k). Such lines
	           -- take each meter as measured, 0 when silent.
	           COALESCE(eq.fill_missing_meter, true) AS fill_missing,
	           (SELECT q.production_speed FROM %[2]s.equipments q WHERE q.id_equipment = eq.lead_machine) AS lead_ideal
	      FROM hour_elig el
	      JOIN %[2]s.equipments eq ON eq.id_equipment = el.id_equipment
	     WHERE eq.tp_equipment = 3 AND COALESCE(eq.lead_machine,0) > 0
	       AND %[6]s
	), counts AS (
	    -- Raw per-source sums: GROSS from gross_id (input machine), NET from net_id
	    -- (output machine: net_machine, else lead_id), SCRAP from scrap_id (defect machine). Single-bucket lookups
	    -- matching the hour join (ts_value = l.ts_value). A NULL source id ⇒ no matching
	    -- rows ⇒ NULL sum ⇒ 0 downstream.
	    SELECT l.line_id, l.ts_value, l.fill_missing,
	           (SELECT sum(CASE WHEN l.gross_ctr = 'processed' THEN cg.net_production_incr ELSE cg.gross_production_incr END) FROM %[3]s.equipment_categorical_1hour cg
	             WHERE cg.id_equipment = l.gross_id AND cg.ts_value = l.ts_value) AS gross,
	           (SELECT sum(CASE WHEN l.net_ctr = 'consumed' THEN cn.gross_production_incr ELSE cn.net_production_incr END) FROM %[3]s.equipment_categorical_1hour cn
	             WHERE cn.id_equipment = l.net_id AND cn.ts_value = l.ts_value) AS net,
	           (SELECT sum(cs.scrap_incr) FROM %[3]s.equipment_categorical_1hour cs
	             WHERE cs.id_equipment = l.scrap_id AND cs.ts_value = l.ts_value) AS scrap
	      FROM lines l
	), reconciled AS MATERIALIZED (
	    -- MATERIALIZED (and active below): each is referenced ONCE, so PG12+ inlines it into
	    -- the UPDATE's LEFT JOIN and re-runs the per-line counter subqueries for every outer
	    -- row: O(N^2). Measured 2026-09-24: 75-row shift batch 104-111 s -> 5-8 s, 50-row
	    -- hour backfill 22-58 s -> 7-9 s, output identical (the long line-lead ticks that
	    -- held equipment_oee_daily row locks and stalled the shift rollup).
	    -- COUNTER-ROLE MATRIX via the identity gross = net + scrap (ProdConsumedCount
	    -- = ProdProcessedCount + ProdDefectiveCount). Reconcile whichever pair of the
	    -- three counters a line actually reports, filling the missing one:
	    --   G+N (+/- S): gross+net present ⇒ take both as measured (S ignored), even
	    --                when gross < net (transit / undercounting meter — shown, not fixed).
	    --   N+S  (no G): gross absent, net+scrap present ⇒ gross = net + scrap.
	    --   G+S  (no N): net absent, gross+scrap present ⇒ net = gross - scrap.
	    --   net-only    : only net ⇒ gross = net (quality 1.0, legacy convention).
	    --   gross-only  : only gross ⇒ net = gross (quality 1.0).
	    -- With s=0 (no scrap counter) the CASEs collapse to the pre-scrap G+N /
	    -- net-only logic byte-for-byte. eff_gross/eff_net feed every OEE term below so
	    -- gross, scrap and oee_q stay mutually consistent. (Keep this const free of any
	    -- literal percent sign: it is a fmt.Sprintf format string.)
	    SELECT c.line_id, c.ts_value,
	           -- A MEASURED gross is stored as measured, also when it is below net
	           -- (2026-09-29, "no clamps distorting data"): within an hour that is
	           -- units in transit between the infeed and outfeed sensors, and over a
	           -- shift/day it exposes a meter that undercounts — both are facts the
	           -- data must show, not repair. (Replaces #1472's gross = net + scrap.)
	           -- Only a MISSING meter is filled, per the identity below.
	           CASE WHEN COALESCE(c.gross,0) > 0 THEN COALESCE(c.gross,0)
	                WHEN NOT c.fill_missing THEN 0
	                WHEN COALESCE(c.net,0) > 0 AND COALESCE(c.scrap,0) > 0 THEN COALESCE(c.net,0) + COALESCE(c.scrap,0)
	                WHEN COALESCE(c.net,0) > 0 THEN COALESCE(c.net,0)
	                ELSE 0 END AS eff_gross,
	           CASE WHEN COALESCE(c.net,0) > 0 THEN COALESCE(c.net,0)
	                WHEN NOT c.fill_missing THEN 0
	                WHEN COALESCE(c.gross,0) > 0 AND COALESCE(c.scrap,0) > 0 THEN COALESCE(c.gross,0) - COALESCE(c.scrap,0)
	                WHEN COALESCE(c.gross,0) > 0 THEN COALESCE(c.gross,0)
	                ELSE 0 END AS eff_net
	      FROM counts c
	), prod_raw AS (
	    SELECT l.line_id, l.ts_value, l.bend, m.ts_value AS mts, m.is_lead
	      FROM lines l
	      CROSS JOIN LATERAL (
	          -- #259 FIX: OFFSET 0 is an optimizer fence forcing PER-LINE correlated
	          -- execution, so id_equipment is a runtime constant and the real-time cagg's
	          -- raw scan uses the (id_equipment, ts_value) index. Without it the planner
	          -- decorrelates this into a hash join that materializes the WHOLE real-time
	          -- 1min aggregation of ALL machines (~1000x blowup → 300s tick rollback →
	          -- OEE stall). Result-identical to the prior JOIN (parity-proven).
	          -- Candidate productive minutes from the lead AND the line's gross/net
	          -- machines (same id for single-machine lines ⇒ same rows as before).
	          SELECT mm.ts_value, (mm.id_equipment = l.lead_id) AS is_lead
	            FROM %[3]s.equipment_categorical_1min mm
	           WHERE mm.id_equipment IN (l.lead_id, l.gross_id, l.net_id)
	             AND mm.ts_value >= l.ts_value AND mm.ts_value < l.bend
	             -- A minute is "productive" if the lead moved EITHER input (gross) or
	             -- output (net). A split-instrumentation line's lead is the net/output
	             -- machine and is NET-ONLY (gross=0), so a gross-only filter misses all
	             -- its activity → oee_a=0. For single-lead leads gross and net move
	             -- together, so this is equivalent (no change to working lines).
	             AND (mm.gross_production_incr > 0 OR mm.net_production_incr > 0 OR mm.scrap_incr > 0)
	           OFFSET 0
	      ) m
	), prod_sel AS (
	    -- LEAD-SILENT FALLBACK (2026-09-29). Running time follows the LEAD machine,
	    -- but when the lead has NO productive minute in an hour while the line's
	    -- gross/net machine is counting, the lead is dark (not the line stopped):
	    -- CPACK L5's lead BREYER published nothing real 09-15..09-23 while TEXA
	    -- counted ~600k → 18 shifts with production and running_time = 0. In such
	    -- hours only, the gross/net machines' productive minutes stand in. Hours
	    -- where the lead is active use the lead alone, exactly as before.
	    SELECT DISTINCT line_id, ts_value, bend, mts
	      FROM (SELECT p.*, bool_or(p.is_lead) OVER (
	                   PARTITION BY p.line_id, p.ts_value, date_trunc('hour', p.mts)) AS lead_hour
	              FROM prod_raw p) z
	     WHERE z.is_lead OR NOT z.lead_hour
	), prod_min AS (
	    SELECT line_id, ts_value, bend, mts,
	           extract(epoch FROM (mts - lag(mts) OVER (
	               PARTITION BY line_id, ts_value ORDER BY mts))) AS gap
	      FROM prod_sel
	), islanded AS (
	    SELECT line_id, ts_value, bend, mts,
	           sum(CASE WHEN gap IS NULL OR gap > %[7]d THEN 1 ELSE 0 END)
	               OVER (PARTITION BY line_id, ts_value ORDER BY mts) AS island
	      FROM prod_min
	), sessions AS (
	    SELECT line_id, ts_value,
	           extract(epoch FROM (LEAST(max(mts) + make_interval(secs => %[7]d), min(bend)) - min(mts))) AS span
	      FROM islanded
	     GROUP BY line_id, ts_value, island
	), active AS MATERIALIZED (
	    SELECT line_id, ts_value, sum(span) AS raw_running
	      FROM sessions GROUP BY line_id, ts_value
	)
	-- PLANNED DOWNTIME (regression fix 2026-09-28). This pass is the single writer
	-- of a line-lead row and used to hard-code planned_downtime = 0 and
	-- available_time = the whole bucket, discarding the planned stops the events
	-- step had just classified. Since CPACK moved onto line-lead (~2026-08-31)
	-- every planned stop counted as downtime and line OEE ran 10-50 pct low vs
	-- legacy. Planned time is the overlap of the LINE's planned events with the
	-- bucket. An event lasts until the NEXT event starts (legacy semantics);
	-- ts_end is only a fallback because the closer can truncate it.
	-- The event IN EFFECT at the scan bound is always included (see
	-- eventsInEffectSQL): an idle line's planned stop that began weeks before
	-- the batch still covers this bucket.
	, planned_ev AS MATERIALIZED (
	    SELECT ee.id_equipment, ee.ts_event, ee.ts_eff_end
	      FROM (
	        SELECT x.id_equipment, x.ts_event, x.planned_downtime, x.change_over,
	               LEAST(COALESCE(lead(x.ts_event) OVER (PARTITION BY x.id_equipment ORDER BY x.ts_event),
	                              x.ts_end, now()), now()) AS ts_eff_end
	          FROM ` + eventsInEffectSQL("%[1]s", "SELECT DISTINCT line_id FROM lines",
	"(SELECT min(ts_value) FROM lines) - interval '10 days'") + ` x
	      ) ee
	     WHERE ` + plannedPredToken + `
	), planned AS (
	    SELECT l.line_id, l.ts_value,
	           LEAST(COALESCE(sum(extract(epoch FROM (LEAST(p.ts_eff_end, l.bend) - GREATEST(p.ts_event, l.ts_value)))), 0), l.ts_total) AS ts_planned
	      FROM lines l
	      JOIN planned_ev p ON p.id_equipment = l.line_id AND p.ts_event < l.bend AND p.ts_eff_end > l.ts_value
	     GROUP BY l.line_id, l.ts_value, l.ts_total
	), lines_p AS (
	    -- ts_avail = planned production time (bucket minus planned stops): the
	    -- Availability denominator and the ideal-production basis, as in legacy.
	    SELECT l.*, COALESCE(p.ts_planned, 0) AS ts_planned,
	           l.ts_total - COALESCE(p.ts_planned, 0) AS ts_avail
	      FROM lines l
	      LEFT JOIN planned p ON p.line_id = l.line_id AND p.ts_value = l.ts_value
	)

	UPDATE %[4]s.equipment_oee_hourly e SET
	       gross            = COALESCE(r.eff_gross, 0),
	       net              = COALESCE(r.eff_net, 0),
	       scrap            = COALESCE(r.eff_gross, 0) - COALESCE(r.eff_net, 0),  -- signed: negative = transit
	       available_time   = l.ts_avail,
	       running_time     = LEAST(COALESCE(a.raw_running, 0), l.ts_avail),
	       stopped_time     = l.ts_avail - LEAST(COALESCE(a.raw_running, 0), l.ts_avail),
	       planned_downtime = l.ts_planned,
	       downtime         = l.ts_avail - LEAST(COALESCE(a.raw_running, 0), l.ts_avail),
	       changeover_time  = 0,
	       ideal_speed      = COALESCE(l.lead_ideal, e.ideal_speed, 0),
	       ideal_production = COALESCE((l.ts_avail / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0),
	       recalc_needed    = false,
	       -- UNCAPPED since 2026-09-29 (see shiftLineLeadSQL). oee_p is left to
	       -- hourOeePSQL off the just-cleared rows.
	       oee   = GREATEST(COALESCE(COALESCE(r.eff_net,0) / NULLIF((l.ts_avail / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0), 0), 0),
	       oee_a = GREATEST(LEAST(COALESCE(LEAST(COALESCE(a.raw_running, 0), l.ts_avail) / NULLIF(l.ts_avail, 0), 0), 1), 0),
	       oee_q = GREATEST(COALESCE(COALESCE(r.eff_net,0) / NULLIF(r.eff_gross, 0), 0), 0)
	  FROM lines_p l
	  LEFT JOIN reconciled r ON r.line_id = l.line_id AND r.ts_value = l.ts_value
	  LEFT JOIN active a ON a.line_id = l.line_id AND a.ts_value = l.ts_value
	 WHERE e.id_equipment = l.line_id AND e.ts_value = l.ts_value
	   -- NO recalc_needed guard (mirrors shiftLineLeadSQL): this pass is the SINGLE
	   -- WRITER of a line-lead line's row. The events step runs first and clears
	   -- recalc_needed on every row with an overlapping event; once lines carry their
	   -- own events (lead-machine attribution, since ~2026-09-05) a 'recalc_needed =
	   -- true' guard skipped every CLOSED hour → net stayed at the values step's 0
	   -- (the line has no counters) while the open hour looked right. Hourly line net
	   -- ran ~40 pct below the shift grain. Scope is still hour_elig (the tick's batch).
	   AND e.ts_value >= now() - interval '6 hour'`

// Test/parity accessors — single-source emission. Deliberately NOT part of the
// Shift/Hour *ForParity sets (those diff against the prod engine, which has no
// line-from-lead pass). The golden test drives these against a hand-built
// line-metered fixture.
// The parity/golden accessors keep their historical contract — %[6]s is the
// enterprise array LITERAL — by re-expanding the scope placeholder to the
// enterprise-only predicate (exactly the pre-override text).
func ShiftLineLeadSQLForParity() string { return entOnlyScope(withPlannedPred(shiftLineLeadSQL, false)) }
func HourLineLeadSQLForParity() string  { return entOnlyScope(withPlannedPred(hourLineLeadSQL, false)) }

func entOnlyScope(sql string) string {
	return strings.Replace(sql, "AND %[6]s", "AND eq.id_enterprise = ANY(%[6]s)", 1)
}

// eventsInEffectSQL returns a parenthesized row source over <evSchema>.equipment_events
// (columns id_equipment, ts_event, ts_end, status, planned_downtime, change_over) for
// the equipments `ids` selects (one column), holding:
//
//   - every event with ts_event in [bound, now())  — the bounded range scan, and
//   - PER EQUIPMENT, the latest event with ts_event < bound — the event IN EFFECT at
//     the bound.
//
// WHY (2026-09-29). Events are open-ended state markers: one lasts until the NEXT
// event starts. The passes used to scan only [bound, now()), so a stop that STARTED
// before the bound and was still running at the bucket was silently dropped — the
// bucket read as having no event at all. CPACK: DUBUIT1 idle (planned) since 07-27
// and DUBUIT2 08-01→09-21 were booked as unplanned downtime; SLEEVE2's planned stop
// from 08-23 disappeared from its shifts exactly 10 days after it began. Adding the
// one event in effect at the bound restores it; lead(ts_event) over the union still
// closes that event at the first in-range event, so ts_eff_end is unchanged for every
// other event.
//
// INDEX-FRIENDLY: the seed is a per-equipment LATERAL ORDER BY ts_event DESC LIMIT 1
// on the (id_equipment, ts_event) primary key — one backward index probe per
// equipment (TimescaleDB ordered-append walks chunks newest-first and stops at the
// first hit). The two halves are disjoint (< bound vs >= bound), so UNION ALL is exact.
// The range half keeps alias `ee` and its original predicate text.
func eventsInEffectSQL(evSchema, ids, bound string) string {
	return `(
	        SELECT ee.id_equipment, ee.ts_event, ee.ts_end, ee.status, ee.planned_downtime, ee.change_over
	          FROM ` + evSchema + `.equipment_events ee
	         WHERE ee.id_equipment IN (` + ids + `)
	           AND ee.ts_event >= ` + bound + ` AND ee.ts_event < now()
	        UNION ALL
	        SELECT s.id_equipment, s.ts_event, s.ts_end, s.status, s.planned_downtime, s.change_over
	          FROM (` + ids + `) AS q (id_equipment)
	          CROSS JOIN LATERAL (
	              SELECT p.id_equipment, p.ts_event, p.ts_end, p.status, p.planned_downtime, p.change_over
	                FROM ` + evSchema + `.equipment_events p
	               WHERE p.id_equipment = q.id_equipment
	                 AND p.ts_event < ` + bound + `
	               ORDER BY p.ts_event DESC
	               LIMIT 1) s
	      )`
}

// plannedPredToken marks where the planned-downtime classification predicate
// goes (plannedDowntimeExpr, flag-dependent). A text token rather than a new
// fmt verb so every caller keeps its argument list.
const plannedPredToken = "/*PLANNED_PRED*/"

func withPlannedPred(sql string, changeoverAvailability bool) string {
	return strings.Replace(sql, plannedPredToken, plannedDowntimeExpr(changeoverAvailability), 1)
}
