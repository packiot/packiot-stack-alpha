package main

// historian_split.go — hot/cold SPLIT execution for the historian endpoints (2026-09-28).
//
// WHY: the union views (silver.equipment_values / silver.equipment_events) mix a pg_duckdb
// read_parquet with a postgres_fdw scan in ONE plan. That plan is slow two ways: the cold
// side re-aggregates per-second parquet rows at query time (a CPACK month ≈ 6-8 M rows; 30
// days took ~25 s against a 60 s timeout), and a mixed plan loses the FDW pushdown the hot
// side needs (the 7-day downtime query took ~24 s). So we run the two sides as SEPARATE
// statements — pure DuckDB for cold, pure Postgres/FDW for hot — and merge in Go:
//
//   production-series, window > histDailyThreshold:
//     cold  = cold.equipment_values_daily (pre-aggregated parquet, spike-guarded), days < W
//     hot   = live.equipment_values_1hour (analytics hourly rollup via FDW),       days >= W
//     W     = cold.ev_daily_watermark.covered_until for an EV-promoted tenant (none ⇒ all hot,
//             exactly like the union view, whose cold branch serves promoted tenants only).
//     Resolution: whole UTC days ([floor(from), ceil(to))).
//   downtime-series, every window:
//     hot   = live.equipment_events aggregated by UTC day in Postgres (pushdown-friendly)
//     cold  = cold.equipment_events, only for an EE-promoted tenant and only before its
//             ee_union_boundary cutover — the union view's exact cold predicate.
//
// Both sides bind LITERAL bounds (simple protocol), never now(): postgres_fdw does not ship
// now(), and a now()-bounded foreign scan pulls the whole remote table.

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// histDailyThreshold: production windows longer than this are served from the daily rollups.
// ≤ 31 days keeps the exact per-second union path (sub-day window edges honored).
const histDailyThreshold = 31 * 24 * time.Hour

const histEVWatermarkSQL = `
  SELECT w.covered_until::text AS covered_until
    FROM cold.ev_daily_watermark w
    JOIN cold.promoted_enterprise p ON p.id_enterprise = w.id_enterprise AND p.ev_promoted
   WHERE w.id_enterprise = $1`

// $1 tenant, $2/$3 day bounds (YYYY-MM-DD), $4-$7 year/month prune; %s equipment filter.
const histEVDailyColdSQL = `
  SELECT day, id_equipment,
         sum(gross_production) AS gross_production,
         sum(net_production)   AS net_production
    FROM cold.equipment_values_daily
   WHERE id_enterprise = $1
     AND day >= $2::date AND day < $3::date
     %s
     AND ( year >  $4 OR (year = $4 AND month >= $5) )
     AND ( year <  $6 OR (year = $6 AND month <= $7) )
   GROUP BY 1, 2`

// $1 tenant, $2/$3 timestamptz bounds; %s equipment filter. date_trunc over
// (ts AT TIME ZONE 'UTC') is immutable, so postgres_fdw can ship the whole aggregate.
const histEVDailyHotSQL = `
  SELECT date_trunc('day', ts_value AT TIME ZONE 'UTC')::date AS day, id_equipment,
         sum(gross_production_incr) AS gross_production,
         sum(net_production_incr)   AS net_production
    FROM live.equipment_values_1hour
   WHERE id_enterprise = $1
     AND ts_value >= $2::timestamptz AND ts_value < $3::timestamptz
     %s
   GROUP BY 1, 2`

const histEEBoundarySQL = `
  SELECT p.ee_promoted, c.cutover_ts::text AS cutover_ts
    FROM cold.promoted_enterprise p
    LEFT JOIN cold.ee_union_boundary c ON c.id_enterprise = p.id_enterprise
   WHERE p.id_enterprise = $1`

const histEEHotSQL = `
  SELECT date_trunc('day', ts_event AT TIME ZONE 'UTC')::date AS day, id_equipment, planned_downtime,
         count(*)      AS event_count,
         sum(duration) AS downtime_seconds
    FROM live.equipment_events
   WHERE id_enterprise = $1
     AND ts_event >= $2::timestamptz AND ts_event < $3::timestamptz
     %s
   GROUP BY 1, 2, 3`

// cold.equipment_events.ts_event is a UTC timestamp (no zone); bounds bind as UTC literals.
const histEEColdSQL = `
  SELECT date_trunc('day', ts_event)::date AS day, id_equipment, planned_downtime,
         count(*)      AS event_count,
         sum(duration) AS downtime_seconds
    FROM cold.equipment_events
   WHERE id_enterprise = $1
     AND ts_event >= $2::timestamp AND ts_event < $3::timestamp
     %s
     AND ( year >  $4 OR (year = $4 AND month >= $5) )
     AND ( year <  $6 OR (year = $6 AND month <= $7) )
   GROUP BY 1, 2, 3`

