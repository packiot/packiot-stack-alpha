// entity_grains.go — runtime-rollup-{area,site}-{grain} (ledger
// names), ported from the 10 piot_get_{area,site}_runtime_*_production
// bodies (dispatcher-verified plain names; captures banked in docs).
//
// TOPOLOGY: area ← equipment (LINES ONLY, tp_equipment = 3) for
// hour/day/shift; site ← area (areas-of-site); week/month ← own-entity
// day. Same-bucket sums (ts_value = ts_value) except week/month
// ([week_trunc(ts), ts + 1 week] — the <= upper bound is verbatim).
//
// EQUIVALENCE ARGUMENT:
//   - All bodies are the always-FOUND class → eligible LEFT JOIN with
//     each body's OWN fill style: hour = RAW (NULL propagates — the
//     verbatim outlier, no COALESCE on metrics); day/week/month/shift
//     = COALESCE-0. Do not "harmonize" them.
//   - oee = net/ideal, oee_a = running/(total−planned) (hour variant:
//     running/available), oee_q = net/gross; oee_p = oee/(oee_a·oee_q)
//     as a SECOND update (hour: inlined in the first — verbatim).
//   - Cascades: area hour → area day (day-begin-by-area anchored);
//     area/site day → own week + month. Site hour → site day.
//   - Tails: hour re-flags current hour with proportional_target =
//     target · minute/60; week re-flags current week; day re-flags
//     current day; shift re-flags via day-begin tvp window — prod's
//     shift tails reference the LOOP VARIABLE after the loop (the
//     amber class again): intent-restored per-row (e.id_area/e.id_site),
//     documented divergence.
//   - Exclusions (area 24) → config param.
//   - Ideal speed: NO own derivation — every body sums the tier
//     below's ideal_production, so the tp_equipment=3 NULL-ideal
//     LOCF fix (hour.go/shift.go speed passes) is inherited here.
//
// GUARDRAIL: UPDATEs area_/site_runtime_* by (key, ts_value); reads
// the tier below. No PO tables.
package rollup

import (
	"context"
	"fmt"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
)

// entitySpec parameterizes the two entity tiers (static, never user input).
type entitySpec struct {
	Name       string // "area" | "site"
	Key        string // id_area | id_site
	DayBeginFn string // piot_get_day_begin_by_area | _site
	// sourceJoin yields rows of the tier below scoped to the entity:
	// area ← lines of the area; site ← areas of the site.
	HourSource  string // equipment_runtime_1hour | area_runtime_1hour
	DaySource   string // equipment_runtime_1day  | area_runtime_1day
	ShiftSource string // equipment_runtime_shift | area_runtime_shift
	ScopePred   string // join predicate template against el (uses %[2]s ref schema)
}

var entityMatrix = []entitySpec{
	{
		Name: "area", Key: "id_area", DayBeginFn: "piot_get_day_begin_by_area",
		HourSource: "equipment_runtime_1hour", DaySource: "equipment_runtime_1day", ShiftSource: "equipment_runtime_shift",
		ScopePred: `ard.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments WHERE id_area = el.id_area AND tp_equipment = 3)`,
	},
	{
		Name: "site", Key: "id_site", DayBeginFn: "piot_get_day_begin_by_site",
		HourSource: "area_runtime_1hour", DaySource: "area_runtime_1day", ShiftSource: "area_runtime_shift",
		ScopePred: `ard.id_area IN (SELECT id_area FROM %[2]s.areas WHERE id_site = el.id_site)`,
	},
}

// The 17-metric sum list shared by day/week/month/shift shapes.
const entitySumList = `
	           sum(ard.available_time) AS available_time,
	           sum(ard.running_time)   AS running_time,
	           sum(ard.stopped_time)   AS stopped_time,
	           sum(ard.planned_downtime) AS planned_downtime,
	           sum(ard.available_time) + sum(ard.planned_downtime) AS total_time,
	           sum(ard.ideal_production) AS ideal_production,
	           sum(ard.idle_time)      AS idle_time,
	           sum(ard.idle_starved)   AS idle_starved,
	           sum(ard.idle_blocked)   AS idle_blocked,
	           sum(ard.target)         AS target,
	           sum(ard.gross)          AS gross,
	           sum(ard.net)            AS net,
	           sum(ard.downtime)       AS downtime,
	           sum(ard.changeover_time) AS changeover_time,
	           sum(ard.scrap)          AS scrap,
	           sum(ard.proportional_target) AS proportional_target`

