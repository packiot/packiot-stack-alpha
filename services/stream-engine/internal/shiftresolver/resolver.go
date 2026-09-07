// Package shiftresolver is the ADR-0014 Phase 2 Go port of the
// piot_set_shift_on_equipment_values() BEFORE INSERT trigger +
// piot_get_shift_hour_by_equipment() PL/pgSQL function.
//
// Semantics ported 1:1 from the staging DB source (captured 2026-07-02):
//
//  1. Equipment → (id_site, id_area) from equipments.
//  2. Site → (timezone, week_begin) from sites; the site must belong to
//     the payload's enterprise or NO shift resolves (the SQL's outer
//     week_begin subselect filters id_enterprise and a NULL there makes
//     the window comparison NULL → zero rows).
//  3. Week offset X = epoch(ts_value − weekStart) − week_begin, where
//     weekStart = date_trunc('week', ts@tz − week_begin·1s) reinterpreted
//     in the site tz. week_begin may be NEGATIVE (CPACK: -3000 = Sunday
//     23:10 local).
//  4. Candidates: shift_hours rows for the site with begin_time <= X <
//     end_time.
//  5. Selection: ORDER BY (id_area = equipment.id_area) DESC NULLS LAST,
//     id_shift_hour LIMIT 1 — area-specific first, then non-null area
//     mismatches, then site-level (NULL area) rows; lowest id_shift_hour
//     breaks ties deterministically.
//
// Fail-open like the trigger (EXCEPTION WHEN OTHERS THEN NULL): every
// error path returns (nil, nil) — a missing shift never blocks a write.
//
// Reference data (sites/equipments/shift_hours) is cached with a TTL:
// shift definitions change at CS-onboarding cadence, not per message.
package shiftresolver

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// SiteInfo carries the two site columns the week-offset math needs.
type SiteInfo struct {
	IDEnterprise int
	Loc          *time.Location
	WeekBegin    int64 // seconds from Monday 00:00 local; may be negative
}

// ShiftHour is one calendar-expansion row scoped to a site.
type ShiftHour struct {
	IDShiftHour int
	IDShift     int
	IDArea      *int  // NULL = site-level definition
	BeginTime   int64 // seconds from the site's shift-week origin
	EndTime     int64
}

// EquipRef is the equipment → hierarchy lookup.
type EquipRef struct {
	IDSite int
	IDArea int
}

// WeekOffsetSeconds ports the SQL window expression:
//
//	extract(epoch from (ts − date_trunc('week', ts AT TIME ZONE tz −
//	    week_begin·'1 second') AT TIME ZONE tz)) − week_begin
//
// The arithmetic inside date_trunc happens in NAIVE local time (no DST
// jumps), so we clone the local wall-clock fields onto UTC to reproduce
// Postgres's naive semantics exactly, then reinterpret the truncated
// Monday back in the site zone (the AT TIME ZONE round-trip). For zones
// currently observing DST a week_begin window crossing the transition
// could differ from absolute-time arithmetic — Postgres and this port
// agree with each other, which is what the comparator bake checks.
func WeekOffsetSeconds(ts time.Time, site SiteInfo) int64 {
	l := ts.In(site.Loc)
	naive := time.Date(l.Year(), l.Month(), l.Day(), l.Hour(), l.Minute(), l.Second(), 0, time.UTC)
	shifted := naive.Add(-time.Duration(site.WeekBegin) * time.Second)
	// date_trunc('week', …) — ISO week, Monday 00:00.
	daysPastMonday := (int(shifted.Weekday()) + 6) % 7
	monday := time.Date(shifted.Year(), shifted.Month(), shifted.Day(), 0, 0, 0, 0, time.UTC).
		AddDate(0, 0, -daysPastMonday)
	// AT TIME ZONE tz — interpret the naive Monday in the site zone.
	weekStart := time.Date(monday.Year(), monday.Month(), monday.Day(), 0, 0, 0, 0, site.Loc)
	return int64(ts.Sub(weekStart)/time.Second) - site.WeekBegin
}

// Pick ports the trigger's ORDER BY
// (sh.id_area = v_id_area) DESC NULLS LAST, sh.id_shift_hour LIMIT 1.
// Rank: area match (true) > non-null mismatch (false) > NULL area.
func Pick(candidates []ShiftHour, eqArea int) *ShiftHour {
	rank := func(sh *ShiftHour) int {
		if sh.IDArea == nil {
			return 0
		}
		if *sh.IDArea == eqArea {
			return 2
		}
		return 1
	}
	var best *ShiftHour
	bestRank := -1
	for i := range candidates {
		c := &candidates[i]
		r := rank(c)
		if best == nil || r > bestRank || (r == bestRank && c.IDShiftHour < best.IDShiftHour) {
			best, bestRank = c, r
		}
	}
	return best
}

