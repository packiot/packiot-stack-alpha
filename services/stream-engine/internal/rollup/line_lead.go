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
//   - gross / net / scrap ← sum of ca_agg_equipment_values_1hour buckets over the
//     grain window (the same _1hour cagg the machine grain sums). By default all
//     three come from lead_machine. A SPLIT-INSTRUMENTATION line puts its counters
//     on DIFFERENT machines: equipments.gross_machine names the gross/input source
//     and equipments.scrap_machine the scrap/defect source, while lead_machine stays
//     the net/output + availability source. When gross_machine/scrap_machine are
//     NULL, gross_id COALESCEs to lead_id and scrap_id is NULL (⇒ 0), so behaviour
//     is byte-identical to the single-lead pass.
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
//     ca_agg_equipment_values_1min productive minutes (identical inference to
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

// shiftLineLeadSQL — %[1]s=EvSchema, %[2]s=RefSchema, %[3]s=enterprise bigint[] literal, %[4]d=idle timeout secs.
const shiftLineLeadSQL = `
	WITH lines AS (
	    SELECT el.id_equipment AS line_id, el.ts_value,
	           LEAST(el.ts_end, now()) AS bend,
	           extract(epoch FROM (LEAST(el.ts_end, now()) - el.ts_value)) AS ts_total,
	           eq.lead_machine AS lead_id,
	           -- SPLIT-INSTRUMENTATION: gross may live on a different machine than
	           -- net. gross_machine names the input/gross source; NULL ⇒ single-lead
	           -- (gross_id == lead_id) so the COALESCE is a no-op for legacy lines.
	           COALESCE(eq.gross_machine, eq.lead_machine) AS gross_id,
	           -- SCRAP source. scrap_machine names the machine whose ProdDefectiveCount
	           -- is this line's scrap/defect source. NULL (the default) ⇒ no scrap
	           -- counter ⇒ the scrap subquery returns NULL ⇒ s=0, so the reconciliation
	           -- CASEs reduce to the pre-scrap G+N / net-only behaviour byte-for-byte.
	           eq.scrap_machine AS scrap_id,
	           (SELECT q.production_speed FROM %[2]s.equipments q WHERE q.id_equipment = eq.lead_machine) AS lead_ideal
	      FROM shift_elig el
	      JOIN %[2]s.equipments eq ON eq.id_equipment = el.id_equipment
	     WHERE eq.tp_equipment = 3 AND COALESCE(eq.lead_machine,0) > 0
	       AND eq.id_enterprise = ANY(%[3]s)
	       AND el.ts_value >= now() - interval '2 days'
	), counts AS (
	    -- Raw per-source sums: GROSS from gross_id (input machine), NET from lead_id
	    -- (output machine), SCRAP from scrap_id (defect machine). Correlated subqueries
	    -- so each factor draws from its own source; few lines, so the lookups are cheap.
	    -- A NULL source id ⇒ no matching rows ⇒ NULL sum ⇒ 0 downstream.
	    SELECT l.line_id, l.ts_value,
	           (SELECT sum(cg.gross_production_incr) FROM %[1]s.ca_agg_equipment_values_1hour cg
	             WHERE cg.id_equipment = l.gross_id
	               AND cg.ts_value >= l.ts_value AND cg.ts_value < l.bend) AS gross,
	           (SELECT sum(cn.net_production_incr) FROM %[1]s.ca_agg_equipment_values_1hour cn
	             WHERE cn.id_equipment = l.lead_id
	               AND cn.ts_value >= l.ts_value AND cn.ts_value < l.bend) AS net,
	           (SELECT sum(cs.scrap_incr) FROM %[1]s.ca_agg_equipment_values_1hour cs
	             WHERE cs.id_equipment = l.scrap_id
	               AND cs.ts_value >= l.ts_value AND cs.ts_value < l.bend) AS scrap
	      FROM lines l
	), reconciled AS (
	    -- COUNTER-ROLE MATRIX via the identity gross = net + scrap (ProdConsumedCount
	    -- = ProdProcessedCount + ProdDefectiveCount). Reconcile whichever pair of the
	    -- three counters a line actually reports, filling the missing one:
	    --   G+N (+/- S): gross+net present ⇒ take both as-is (S ignored, kept exact).
	    --   N+S  (no G): gross absent, net+scrap present ⇒ gross = net + scrap.
	    --   G+S  (no N): net absent, gross+scrap present ⇒ net = gross - scrap.
	    --   net-only    : only net ⇒ gross = net (quality 1.0, legacy convention).
	    --   gross-only  : only gross ⇒ net = gross (quality 1.0).
	    -- With s=0 (no scrap counter) the CASEs collapse to the pre-scrap G+N /
	    -- net-only logic byte-for-byte. eff_gross/eff_net feed every OEE term below so
	    -- gross, scrap and oee_q stay mutually consistent. (Keep this const free of any
	    -- literal percent sign: it is a fmt.Sprintf format string.)
	    SELECT c.line_id, c.ts_value,
	           CASE WHEN COALESCE(c.gross,0) > 0 THEN COALESCE(c.gross,0)
	                WHEN COALESCE(c.net,0) > 0 AND COALESCE(c.scrap,0) > 0 THEN COALESCE(c.net,0) + COALESCE(c.scrap,0)
	                WHEN COALESCE(c.net,0) > 0 THEN COALESCE(c.net,0)
	                ELSE 0 END AS eff_gross,
	           CASE WHEN COALESCE(c.net,0) > 0 THEN COALESCE(c.net,0)
	                WHEN COALESCE(c.gross,0) > 0 AND COALESCE(c.scrap,0) > 0 THEN COALESCE(c.gross,0) - COALESCE(c.scrap,0)
	                WHEN COALESCE(c.gross,0) > 0 THEN COALESCE(c.gross,0)
	                ELSE 0 END AS eff_net
	      FROM counts c
	), prod_min AS (
	    SELECT l.line_id, l.ts_value, l.bend, m.ts_value AS mts,
	           extract(epoch FROM (m.ts_value - lag(m.ts_value) OVER (
	               PARTITION BY l.line_id, l.ts_value ORDER BY m.ts_value))) AS gap
	      FROM lines l
	      JOIN %[1]s.ca_agg_equipment_values_1min m
	        ON m.id_equipment = l.lead_id
	       AND m.ts_value >= l.ts_value AND m.ts_value < l.bend
	       -- A minute is "productive" if the lead moved EITHER input (gross) or
	       -- output (net). A split-instrumentation line's lead is the net/output
	       -- machine and is NET-ONLY (gross=0), so a gross-only filter misses all
	       -- its activity → oee_a=0. For single-lead leads gross and net move
	       -- together, so this is equivalent (no change to working lines).
	       AND (m.gross_production_incr > 0 OR m.net_production_incr > 0 OR m.scrap_incr > 0)
	), islanded AS (
	    SELECT line_id, ts_value, bend, mts,
	           sum(CASE WHEN gap IS NULL OR gap > %[4]d THEN 1 ELSE 0 END)
	               OVER (PARTITION BY line_id, ts_value ORDER BY mts) AS island
	      FROM prod_min
	), sessions AS (
	    SELECT line_id, ts_value,
	           extract(epoch FROM (LEAST(max(mts) + make_interval(secs => %[4]d), min(bend)) - min(mts))) AS span
	      FROM islanded
	     GROUP BY line_id, ts_value, island
	), active AS (
	    SELECT line_id, ts_value, sum(span) AS raw_running
	      FROM sessions GROUP BY line_id, ts_value
	)
	UPDATE %[1]s.equipment_runtime_shift e SET
	       gross            = COALESCE(r.eff_gross, 0),
	       net              = COALESCE(r.eff_net, 0),
	       scrap            = GREATEST(COALESCE(r.eff_gross, 0) - COALESCE(r.eff_net, 0), 0),
	       available_time   = l.ts_total,
	       running_time     = LEAST(COALESCE(a.raw_running, 0), l.ts_total),
	       stopped_time     = l.ts_total - LEAST(COALESCE(a.raw_running, 0), l.ts_total),
	       planned_downtime = 0,
	       downtime         = l.ts_total - LEAST(COALESCE(a.raw_running, 0), l.ts_total),
	       changeover_time  = 0,
	       ideal_speed      = COALESCE(l.lead_ideal, e.ideal_speed, 0),
	       ideal_production = COALESCE((l.ts_total / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0),
	       recalc_needed    = false,
	       -- ADR-0037 *_oee_bounds clamp (#663): counter-only line throughput can
	       -- exceed the rated-speed estimate, so net/ideal (and the back-solved
	       -- oee_p) can top 1 and violate the BETWEEN 0 AND 1 CHECK. Clamp each
	       -- served factor; no-op on in-range data.
	       oee   = GREATEST(LEAST(COALESCE(COALESCE(r.eff_net,0) / NULLIF((l.ts_total / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0), 0), 1), 0),
	       oee_a = GREATEST(LEAST(COALESCE(LEAST(COALESCE(a.raw_running, 0), l.ts_total) / NULLIF(l.ts_total, 0), 0), 1), 0),
	       oee_q = GREATEST(LEAST(COALESCE(COALESCE(r.eff_net,0) / NULLIF(r.eff_gross, 0), 0), 1), 0),
	       oee_p = GREATEST(LEAST(COALESCE(
	             COALESCE(COALESCE(r.eff_net,0) / NULLIF((l.ts_total / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0), 0)
	             / NULLIF(
	                 COALESCE(LEAST(COALESCE(a.raw_running, 0), l.ts_total) / NULLIF(l.ts_total, 0), 0)
	                 * COALESCE(COALESCE(r.eff_net,0) / NULLIF(r.eff_gross, 0), 0), 0), 0), 1), 0)
	  FROM lines l
	  LEFT JOIN reconciled r ON r.line_id = l.line_id AND r.ts_value = l.ts_value
	  LEFT JOIN active a ON a.line_id = l.line_id AND a.ts_value = l.ts_value
	 WHERE e.id_equipment = l.line_id AND e.ts_value = l.ts_value
	   AND e.ts_value >= now() - interval '25 day'`