const tsLayout = "2006-01-02 15:04:05.999999+00"

func utcDayFloor(t time.Time) time.Time {
	u := t.UTC()
	return time.Date(u.Year(), u.Month(), u.Day(), 0, 0, 0, 0, time.UTC)
}

func utcDayCeil(t time.Time) time.Time {
	f := utcDayFloor(t)
	if f.Equal(t.UTC()) {
		return f
	}
	return f.AddDate(0, 0, 1)
}

// pruneArgs returns the year/month bounds covering [from, to).
func pruneArgs(from, to time.Time) (int, int, int, int) {
	last := to.UTC().Add(-time.Microsecond)
	return from.UTC().Year(), int(from.UTC().Month()), last.Year(), int(last.Month())
}

// evDailyPlan is the pure planning step of the production daily path (unit-tested).
type evDailyPlan struct {
	ColdFrom, ColdTo time.Time // days [ColdFrom, ColdTo) from the rollup; zero ⇒ no cold query
	HotFrom, HotTo   time.Time // [HotFrom, HotTo) from the hourly rollup; zero ⇒ no hot query
}

func planEVDaily(from, to time.Time, watermark *time.Time) evDailyPlan {
	dFrom, dTo := utcDayFloor(from), utcDayCeil(to)
	var p evDailyPlan
	hotFrom := dFrom
	if watermark != nil {
		coldTo := *watermark
		if dTo.Before(coldTo) {
			coldTo = dTo
		}
		if dFrom.Before(coldTo) {
			p.ColdFrom, p.ColdTo = dFrom, coldTo
		}
		if watermark.After(hotFrom) {
			hotFrom = *watermark
		}
	}
	if hotFrom.Before(dTo) {
		p.HotFrom, p.HotTo = hotFrom, dTo
	}
	return p
}

// eeColdWindow returns the cold slice of [from, to) for downtime: the union view serves
// cold only for an EE-promoted tenant, and only before its cutover (no cutover row ⇒ all).
func eeColdWindow(from, to time.Time, promoted bool, cutover *time.Time) (time.Time, time.Time, bool) {
	if !promoted {
		return time.Time{}, time.Time{}, false
	}
	end := to
	if cutover != nil && cutover.Before(end) {
		end = *cutover
	}
	if !from.Before(end) {
		return time.Time{}, time.Time{}, false
	}
	return from, end, true
}

func asTime(v any) (time.Time, bool) {
	switch t := v.(type) {
	case time.Time:
		return t.UTC(), true
	case string:
		for _, l := range []string{"2006-01-02", time.RFC3339, "2006-01-02 15:04:05"} {
			if p, err := time.Parse(l, t); err == nil {
				return p.UTC(), true
			}
		}
	}
	return time.Time{}, false
}

func asInt(v any) (int64, bool) {
	switch n := v.(type) {
	case int16:
		return int64(n), true
	case int32:
		return int64(n), true
	case int64:
		return n, true
	case int:
		return int64(n), true
	case float64:
		return int64(n), true
	}
	return 0, false
}

func asFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int64:
		return float64(n), true
	case int32:
		return float64(n), true
	case int:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	case fmt.Stringer:
		var f float64
		_, err := fmt.Sscan(n.String(), &f)
		return f, err == nil
	}
	return 0, false
}