// Resolver caches reference data and answers Resolve() lookups.
type Resolver struct {
	pool   *pgxpool.Pool
	ttl    time.Duration
	logger *slog.Logger

	mu       sync.RWMutex
	loadedAt time.Time
	sites    map[int]SiteInfo
	equips   map[int]EquipRef
	hours    map[int][]ShiftHour // keyed by id_site
}

func New(pool *pgxpool.Pool, ttl time.Duration, logger *slog.Logger) *Resolver {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	return &Resolver{pool: pool, ttl: ttl, logger: logger}
}

// Resolve returns (id_shift, id_shift_hour) for the equipment at ts, or
// (nil, nil) when no shift matches or any lookup fails — fail-open,
// matching the trigger's EXCEPTION WHEN OTHERS THEN NULL.
func (r *Resolver) Resolve(ctx context.Context, idEnterprise, idEquipment int, ts time.Time) (idShift, idShiftHour *int) {
	if err := r.ensureFresh(ctx); err != nil {
		r.logger.Warn("shiftresolver: cache refresh FAILED — resolver fail-open (labels will be NULL)",
			slog.String("err", err.Error()))
		return nil, nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()

	eq, ok := r.equips[idEquipment]
	if !ok {
		return nil, nil
	}
	site, ok := r.sites[eq.IDSite]
	if !ok || site.IDEnterprise != idEnterprise {
		// SQL: the outer week_begin subselect filters id_enterprise; a
		// mismatch NULLs the window comparison → no candidates.
		return nil, nil
	}
	x := WeekOffsetSeconds(ts, site)
	var candidates []ShiftHour
	for _, sh := range r.hours[eq.IDSite] {
		if sh.BeginTime <= x && sh.EndTime > x {
			candidates = append(candidates, sh)
		}
	}
	best := Pick(candidates, eq.IDArea)
	if best == nil {
		return nil, nil
	}
	s, h := best.IDShift, best.IDShiftHour
	return &s, &h
}

func (r *Resolver) ensureFresh(ctx context.Context) error {
	r.mu.RLock()
	fresh := time.Since(r.loadedAt) < r.ttl
	r.mu.RUnlock()
	if fresh {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if time.Since(r.loadedAt) < r.ttl { // double-checked under write lock
		return nil
	}

	sites := make(map[int]SiteInfo)
	rows, err := r.pool.Query(ctx,
		`SELECT id_site, id_enterprise, COALESCE(timezone, 'UTC'), COALESCE(week_begin, 0) FROM public.sites`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id, ent int
		var tz string
		var wb int64
		if err := rows.Scan(&id, &ent, &tz, &wb); err != nil {
			rows.Close()
			return err
		}
		loc, err := time.LoadLocation(tz)
		if err != nil {
			r.logger.Warn("shiftresolver: bad site timezone — site skipped",
				slog.Int("id_site", id), slog.String("tz", tz))
			continue
		}
		sites[id] = SiteInfo{IDEnterprise: ent, Loc: loc, WeekBegin: wb}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	equips := make(map[int]EquipRef)
	rows, err = r.pool.Query(ctx,
		`SELECT id_equipment, id_site, id_area FROM public.equipments`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id int
		var site, area *int
		if err := rows.Scan(&id, &site, &area); err != nil {
			rows.Close()
			return err
		}
		if site == nil {
			continue // unplaced equipment cannot resolve a shift
		}
		a := 0
		if area != nil {
			a = *area
		}
		equips[id] = EquipRef{IDSite: *site, IDArea: a}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	hours := make(map[int][]ShiftHour)
	rows, err = r.pool.Query(ctx,
		`SELECT id_shift_hour, id_shift, id_site, id_area, begin_time, end_time
		   FROM public.shift_hours
		  WHERE id_site IS NOT NULL AND begin_time IS NOT NULL AND end_time IS NOT NULL`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var sh ShiftHour
		var site int
		if err := rows.Scan(&sh.IDShiftHour, &sh.IDShift, &site, &sh.IDArea, &sh.BeginTime, &sh.EndTime); err != nil {
			rows.Close()
			return err
		}
		hours[site] = append(hours[site], sh)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	r.sites, r.equips, r.hours = sites, equips, hours
	r.loadedAt = time.Now()
	r.logger.Info("shiftresolver: reference cache refreshed",
		slog.Int("sites", len(sites)),
		slog.Int("equipments", len(equips)),
		slog.Int("shift_hour_sites", len(hours)))
	return nil
}