const entityFillList = `
	       available_time  = COALESCE(s.available_time, 0),
	       running_time    = COALESCE(s.running_time, 0),
	       stopped_time    = COALESCE(s.stopped_time, 0),
	       planned_downtime = COALESCE(s.planned_downtime, 0),
	       ideal_production = COALESCE(s.ideal_production, 0),
	       idle_time       = COALESCE(s.idle_time, 0),
	       idle_starved    = COALESCE(s.idle_starved, 0),
	       idle_blocked    = COALESCE(s.idle_blocked, 0),
	       target          = COALESCE(s.target, 0),
	       gross           = COALESCE(s.gross, 0),
	       net             = COALESCE(s.net, 0),
	       scrap           = COALESCE(s.scrap, 0),
	       downtime        = COALESCE(s.downtime, 0),
	       changeover_time = COALESCE(s.changeover_time, 0),
	       recalc_needed   = false,
	       -- ADR-0037 output-invariant clamp (#576 extended to the aggregation
	       -- grains): the equipment grain clamps oee_a via LEAST, but area/site
	       -- summed raw — so a historical corrupt running_time (billions) or
	       -- net>gross on ONE contributor surfaced as oee_a=38316 / oee_q>1 here.
	       -- Bound every served factor to [0,1]; raw summed columns untouched.
	       oee   = LEAST(COALESCE(s.net / NULLIF(s.ideal_production, 0), 0), 1),
	       oee_a = LEAST(COALESCE(s.running_time::float / NULLIF(s.total_time - s.planned_downtime, 0), 0), 1),
	       oee_q = LEAST(COALESCE(s.net::float / NULLIF(s.gross, 0), 0), 1)`

