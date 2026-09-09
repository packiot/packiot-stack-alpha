// entity_grains.go — runtime-rollup-{area,site}-{grain} (ledger
// names), ported from the 10 piot_get_{area,site}_runtime_*_production
// bodies (dispatcher-verified plain names; captures banked in docs).
//
// TOPOLOGY: area ← equipment (LINES ONLY, tp_equipment = 3) for day/shift;
// site ← area (areas-of-site). Same-bucket sums (ts_value = ts_value).
//
// #186 (necessity-proven, triple-signal): the area/site HOUR, WEEK, and MONTH
// grains + their *_live_* UNS derivatives had ZERO external consumers (the only
// live area/site consumer — front4 mission control — reads only the DAY/SHIFT
// chain), so those grains + the six piot_create_{area,site}_runtime_{1hour,1week,
// 1month} seed procs were retired. The hour grain's ONE remaining job for the live
// chain was flagging its day grain recalc_needed; that flag is now re-sourced from
// the tier-below DAY grain (equipment→area, area→site — same ts_value the day
// rollup already sums on), so area/site day/shift freshness is unchanged.
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

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// entitySpec parameterizes the two entity tiers (static, never user input).
type entitySpec struct {
	Name       string // "area" | "site"
	Key        string // id_area | id_site
	DayBeginFn string // piot_get_day_begin_by_area | _site
	// sourceJoin yields rows of the tier below scoped to the entity:
	// area ← lines of the area; site ← areas of the site.
	DaySource   string // equipment_oee_daily  | area_oee_daily
	ShiftSource string // equipment_oee_shift | area_oee_shift
	ScopePred   string // join predicate template against el (uses %[2]s ref schema)
}

var entityMatrix = []entitySpec{
	{
		Name: "area", Key: "id_area", DayBeginFn: "piot_get_day_begin_by_area",
		DaySource: "equipment_oee_daily", ShiftSource: "equipment_oee_shift",
		ScopePred: `ard.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments WHERE id_area = el.id_area AND tp_equipment = 3)`,
	},
	{
		Name: "site", Key: "id_site", DayBeginFn: "piot_get_day_begin_by_site",
		DaySource: "area_oee_daily", ShiftSource: "area_oee_shift",
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
	       oee   = GREATEST(LEAST(COALESCE(s.net / NULLIF(s.ideal_production, 0), 0), 1), 0),
	       oee_a = GREATEST(LEAST(COALESCE(s.running_time::float / NULLIF(s.total_time - s.planned_downtime, 0), 0), 1), 0),
	       oee_q = GREATEST(LEAST(COALESCE(s.net::float / NULLIF(s.gross, 0), 0), 1), 0)`

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
	   SET oee_p = GREATEST(LEAST(COALESCE(e.oee::float / NULLIF(e.oee_a * e.oee_q, 0), 0), 1), 0)
	 WHERE NOT e.recalc_needed AND e.ts_value >= now() - interval '1 month'`
	}
	monthWindow := `d.ts_value >= now() - interval '1 month' AND d.ts_value <= now()`
	sameBucket := `ard.ts_value = el.ts_value`

	// #186 DAY-flag cascade — replaces the retired hour→day cascade. The removed
	// hour grain's only remaining job for the live chain was flagging its day grain
	// recalc_needed; re-source that flag from the tier-BELOW day grain
	// (equipment→area, area→site). The day rollup already sums that same source on
	// ard.ts_value = el.ts_value, so the tiers share ts_value and a changed
	// equipment/area day propagates to the area/site day exactly as the hour path did.
	var dayFlagCascade string
	if sp.Name == "area" {
		dayFlagCascade = `
	UPDATE ` + evSchema + `.area_oee_daily t SET recalc_needed = true
	  FROM ` + evSchema + `.equipment_oee_daily ed
	  JOIN ` + refSchema + `.equipments q ON q.id_equipment = ed.id_equipment AND q.tp_equipment = 3
	 WHERE ed.recalc_needed = false AND ed.ts_value >= now() - interval '1 month'
	   AND t.id_area = q.id_area AND t.ts_value = ed.ts_value`
	} else {
		dayFlagCascade = `
	UPDATE ` + evSchema + `.site_oee_daily t SET recalc_needed = true
	  FROM ` + evSchema + `.area_oee_daily ad
	  JOIN ` + refSchema + `.areas a ON a.id_area = ad.id_area
	 WHERE ad.recalc_needed = false AND ad.ts_value >= now() - interval '1 month'
	   AND t.id_site = a.id_site AND t.ts_value = ad.ts_value`
	}

	// Shift tail: prod leaks the loop variable — per-row intent restore.
	shiftTail := `
	UPDATE ` + evSchema + `.` + sp.Name + `_oee_shift e SET recalc_needed = true
	 WHERE e.ts_value_production >= (SELECT ts_value_production FROM ` + sp.DayBeginFn + `(e.` + sp.Key + `, now()) LIMIT 1)
	   AND e.ts_value_production <  (SELECT ts_value_production FROM ` + sp.DayBeginFn + `(e.` + sp.Key + `, now() + interval '1 day') LIMIT 1)`

	// #186: hour/week/month retired (dead). Order preserved for the survivors:
	// the day-flag cascade runs FIRST (flags this entity's day grain from the
	// tier-below day grain), then the day rollup consumes those flags, then shift.
	return []struct{ Name, SQL string }{
		{sp.Name + "-day-flag", dayFlagCascade},
		{sp.Name + "-day", rollup(sp.Name+"_oee_daily", sp.DaySource, sameBucket, `,
	       proportional_target = COALESCE(s.proportional_target, 0)`+stamp("1 day"), monthWindow, true)},
		{sp.Name + "-day-oeep", oeeP(sp.Name + "_oee_daily")},
		{sp.Name + "-shift", rollup(sp.Name+"_oee_shift", sp.ShiftSource, sameBucket, stamp("1 day"), monthWindow, true)},
		{sp.Name + "-shift-oeep", oeeP(sp.Name + "_oee_shift")},
		{sp.Name + "-shift-tail", shiftTail},
	}
}

// RunEntityGrains executes both entity tiers for one destination.
func RunEntityGrains(ctx context.Context, d flows.Dest, exclAreas []int) error {
	for _, sp := range entityMatrix {
		excl := exclAreas
		if sp.Name == "site" {
			excl = []int{} // prod excludes areas only; sites unfiltered
		}
		// #251: entity_grains' evSchema qualifies ONLY the *_oee_daily/_shift GOLD grains
		// (ScopePred's only schema ref is %[2]s=RefSchema=core) → feed GoldSchema, not the
		// public shim, so the shim can drop.
		for _, st := range entityStatements(sp, d.GoldSchema, d.RefSchema) {
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
