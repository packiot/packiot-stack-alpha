package rollup

import "strings"

// AVAILABILITY EXCLUSIONS (2026-10-01, availability three-state policy).
//
// Time a line could not be judged is not "stopped":
//   - OUT OF SERVICE — a CS/customer window (config.equipment_out_of_service) on
//     the equipment or any ancestor (a line's window covers its machines). Not
//     planned production time: excluded from available_time AND from the target.
//   - NO DATA — the PLC could not be read (status-20 equipment_events written by
//     the link-aware stop deriver; a LINE reads its lead machine's). Excluded
//     from available_time (so it neither credits nor debits Availability) but
//     KEPT in the target (the line was still expected to produce — we only lost
//     sight of it) and SHOWN as no_data_time so coverage can be displayed.
//
// One step per grain, appended AFTER every available_time writer (events,
// counters-avail, line-lead, avail-floor) and BEFORE the OEE finalize, so the
// five writers stay untouched (no #456 multi-writer drift) and the finalize
// reads the excluded denominator. IDEMPOTENT by construction: available_time is
// recomputed from the bucket length and the row's planned_downtime (every writer
// keeps available = total − planned), never decremented from its current value,
// so a row the writers skipped this tick is not excluded twice.
//
//	excl     = |(out_of_service ∪ no_data) − planned| within the bucket (multiranges)
//	available = max(total − planned − excl, running)   -- measured running is never erased
//	stopped  ≤ available − running ; downtime ≤ total − excl − running
//	ideal_production keeps its rate per available second
//
// Rows with nothing excluded (now or before) are not touched: inert for every
// tenant without out-of-service windows or link-health no-data events.