// mergeDaily folds rows from several result sets into one row per key, summing the
// numeric columns. A sum stays null only when every contributing value was null (same
// "honest no data" semantics as SQL sum()). Output is ordered by day, then the key
// columns, and capped at limit.
func mergeDaily(sets [][]map[string]any, keyCols, sumCols []string, limit int) []map[string]any {
	type acc struct {
		row  map[string]any
		sums map[string]*float64
	}
	byKey := map[string]*acc{}
	keys := []string{}
	for _, set := range sets {
		for _, r := range set {
			k := ""
			key := map[string]any{}
			for _, c := range keyCols {
				v := r[c]
				if c == "day" {
					if t, ok := asTime(v); ok {
						v = t
					}
				} else if i, ok := asInt(v); ok {
					v = i
				}
				key[c] = v
				k += fmt.Sprintf("%v|", v)
			}
			a, ok := byKey[k]
			if !ok {
				a = &acc{row: key, sums: map[string]*float64{}}
				byKey[k] = a
				keys = append(keys, k)
			}
			for _, c := range sumCols {
				if f, ok := asFloat(r[c]); ok {
					if a.sums[c] == nil {
						z := 0.0
						a.sums[c] = &z
					}
					*a.sums[c] += f
				}
			}
		}
	}
	out := make([]map[string]any, 0, len(keys))
	for _, k := range keys {
		a := byKey[k]
		row := map[string]any{}
		for c, v := range a.row {
			row[c] = v
		}
		for _, c := range sumCols {
			if a.sums[c] == nil {
				row[c] = nil
			} else {
				row[c] = *a.sums[c]
			}
		}
		out = append(out, row)
	}
	sort.SliceStable(out, func(i, j int) bool {
		for _, c := range keyCols {
			a, b := out[i][c], out[j][c]
			if ta, ok := a.(time.Time); ok {
				if tb, ok := b.(time.Time); ok && !ta.Equal(tb) {
					return ta.Before(tb)
				}
				continue
			}
			sa, sb := fmt.Sprintf("%v", a), fmt.Sprintf("%v", b)
			if ia, ok := asInt(a); ok {
				if ib, ok := asInt(b); ok && ia != ib {
					return ia < ib
				}
				continue
			}
			if sa != sb {
				return sa < sb
			}
		}
		return false
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

func serveEVDaily(ctx context.Context, pool *pgxpool.Pool, cid int, q histSeriesReq, equipFilter string) ([]map[string]any, error) {
	var wm *time.Time
	rows, err := runQueryRows(ctx, pool, cid, histEVWatermarkSQL, []any{cid})
	if err != nil {
		return nil, fmt.Errorf("watermark: %w", err)
	}
	if len(rows) == 1 {
		if t, ok := asTime(rows[0]["covered_until"]); ok {
			wm = &t
		}
	}
	p := planEVDaily(q.From, q.To, wm)
	var sets [][]map[string]any
	if !p.ColdFrom.IsZero() {
		fy, fm, ty, tm := pruneArgs(p.ColdFrom, p.ColdTo)
		cold, err := runQueryRows(ctx, pool, cid, fmt.Sprintf(histEVDailyColdSQL, equipFilter),
			[]any{cid, p.ColdFrom.Format("2006-01-02"), p.ColdTo.Format("2006-01-02"), fy, fm, ty, tm})
		if err != nil {
			return nil, fmt.Errorf("cold daily: %w", err)
		}
		sets = append(sets, cold)
	}
	if !p.HotFrom.IsZero() {
		hot, err := runQueryRows(ctx, pool, cid, fmt.Sprintf(histEVDailyHotSQL, equipFilter),
			[]any{cid, p.HotFrom.Format(tsLayout), p.HotTo.Format(tsLayout)})
		if err != nil {
			return nil, fmt.Errorf("hot hourly: %w", err)
		}
		sets = append(sets, hot)
	}
	return mergeDaily(sets, []string{"day", "id_equipment"}, []string{"gross_production", "net_production"}, histRowLimit), nil
}

func serveEESplit(ctx context.Context, pool *pgxpool.Pool, cid int, q histSeriesReq, equipFilter string) ([]map[string]any, error) {
	promoted := false
	var cut *time.Time
	rows, err := runQueryRows(ctx, pool, cid, histEEBoundarySQL, []any{cid})
	if err != nil {
		return nil, fmt.Errorf("ee boundary: %w", err)
	}
	if len(rows) == 1 {
		promoted, _ = rows[0]["ee_promoted"].(bool)
		if t, ok := asTime(rows[0]["cutover_ts"]); ok {
			cut = &t
		}
	}
	var sets [][]map[string]any
	hot, err := runQueryRows(ctx, pool, cid, fmt.Sprintf(histEEHotSQL, equipFilter),
		[]any{cid, q.From.UTC().Format(tsLayout), q.To.UTC().Format(tsLayout)})
	if err != nil {
		return nil, fmt.Errorf("hot events: %w", err)
	}
	sets = append(sets, hot)
	if cf, ct, ok := eeColdWindow(q.From.UTC(), q.To.UTC(), promoted, cut); ok {
		fy, fm, ty, tm := pruneArgs(cf, ct)
		cold, err := runQueryRows(ctx, pool, cid, fmt.Sprintf(histEEColdSQL, equipFilter),
			[]any{cid, cf.Format("2006-01-02 15:04:05.999999"), ct.Format("2006-01-02 15:04:05.999999"), fy, fm, ty, tm})
		if err != nil {
			return nil, fmt.Errorf("cold events: %w", err)
		}
		sets = append(sets, cold)
	}
	return mergeDaily(sets, []string{"day", "id_equipment", "planned_downtime"}, []string{"event_count", "downtime_seconds"}, histRowLimit), nil
}
