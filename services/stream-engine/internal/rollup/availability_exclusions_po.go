package rollup

import "strings"

// PO-grain availability exclusions (2026-10-01). The PO availability write
// (computeAvailabilitySQL) recomputes available_time from the run's span every
// pass, so the exclusion folds straight into it — no extra step, idempotent by
// construction. A PO's line inherits out-of-service windows on itself or its
// parent and no-data time from its LEAD machine's status-20 events, exactly as
// the hour/shift exclusions step (availability_exclusions.go):
//
//	available = max(total − planned − |(oos ∪ no data) − planned|, 0)
//
// Off ⇒ every token renders empty ⇒ the exact pre-exclusion statement.
func withPOExclusions(sql string, engaged bool, configSchema string) string {
	if !engaged {
		return strings.NewReplacer("/*EXCL_ELIG*/", "", "/*EXCL_SEL*/", "", "/*EXCL_JOIN*/", "",
			"/*EXCL_TERM*/", "", "/*EXCL_SET*/", "").Replace(sql)
	}
	join := strings.ReplaceAll(poExclJoin, "CFGSCHEMA", configSchema)
	return strings.NewReplacer(
		"/*EXCL_ELIG*/", `,
	           CASE WHEN COALESCE(eq.lead_machine, 0) > 0 THEN eq.lead_machine ELSE e.id_equipment END AS nd_src,
	           ARRAY[e.id_equipment, COALESCE(eq.id_parentequipment, 0)] AS anc`,
		"/*EXCL_SEL*/", `, xx.excl, xx.oos, xx.nd`,
		"/*EXCL_JOIN*/", join,
		"/*EXCL_TERM*/", ` - ev.excl`,
		"/*EXCL_SET*/", `,
	       no_data_time        = round(ev.nd)::int,
	       out_of_service_time = round(ev.oos)::int`,
	).Replace(sql)
}

// poExclJoin — per-PO excluded seconds within [lo, hi). Planned intervals reuse
// the availability predicate (%[6]s over alias ee) on ev_src, like x.planned.
const poExclJoin = `
	      CROSS JOIN LATERAL (
	          SELECT (SELECT COALESCE(sum(extract(epoch FROM upper(r) - lower(r))), 0) FROM unnest((m.oos + m.nd) - m.pl) r) AS excl,
	                 (SELECT COALESCE(sum(extract(epoch FROM upper(r) - lower(r))), 0) FROM unnest(m.oos) r) AS oos,
	                 (SELECT COALESCE(sum(extract(epoch FROM upper(r) - lower(r))), 0) FROM unnest(m.nd - m.oos) r) AS nd
	            FROM (SELECT
	                COALESCE((SELECT range_agg(o.period * tstzrange(el.lo, el.hi))
	                            FROM CFGSCHEMA.equipment_out_of_service o
	                           WHERE o.id_equipment = ANY (el.anc) AND o.period && tstzrange(el.lo, el.hi)),
	                         '{}'::tstzmultirange) AS oos,
	                COALESCE((SELECT range_agg(tstzrange(ee.ts_event, COALESCE(ee.ts_end, nx.ts_next, now())) * tstzrange(el.lo, el.hi))
	                            FROM %[3]s.equipment_events ee
	                            LEFT JOIN LATERAL (SELECT min(n.ts_event) AS ts_next FROM %[3]s.equipment_events n
	                                                WHERE n.id_equipment = ee.id_equipment AND n.ts_event > ee.ts_event
	                                                  AND n.ts_event < el.hi + interval '60 days') nx ON true
	                           WHERE ee.id_equipment = el.nd_src AND ee.status = 20
	                             AND ee.ts_event < el.hi AND ee.ts_event >= el.lo - interval '60 days'
	                             AND COALESCE(ee.ts_end, nx.ts_next, now()) > el.lo),
	                         '{}'::tstzmultirange) AS nd,
	                COALESCE((SELECT range_agg(tstzrange(ee.ts_event, COALESCE(ee.ts_end, nx.ts_next, now())) * tstzrange(el.lo, el.hi))
	                            FROM %[3]s.equipment_events ee
	                            LEFT JOIN LATERAL (SELECT min(n.ts_event) AS ts_next FROM %[3]s.equipment_events n
	                                                WHERE n.id_equipment = ee.id_equipment AND n.ts_event > ee.ts_event
	                                                  AND n.ts_event < el.hi + interval '60 days') nx ON true
	                           WHERE ee.id_equipment = el.ev_src AND %[6]s
	                             AND ee.ts_event < el.hi AND ee.ts_event >= el.lo - interval '60 days'
	                             AND COALESCE(ee.ts_end, nx.ts_next, now()) > el.lo),
	                         '{}'::tstzmultirange) AS pl
	            ) m
	          OFFSET 0
	      ) xx`