// hourLineLeadSQL — %[1]s=EvSchema, %[2]s=RefSchema, %[3]s=enterprise bigint[] literal, %[4]d=idle timeout secs.
// Leaves oee_p to hourOeePSQL (runs next off the just-cleared rows), matching hourCountsAvailSQL.
const hourLineLeadSQL = `
	WITH lines AS (
	    SELECT el.id_equipment AS line_id, el.ts_value,
	           LEAST(el.ts_value + interval '1 hour', now()) AS bend,
	           extract(epoch FROM (LEAST(el.ts_value + interval '1 hour', now()) - el.ts_value)) AS ts_total,
	           eq.lead_machine AS lead_id,
	           -- SPLIT-INSTRUMENTATION: gross may live on a different machine than
	           -- net. gross_machine names the input/gross source; NULL ⇒ single-lead
	           -- (gross_id == lead_id) so the COALESCE is a no-op for legacy lines.
	           COALESCE(eq.gross_machine, eq.lead_machine) AS gross_id,
	           -- SCRAP source. scrap_machine names the machine whose ProdDefectiveCount
	           -- is this line's scrap/defect source. NULL (the default) ⇒ no scrap
	           -- counter ⇒ the scrap subquery returns NULL ⇒ s=0, so the reconciliation
	           -- CASEs reduce to the pre-scrap G+N / net-only behaviour byte-for-byte.
	           eq.scrap_machine AS scrap_id,
	           (SELECT q.production_speed FROM %[2]s.equipments q WHERE q.id_equipment = eq.lead_machine) AS lead_ideal
	      FROM hour_elig el
	      JOIN %[2]s.equipments eq ON eq.id_equipment = el.id_equipment
	     WHERE eq.tp_equipment = 3 AND COALESCE(eq.lead_machine,0) > 0
	       AND eq.id_enterprise = ANY(%[3]s)
	), counts AS (
	    -- Raw per-source sums: GROSS from gross_id (input machine), NET from lead_id
	    -- (output machine), SCRAP from scrap_id (defect machine). Single-bucket lookups
	    -- matching the hour join (ts_value = l.ts_value). A NULL source id ⇒ no matching
	    -- rows ⇒ NULL sum ⇒ 0 downstream.
	    SELECT l.line_id, l.ts_value,
	           (SELECT sum(cg.gross_production_incr) FROM %[1]s.ca_agg_equipment_values_1hour cg
	             WHERE cg.id_equipment = l.gross_id AND cg.ts_value = l.ts_value) AS gross,
	           (SELECT sum(cn.net_production_incr) FROM %[1]s.ca_agg_equipment_values_1hour cn
	             WHERE cn.id_equipment = l.lead_id AND cn.ts_value = l.ts_value) AS net,
	           (SELECT sum(cs.scrap_incr) FROM %[1]s.ca_agg_equipment_values_1hour cs
	             WHERE cs.id_equipment = l.scrap_id AND cs.ts_value = l.ts_value) AS scrap
	      FROM lines l
	), reconciled AS (
	    -- COUNTER-ROLE MATRIX via the identity gross = net + scrap (ProdConsumedCount
	    -- = ProdProcessedCount + ProdDefectiveCount). Reconcile whichever pair of the
	    -- three counters a line actually reports, filling the missing one:
	    --   G+N (+/- S): gross+net present ⇒ take both as-is (S ignored, kept exact).
	    --   N+S  (no G): gross absent, net+scrap present ⇒ gross = net + scrap.
	    --   G+S  (no N): net absent, gross+scrap present ⇒ net = gross - scrap.
	    --   net-only    : only net ⇒ gross = net (quality 1.0, legacy convention).
	    --   gross-only  : only gross ⇒ net = gross (quality 1.0).
	    -- With s=0 (no scrap counter) the CASEs collapse to the pre-scrap G+N /
	    -- net-only logic byte-for-byte. eff_gross/eff_net feed every OEE term below so
	    -- gross, scrap and oee_q stay mutually consistent. (Keep this const free of any
	    -- literal percent sign: it is a fmt.Sprintf format string.)
	    SELECT c.line_id, c.ts_value,
	           CASE WHEN COALESCE(c.gross,0) > 0 THEN COALESCE(c.gross,0)
	                WHEN COALESCE(c.net,0) > 0 AND COALESCE(c.scrap,0) > 0 THEN COALESCE(c.net,0) + COALESCE(c.scrap,0)
	                WHEN COALESCE(c.net,0) > 0 THEN COALESCE(c.net,0)
	                ELSE 0 END AS eff_gross,
	           CASE WHEN COALESCE(c.net,0) > 0 THEN COALESCE(c.net,0)
	                WHEN COALESCE(c.gross,0) > 0 AND COALESCE(c.scrap,0) > 0 THEN COALESCE(c.gross,0) - COALESCE(c.scrap,0)
	                WHEN COALESCE(c.gross,0) > 0 THEN COALESCE(c.gross,0)
	                ELSE 0 END AS eff_net
	      FROM counts c
	), prod_min AS (
	    SELECT l.line_id, l.ts_value, l.bend, m.ts_value AS mts,
	           extract(epoch FROM (m.ts_value - lag(m.ts_value) OVER (
	               PARTITION BY l.line_id, l.ts_value ORDER BY m.ts_value))) AS gap
	      FROM lines l
	      JOIN %[1]s.ca_agg_equipment_values_1min m
	        ON m.id_equipment = l.lead_id
	       AND m.ts_value >= l.ts_value AND m.ts_value < l.bend
	       -- A minute is "productive" if the lead moved EITHER input (gross) or
	       -- output (net). A split-instrumentation line's lead is the net/output
	       -- machine and is NET-ONLY (gross=0), so a gross-only filter misses all
	       -- its activity → oee_a=0. For single-lead leads gross and net move
	       -- together, so this is equivalent (no change to working lines).
	       AND (m.gross_production_incr > 0 OR m.net_production_incr > 0 OR m.scrap_incr > 0)
	), islanded AS (
	    SELECT line_id, ts_value, bend, mts,
	           sum(CASE WHEN gap IS NULL OR gap > %[4]d THEN 1 ELSE 0 END)
	               OVER (PARTITION BY line_id, ts_value ORDER BY mts) AS island
	      FROM prod_min
	), sessions AS (
	    SELECT line_id, ts_value,
	           extract(epoch FROM (LEAST(max(mts) + make_interval(secs => %[4]d), min(bend)) - min(mts))) AS span
	      FROM islanded
	     GROUP BY line_id, ts_value, island
	), active AS (
	    SELECT line_id, ts_value, sum(span) AS raw_running
	      FROM sessions GROUP BY line_id, ts_value
	)
	UPDATE %[1]s.equipment_runtime_1hour e SET
	       gross            = COALESCE(r.eff_gross, 0),
	       net              = COALESCE(r.eff_net, 0),
	       scrap            = GREATEST(COALESCE(r.eff_gross, 0) - COALESCE(r.eff_net, 0), 0),
	       available_time   = l.ts_total,
	       running_time     = LEAST(COALESCE(a.raw_running, 0), l.ts_total),
	       stopped_time     = l.ts_total - LEAST(COALESCE(a.raw_running, 0), l.ts_total),
	       planned_downtime = 0,
	       downtime         = l.ts_total - LEAST(COALESCE(a.raw_running, 0), l.ts_total),
	       changeover_time  = 0,
	       ideal_speed      = COALESCE(l.lead_ideal, e.ideal_speed, 0),
	       ideal_production = COALESCE((l.ts_total / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0),
	       recalc_needed    = false,
	       -- ADR-0037 *_oee_bounds clamp (#663): counter-only line throughput can
	       -- exceed the rated-speed estimate → net/ideal > 1 violates the CHECK.
	       -- Clamp each served factor; no-op on in-range data. oee_p is left to
	       -- hourOeePSQL (itself clamped) off the just-cleared rows.
	       oee   = GREATEST(LEAST(COALESCE(COALESCE(r.eff_net,0) / NULLIF((l.ts_total / 60.0) * NULLIF(COALESCE(l.lead_ideal, e.ideal_speed), 0), 0), 0), 1), 0),
	       oee_a = GREATEST(LEAST(COALESCE(LEAST(COALESCE(a.raw_running, 0), l.ts_total) / NULLIF(l.ts_total, 0), 0), 1), 0),
	       oee_q = GREATEST(LEAST(COALESCE(COALESCE(r.eff_net,0) / NULLIF(r.eff_gross, 0), 0), 1), 0)
	  FROM lines l
	  LEFT JOIN reconciled r ON r.line_id = l.line_id AND r.ts_value = l.ts_value
	  LEFT JOIN active a ON a.line_id = l.line_id AND a.ts_value = l.ts_value
	 WHERE e.id_equipment = l.line_id AND e.ts_value = l.ts_value
	   AND e.recalc_needed = true
	   AND e.ts_value >= now() - interval '6 hour'`

// Test/parity accessors — single-source emission. Deliberately NOT part of the
// Shift/Hour *ForParity sets (those diff against the prod engine, which has no
// line-from-lead pass). The golden test drives these against a hand-built
// line-metered fixture.
func ShiftLineLeadSQLForParity() string { return shiftLineLeadSQL }
func HourLineLeadSQLForParity() string  { return hourLineLeadSQL }