// exclusionsCore renders the shared CTEs for one grain. %[1]s = EvSchema,
// %[2]s = RefSchema, %[6]s = ConfigSchema; ELIG / BUCKET are grain-specific.
const exclusionsCore = `
	WITH rows AS (
	    SELECT el.id_equipment, el.ts_value, BUCKET AS b
	      FROM ELIG el
	     WHERE el.ts_value < now()
	), m AS (
	    SELECT r.id_equipment, r.ts_value, r.b,
	           CASE WHEN e.tp_equipment = 3 AND COALESCE(e.lead_machine, 0) > 0
	                THEN e.lead_machine ELSE e.id_equipment END AS nd_src,
	           ARRAY[e.id_equipment, COALESCE(e.id_parentequipment, 0), COALESCE(pe.id_parentequipment, 0)] AS anc
	      FROM rows r
	      JOIN %[2]s.equipments e ON e.id_equipment = r.id_equipment
	      LEFT JOIN %[2]s.equipments pe ON pe.id_equipment = e.id_parentequipment
	     WHERE NOT isempty(r.b)
	), x AS (
	    SELECT m.id_equipment, m.ts_value, m.b,
	           COALESCE((SELECT range_agg(o.period * m.b)
	                       FROM %[6]s.equipment_out_of_service o
	                      WHERE o.id_equipment = ANY (m.anc) AND o.period && m.b),
	                    '{}'::tstzmultirange) AS oos,
	           -- events are open-ended transition markers: an event ends at ts_end,
	           -- else at the next event of the same equipment, else now()
	           COALESCE((SELECT range_agg(tstzrange(ev.ts_event, COALESCE(ev.ts_end, nx.ts_next, now())) * m.b)
	                       FROM %[1]s.equipment_events ev
	                       LEFT JOIN LATERAL (SELECT min(n.ts_event) AS ts_next
	                                            FROM %[1]s.equipment_events n
	                                           WHERE n.id_equipment = ev.id_equipment
	                                             AND n.ts_event > ev.ts_event
	                                             AND n.ts_event < upper(m.b) + interval '60 days') nx ON true
	                      WHERE ev.id_equipment = m.nd_src AND ev.status = 20
	                        AND ev.ts_event < upper(m.b)
	                        AND ev.ts_event >= lower(m.b) - interval '60 days'
	                        AND COALESCE(ev.ts_end, nx.ts_next, now()) > lower(m.b)),
	                    '{}'::tstzmultirange) AS nd,
	           COALESCE((SELECT range_agg(tstzrange(ev.ts_event, COALESCE(ev.ts_end, nx.ts_next, now())) * m.b)
	                       FROM %[1]s.equipment_events ev
	                       LEFT JOIN LATERAL (SELECT min(n.ts_event) AS ts_next
	                                            FROM %[1]s.equipment_events n
	                                           WHERE n.id_equipment = ev.id_equipment
	                                             AND n.ts_event > ev.ts_event
	                                             AND n.ts_event < upper(m.b) + interval '60 days') nx ON true
	                      WHERE ev.id_equipment = m.id_equipment AND ev.planned_downtime IS TRUE
	                        AND ev.ts_event < upper(m.b)
	                        AND ev.ts_event >= lower(m.b) - interval '60 days'
	                        AND COALESCE(ev.ts_end, nx.ts_next, now()) > lower(m.b)),
	                    '{}'::tstzmultirange) AS pl
	      FROM m
	), y AS (
	    SELECT x.id_equipment, x.ts_value,
	           extract(epoch FROM upper(x.b) - lower(x.b)) AS ts_total,
	           (SELECT COALESCE(sum(extract(epoch FROM upper(r) - lower(r))), 0) FROM unnest((x.oos + x.nd) - x.pl) r) AS excl_s,
	           (SELECT COALESCE(sum(extract(epoch FROM upper(r) - lower(r))), 0) FROM unnest(x.oos) r) AS oos_s,
	           (SELECT COALESCE(sum(extract(epoch FROM upper(r) - lower(r))), 0) FROM unnest(x.nd - x.oos) r) AS nd_s
	      FROM x
	)
	UPDATE %[4]s.TABLE e SET
	       out_of_service_time = round(y.oos_s),
	       no_data_time        = round(y.nd_s),
	       available_time      = round(GREATEST(y.ts_total - LEAST(COALESCE(e.planned_downtime, 0), y.ts_total) - y.excl_s,
	                                            LEAST(COALESCE(e.running_time, 0), y.ts_total))),
	       stopped_time        = LEAST(e.stopped_time, round(GREATEST(
	                                 GREATEST(y.ts_total - LEAST(COALESCE(e.planned_downtime, 0), y.ts_total) - y.excl_s,
	                                          LEAST(COALESCE(e.running_time, 0), y.ts_total))
	                                 - COALESCE(e.running_time, 0), 0))),
	       downtime            = LEAST(e.downtime, round(GREATEST(y.ts_total - y.excl_s - COALESCE(e.running_time, 0), 0))),
	       -- keep the ideal rate per available second (writers set the pair together)
	       ideal_production    = CASE WHEN e.available_time > 0
	                                  THEN e.ideal_production * (round(GREATEST(
	                                       y.ts_total - LEAST(COALESCE(e.planned_downtime, 0), y.ts_total) - y.excl_s,
	                                       LEAST(COALESCE(e.running_time, 0), y.ts_total))) / e.available_time::float)
	                                  ELSE e.ideal_production END
	  FROM y
	 WHERE e.id_equipment = y.id_equipment AND e.ts_value = y.ts_value
	   AND (y.excl_s > 0 OR y.oos_s > 0 OR y.nd_s > 0
	        OR COALESCE(e.out_of_service_time, 0) <> 0 OR COALESCE(e.no_data_time, 0) <> 0)`

var (
	hourExclusionsSQL = strings.NewReplacer(
		"BUCKET", "tstzrange(el.ts_value, LEAST(el.ts_value + interval '1 hour', now()))",
		"ELIG", "hour_elig",
		"TABLE", "equipment_oee_hourly",
	).Replace(exclusionsCore)
	shiftExclusionsSQL = strings.NewReplacer(
		"BUCKET", "tstzrange(el.ts_value, LEAST(el.ts_end, now()))",
		"ELIG", "shift_elig",
		"TABLE", "equipment_oee_shift",
	).Replace(exclusionsCore)
)

// oosTargetToken marks where the targets formula subtracts out-of-service time.
// Rendered empty for the parity accessors (prod has no such column), so their
// text stays byte-identical; the live engine renders the subtraction.
const oosTargetToken = "/*OOS_TARGET*/"

func withOosTarget(sql string, engaged bool, repl string) string {
	if !engaged {
		return strings.Replace(sql, oosTargetToken, "", 1)
	}
	return strings.Replace(sql, oosTargetToken, repl, 1)
}

// Out-of-service time is not planned production time, so it earns no target
// (no-data time keeps its target — see the header).
const (
	hourOosTargetTerm  = " * (1 - LEAST(COALESCE(e.out_of_service_time, 0), 3600) / 3600.0)"
	shiftOosTargetTerm = " - COALESCE(e.out_of_service_time, 0)"
)

// Test accessors.
func HourExclusionsSQLForTest() string  { return hourExclusionsSQL }
func ShiftExclusionsSQLForTest() string { return shiftExclusionsSQL }