// entityStatements builds the ordered SQL for one entity tier.
// KEY = spec key column, TBL = grain table, SRC = source table,
// SCOPE = source scoping predicate, JOINEXPR = bucket-matching pred.
func entityStatements(sp entitySpec, evSchema, refSchema string) []struct{ Name, SQL string } {
	scope := fmt.Sprintf(sp.ScopePred, evSchema, refSchema)
	// ADR-0036 §5A lineage stamp (T0-2), folded into each entity rollup's SET
	// list. entity_grains has no ForParity accessor, so this never reaches the
	// prod comparator. ts_value on area/site grains may be DATE or timestamptz
	// → ::timestamptz normalizes both; source_watermark = LEAST(bucket end,
	// now()) with the span passed per grain.
	stamp := func(span string) string {
		return ",\n\t       computed_at = now(),\n\t       source_watermark = LEAST(e.ts_value::timestamptz + interval '" + span + "', now())"
	}
	rollup := func(tbl, src, joinExpr, extraFill, window string, scoped bool) string {
		srcPred := scope
		if !scoped {
			// week/month sum OWN-entity day rows — keyed directly;
			// the tier-below scope pred would reference absent columns.
			srcPred = "ard." + sp.Key + " = el." + sp.Key
		}
		return `
	WITH eligible AS (
	    SELECT d.` + sp.Key + ` AS key, d.ts_value AS bucket
	      FROM ` + evSchema + `.` + tbl + ` d
	     WHERE d.recalc_needed AND ` + window + `
	       AND NOT (d.` + sp.Key + ` = ANY($1))
	), el AS (SELECT key AS ` + sp.Key + `, bucket AS ts_value FROM eligible), sums AS (
	    SELECT el.` + sp.Key + `, el.ts_value,` + entitySumList + `
	      FROM el
	      JOIN ` + evSchema + `.` + src + ` ard ON ` + joinExpr + `
	       AND ` + srcPred + `
	     GROUP BY el.` + sp.Key + `, el.ts_value
	)
	UPDATE ` + evSchema + `.` + tbl + ` e SET` + entityFillList + extraFill + `
	  FROM el LEFT JOIN sums s ON s.` + sp.Key + ` = el.` + sp.Key + ` AND s.ts_value = el.ts_value
	 WHERE e.` + sp.Key + ` = el.` + sp.Key + ` AND e.ts_value = el.ts_value`
	}
	oeeP := func(tbl string) string {
		return `
	UPDATE ` + evSchema + `.` + tbl + ` e
	   SET oee_p = LEAST(COALESCE(e.oee::float / NULLIF(e.oee_a * e.oee_q, 0), 0), 1)
	 WHERE NOT e.recalc_needed AND e.ts_value >= now() - interval '1 month'`
	}
	monthWindow := `d.ts_value >= now() - interval '1 month' AND d.ts_value <= now()`
	weekWindow := `d.ts_value >= now() - interval '1 month' AND d.ts_value < now()`
	sameBucket := `ard.ts_value = el.ts_value`
	weekSpan := `ard.ts_value >= date_trunc('week', el.ts_value) AND ard.ts_value <= el.ts_value + interval '1 week'`
	monthSpan := `ard.ts_value >= date_trunc('month', el.ts_value) AND ard.ts_value <= el.ts_value + interval '1 month'`
	ownDay := sp.Name + `_runtime_1day`
	if sp.Name == "area" {
		ownDay = "area_runtime_1day"
	} else {
		ownDay = "site_runtime_1day"
	}

	// HOUR shape: RAW fill (NULL propagates), inline oee_p, prop = target.
	hour := `
	WITH el AS (
	    SELECT d.` + sp.Key + `, d.ts_value
	      FROM ` + evSchema + `.` + sp.Name + `_runtime_1hour d
	     WHERE d.recalc_needed AND d.ts_value >= now() - interval '1 month' AND d.ts_value <= now()
	       AND NOT (d.` + sp.Key + ` = ANY($1))
	), sums AS (
	    SELECT el.` + sp.Key + `, el.ts_value,` + entitySumList + `
	      FROM el
	      JOIN ` + evSchema + `.` + sp.HourSource + ` ard ON ard.ts_value = el.ts_value
	       AND ` + scope + `
	     GROUP BY el.` + sp.Key + `, el.ts_value
	)
	UPDATE ` + evSchema + `.` + sp.Name + `_runtime_1hour e SET
	       gross = s.gross, net = s.net, scrap = s.scrap,
	       oee_q = LEAST(COALESCE(s.net / NULLIF(s.gross, 0), 0), 1), -- ADR-0037 clamp (net≤gross)
	       available_time = s.available_time, running_time = s.running_time,
	       stopped_time = s.stopped_time, planned_downtime = s.planned_downtime,
	       ideal_production = s.ideal_production,
	       idle_time = s.idle_time, idle_starved = s.idle_starved, idle_blocked = s.idle_blocked,
	       target = s.target, downtime = s.downtime, changeover_time = s.changeover_time,
	       oee   = LEAST(COALESCE(s.net / NULLIF(s.ideal_production, 0), 0), 1), -- ADR-0037 clamp [0,1]
	       oee_a = LEAST(COALESCE(s.running_time::float / NULLIF(s.available_time, 0), 0), 1),
	       oee_p = LEAST(COALESCE((s.net / NULLIF(s.ideal_production, 0)) /
	               NULLIF(s.running_time::float / NULLIF(s.available_time, 0) * (s.net::float / NULLIF(s.gross, 0)), 0), 0), 1),
	       proportional_target = s.target,
	       recalc_needed = false` + stamp("1 hour") + `
	  FROM el
	  JOIN sums s ON s.` + sp.Key + ` = el.` + sp.Key + ` AND s.ts_value = el.ts_value
	 WHERE e.` + sp.Key + ` = el.` + sp.Key + ` AND e.ts_value = el.ts_value`
	// hour body updates ONLY on found (inner join) — sums exist ⇒
	// always-FOUND makes inner ≈ left for non-empty; empty-sum rows
	// keep prior values AND their flag: prod's if-found gates the
	// whole update, and with no source rows FOUND is still true but
	// every field is NULL — RAW fill writes those NULLs. Left join +
	// raw fill reproduces exactly that.
	hour = hourRawLeftJoin(hour)

	hourCascadeDay := `
	UPDATE ` + evSchema + `.` + sp.Name + `_runtime_1day t SET recalc_needed = true
	  FROM el
	 WHERE t.` + sp.Key + ` = el.` + sp.Key + `
	   AND t.ts_value = (SELECT ts_value_production FROM ` + sp.DayBeginFn + `(el.` + sp.Key + `, el.ts_value) LIMIT 1)`
	_ = hourCascadeDay // folded into the tx below via temp view; see runner

	hourTail := `
	UPDATE ` + evSchema + `.` + sp.Name + `_runtime_1hour SET recalc_needed = true,
	       proportional_target = target * (SELECT extract(minute FROM now()) / 60)
	 WHERE ts_value >= date_trunc('hour', now())::timestamptz AND ts_value <= now()`

	dayCascades := `
	UPDATE ` + evSchema + `.` + sp.Name + `_runtime_1month t SET recalc_needed = true
	  FROM ` + evSchema + `.` + sp.Name + `_runtime_1day d
	 WHERE d.recalc_needed = false AND d.ts_value >= now() - interval '1 month'
	   AND t.` + sp.Key + ` = d.` + sp.Key + ` AND t.ts_value = date_trunc('month', d.ts_value)`
	dayCascadeWeek := `
	UPDATE ` + evSchema + `.` + sp.Name + `_runtime_1week t SET recalc_needed = true
	  FROM ` + evSchema + `.` + sp.Name + `_runtime_1day d
	 WHERE d.recalc_needed = false AND d.ts_value >= now() - interval '1 month'
	   AND t.` + sp.Key + ` = d.` + sp.Key + ` AND t.ts_value = date_trunc('week', d.ts_value)`

	weekTail := `
	UPDATE ` + evSchema + `.` + sp.Name + `_runtime_1week SET recalc_needed = true
	 WHERE ts_value >= date_trunc('week', now())
	   AND ts_value < date_trunc('week', now() + interval '1 week')`
	monthTail := `
	UPDATE ` + evSchema + `.` + sp.Name + `_runtime_1month SET recalc_needed = true
	 WHERE ts_value >= date_trunc('month', now())
	   AND ts_value < date_trunc('month', now() + interval '1 month')`
	// Shift tail: prod leaks the loop variable — per-row intent restore.
	shiftTail := `
	UPDATE ` + evSchema + `.` + sp.Name + `_runtime_shift e SET recalc_needed = true
	 WHERE e.ts_value_production >= (SELECT ts_value_production FROM ` + sp.DayBeginFn + `(e.` + sp.Key + `, now()) LIMIT 1)
	   AND e.ts_value_production <  (SELECT ts_value_production FROM ` + sp.DayBeginFn + `(e.` + sp.Key + `, now() + interval '1 day') LIMIT 1)`

	return []struct{ Name, SQL string }{
		{sp.Name + "-hour", hour},
		{sp.Name + "-hour-cascade-day", `
	UPDATE ` + evSchema + `.` + sp.Name + `_runtime_1day t SET recalc_needed = true
	  FROM ` + evSchema + `.` + sp.Name + `_runtime_1hour h
	 WHERE h.recalc_needed = false AND h.ts_value >= now() - interval '1 month'
	   AND t.` + sp.Key + ` = h.` + sp.Key + `
	   AND t.ts_value = (SELECT ts_value_production FROM ` + sp.DayBeginFn + `(h.` + sp.Key + `, h.ts_value) LIMIT 1)`},
		{sp.Name + "-hour-tail", hourTail},
		{sp.Name + "-day", rollup(sp.Name+"_runtime_1day", sp.DaySource, sameBucket, `,
	       proportional_target = COALESCE(s.proportional_target, 0)`+stamp("1 day"), monthWindow, true)},
		{sp.Name + "-day-oeep", oeeP(sp.Name + "_runtime_1day")},
		{sp.Name + "-day-cascade-month", dayCascades},
		{sp.Name + "-day-cascade-week", dayCascadeWeek},
		{sp.Name + "-shift", rollup(sp.Name+"_runtime_shift", sp.ShiftSource, sameBucket, stamp("1 day"), monthWindow, true)},
		{sp.Name + "-shift-oeep", oeeP(sp.Name + "_runtime_shift")},
		{sp.Name + "-shift-tail", shiftTail},
		{sp.Name + "-week", rollup(sp.Name+"_runtime_1week", ownDay, weekSpan, `,
	       proportional_target = COALESCE(s.proportional_target, 0)`+stamp("7 days"), weekWindow, false)},
		{sp.Name + "-week-oeep", oeeP(sp.Name + "_runtime_1week")},
		{sp.Name + "-week-tail", weekTail},
		{sp.Name + "-month", rollup(sp.Name+"_runtime_1month", ownDay, monthSpan, `,
	       proportional_target = COALESCE(s.proportional_target, 0)`+stamp("1 month"), weekWindow, false)},
		{sp.Name + "-month-oeep", oeeP(sp.Name + "_runtime_1month")},
		{sp.Name + "-month-tail", monthTail},
	}
}

// hourRawLeftJoin converts the hour statement's inner sums join to a
// left join (see the equivalence note in the hour template).
func hourRawLeftJoin(s string) string {
	return strings.Replace(s, "JOIN sums s ON", "LEFT JOIN sums s ON", 1)
}

// RunEntityGrains executes both entity tiers for one destination.
func RunEntityGrains(ctx context.Context, d flows.Dest, exclAreas []int) error {
	for _, sp := range entityMatrix {
		excl := exclAreas
		if sp.Name == "site" {
			excl = []int{} // prod excludes areas only; sites unfiltered
		}
		for _, st := range entityStatements(sp, d.EvSchema, d.RefSchema) {
			var err error
			if strings.Contains(st.SQL, "$1") {
				_, err = d.Pool.Exec(ctx, st.SQL, excl)
			} else {
				_, err = d.Pool.Exec(ctx, st.SQL)
			}
			if err != nil {
				return fmt.Errorf("%s: %w", st.Name, err)
			}
		}
	}
	return nil
}
