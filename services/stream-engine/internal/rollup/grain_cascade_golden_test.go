//go:build golden

// Golden regressions for the week/month and area/site cascade (2026-09-29), driven
// through the PUBLIC entry points RunGrains / RunEntityGrains so the same test runs
// (and fails) on the pre-fix code:
//
//   - WEEK/MONTH SCRAP: grainRollupSQL never wrote scrap → weekly/monthly scrap
//     stayed 0 while gross != net. Now Σ daily scrap, SIGNED (negative = transit).
//   - STALE WEEKS: a day rewritten outside RunDay's cascade (a recompute runner)
//     never flagged its week → the week stayed all-zero, computed_at NULL. The
//     freshness flag recomputes a week whose newest day is newer than the week.
//     A fresh week and a legacy week (days with computed_at NULL) are untouched.
//   - PHANTOM FLAGS: the week/month re-flag flagged tp=1 machine rows the
//     eligibility (tp>1) never drains → permanent recalc_needed backlog.
//   - SITE SHIFT: nothing re-flagged a past site shift after its areas were
//     recomputed → site != Σ areas (stale gross, planned_downtime 0).
//   - AREA WINDOW: a flagged area row older than 1 month never drained.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run Cascade
package rollup

import (
	"context"
	"math"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

const cascadeGrainCols = `
	    recalc_needed boolean DEFAULT false, target_customized boolean DEFAULT false,
	    available_time double precision, running_time double precision,
	    stopped_time double precision, planned_downtime double precision,
	    ideal_production double precision, idle_time double precision,
	    idle_starved double precision, idle_blocked double precision,
	    target double precision, proportional_target double precision,
	    gross double precision, net double precision, scrap double precision,
	    downtime double precision, changeover_time double precision, speed double precision,
	    oee double precision, oee_a double precision, oee_p double precision, oee_q double precision,
	    computed_at timestamptz, source_watermark timestamptz`

const cascadeSchema = `
	CREATE TABLE golden.areas (id_area int, id_site int);
	CREATE TABLE golden.enterprises (id_enterprise int, active boolean);
	CREATE TABLE golden.production_targets (id_equipment int, vl_week double precision, vl_month double precision);
	CREATE TABLE golden.equipment_oee_daily   (id_equipment int, ts_value date,` + cascadeGrainCols + `);
	CREATE TABLE golden.equipment_oee_weekly  (id_equipment int, ts_value date,` + cascadeGrainCols + `);
	CREATE TABLE golden.equipment_oee_monthly (id_equipment int, ts_value date,` + cascadeGrainCols + `);
	CREATE TABLE golden.equipment_oee_shift   (id_equipment int, ts_value timestamptz, ts_value_production date,` + cascadeGrainCols + `);
	CREATE TABLE golden.area_oee_daily (id_area int, ts_value date,` + cascadeGrainCols + `);
	CREATE TABLE golden.area_oee_shift (id_area int, ts_value timestamptz, ts_value_production date,` + cascadeGrainCols + `);
	CREATE TABLE golden.site_oee_shift (id_site int, ts_value timestamptz, ts_value_production date,` + cascadeGrainCols + `);
	CREATE FUNCTION golden.piot_get_day_begin_by_area(a int, t timestamptz)
	  RETURNS TABLE (ts_value timestamptz, ts_value_production date)
	  AS 'SELECT date_trunc(''day'', $2), date_trunc(''day'', $2)::date' LANGUAGE sql;
	CREATE FUNCTION golden.piot_get_day_begin_by_site(s int, t timestamptz)
	  RETURNS TABLE (ts_value timestamptz, ts_value_production date)
	  AS 'SELECT date_trunc(''day'', $2), date_trunc(''day'', $2)::date' LANGUAGE sql;

	INSERT INTO golden.enterprises VALUES (35, true);
	INSERT INTO golden.areas VALUES (1, 1), (2, 1);
	INSERT INTO golden.equipments VALUES
	    (30,1,1,35,3,100),  -- line, area 1
	    (31,1,1,35,1,100),  -- MACHINE (tp=1), area 1
	    (32,1,1,35,3,100),  -- line with legacy-copied days (computed_at NULL)
	    (33,1,2,35,3,100);  -- line, area 2

	-- SCRAP: last week, flagged; two days with SIGNED scrap (-5 transit, +12).
	INSERT INTO golden.equipment_oee_weekly (id_equipment, ts_value, recalc_needed, gross, net, scrap)
	VALUES (30, (date_trunc('week', now()) - interval '7 days')::date, true, 0, 0, 0);
	INSERT INTO golden.equipment_oee_daily (id_equipment, ts_value, gross, net, scrap, available_time, running_time, planned_downtime, ideal_production, computed_at)
	VALUES (30, (date_trunc('week', now()) - interval '7 days')::date,                     100, 105, -5, 3600, 1800, 0, 200, now() - interval '1 hour'),
	       (30, (date_trunc('week', now()) - interval '7 days' + interval '1 day')::date,  50,  38, 12, 3600, 1800, 0, 200, now() - interval '1 hour');
	-- same for a month (6 months back: 3 months collided with the -70-day stale-week day on some dates, e.g. 2026-10-01), flagged.
	INSERT INTO golden.equipment_oee_monthly (id_equipment, ts_value, recalc_needed, gross, net, scrap)
	VALUES (30, date_trunc('month', now() - interval '6 months')::date, true, 0, 0, 0);
	INSERT INTO golden.equipment_oee_daily (id_equipment, ts_value, gross, net, scrap, available_time, running_time, planned_downtime, ideal_production, computed_at)
	VALUES (30, date_trunc('month', now() - interval '6 months')::date,                    100, 105, -5, 3600, 1800, 0, 200, now() - interval '1 hour'),
	       (30, (date_trunc('month', now() - interval '6 months') + interval '1 day')::date, 50, 38, 12, 3600, 1800, 0, 200, now() - interval '1 hour');

	-- STALE week (10 weeks back): never computed, NOT flagged, its day has data.
	INSERT INTO golden.equipment_oee_weekly (id_equipment, ts_value, recalc_needed, gross, net, scrap, computed_at)
	VALUES (30, (date_trunc('week', now()) - interval '70 days')::date, false, 0, 0, 0, NULL),
	       -- FRESH week (20 weeks back): computed after its day → untouched (999 sentinel).
	       (30, (date_trunc('week', now()) - interval '140 days')::date, false, 999, 999, 0, now()),
	       -- LEGACY week: its day has computed_at NULL → untouched (555 sentinel).
	       (32, (date_trunc('week', now()) - interval '70 days')::date, false, 555, 555, 0, NULL);
	INSERT INTO golden.equipment_oee_daily (id_equipment, ts_value, gross, net, scrap, available_time, running_time, planned_downtime, ideal_production, computed_at)
	VALUES (30, (date_trunc('week', now()) - interval '70 days')::date,  70, 60, 10, 3600, 1800, 0, 200, now() - interval '1 hour'),
	       (30, (date_trunc('week', now()) - interval '140 days')::date,  1,  1,  0, 3600, 1800, 0, 200, now() - interval '1 hour'),
	       (32, (date_trunc('week', now()) - interval '70 days')::date,   1,  1,  0, 3600, 1800, 0, 200, NULL);

	-- PHANTOM FLAG: current-week rows of a line and of a tp=1 machine, both unflagged.
	INSERT INTO golden.equipment_oee_weekly (id_equipment, ts_value, recalc_needed)
	VALUES (30, date_trunc('week', now())::date, false), (31, date_trunc('week', now())::date, false);

	-- SITE: a shift 2 days ago; areas recomputed a minute ago, site a day ago (stale).
	INSERT INTO golden.area_oee_shift (id_area, ts_value, ts_value_production, recalc_needed, gross, net, scrap, planned_downtime, available_time, running_time, ideal_production, computed_at)
	VALUES (1, date_trunc('hour', now()) - interval '2 days', (now() - interval '2 days')::date, false, 10, 9, 1, 100, 3500, 3000, 20, now() - interval '1 minute'),
	       (2, date_trunc('hour', now()) - interval '2 days', (now() - interval '2 days')::date, false, 20, 18, 2, 200, 3400, 3000, 40, now() - interval '1 minute');
	INSERT INTO golden.site_oee_shift (id_site, ts_value, ts_value_production, recalc_needed, gross, net, planned_downtime, computed_at)
	VALUES (1, date_trunc('hour', now()) - interval '2 days', (now() - interval '2 days')::date, false, 99, 99, 0, now() - interval '1 day');

	-- AREA WINDOW: an area shift 60 days old, flagged; its line carries gross 40.
	INSERT INTO golden.area_oee_shift (id_area, ts_value, ts_value_production, recalc_needed, gross)
	VALUES (1, date_trunc('hour', now()) - interval '60 days', (now() - interval '60 days')::date, true, 0);
	INSERT INTO golden.equipment_oee_shift (id_equipment, ts_value, ts_value_production, gross, net, scrap, available_time, running_time, planned_downtime, ideal_production)
	VALUES (30, date_trunc('hour', now()) - interval '60 days', (now() - interval '60 days')::date, 40, 36, 4, 3600, 1800, 0, 60);`

func TestGoldenCascadeGrains(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = "golden, public"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	for _, s := range []string{goldenSchema, cascadeSchema} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	d := flows.Dest{Name: "golden", Pool: pool, EvSchema: "golden", RefSchema: "golden", SilverSchema: "golden",
		GoldSchema: "golden", GrainSchema: "golden", ConfigSchema: "golden"}
	if err := RunGrains(ctx, d, []int{}, []int{}, CountersAvail{OeeCanonicalAPQ: true}); err != nil {
		t.Fatalf("RunGrains: %v", err)
	}
	if err := RunEntityGrains(ctx, d, []int{}); err != nil {
		t.Fatalf("RunEntityGrains: %v", err)
	}

	f := func(q string, args ...any) float64 {
		t.Helper()
		var v float64
		if err := pool.QueryRow(ctx, q, args...).Scan(&v); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return v
	}
	b := func(q string) bool {
		t.Helper()
		var v bool
		if err := pool.QueryRow(ctx, q).Scan(&v); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return v
	}

	// 1. week/month scrap = Σ daily scrap, signed.
	if s := f(`SELECT scrap FROM golden.equipment_oee_weekly WHERE id_equipment=30 AND ts_value=(date_trunc('week', now()) - interval '7 days')::date`); s != 7 {
		t.Errorf("weekly scrap = %v, want 7 (Σ daily scrap -5 + 12; old code never wrote scrap → 0)", s)
	}
	if s := f(`SELECT scrap FROM golden.equipment_oee_monthly WHERE id_equipment=30 AND ts_value=date_trunc('month', now() - interval '6 months')::date`); s != 7 {
		t.Errorf("monthly scrap = %v, want 7", s)
	}

	// 2. stale week recomputed; fresh + legacy weeks untouched.
	if g := f(`SELECT gross FROM golden.equipment_oee_weekly WHERE id_equipment=30 AND ts_value=(date_trunc('week', now()) - interval '70 days')::date`); g != 70 {
		t.Errorf("stale week gross = %v, want 70 (its day was rewritten after the week; old code never flagged it → 0)", g)
	}
	if b(`SELECT computed_at IS NULL FROM golden.equipment_oee_weekly WHERE id_equipment=30 AND ts_value=(date_trunc('week', now()) - interval '70 days')::date`) {
		t.Error("stale week still has computed_at NULL")
	}
	if g := f(`SELECT gross FROM golden.equipment_oee_weekly WHERE id_equipment=30 AND ts_value=(date_trunc('week', now()) - interval '140 days')::date`); g != 999 {
		t.Errorf("fresh week gross = %v, want 999 (computed after its days — must not be re-flagged)", g)
	}
	if g := f(`SELECT gross FROM golden.equipment_oee_weekly WHERE id_equipment=32`); g != 555 {
		t.Errorf("legacy week gross = %v, want 555 (days with computed_at NULL must not trigger a recompute)", g)
	}

	// 3. re-flag scoped to the eligibility: the line's current week is flagged, the machine's is not.
	if !b(`SELECT recalc_needed FROM golden.equipment_oee_weekly WHERE id_equipment=30 AND ts_value=date_trunc('week', now())::date`) {
		t.Error("line current week not re-flagged")
	}
	if b(`SELECT recalc_needed FROM golden.equipment_oee_weekly WHERE id_equipment=31`) {
		t.Error("tp=1 machine current week was re-flagged — the grain eligibility is tp>1, so the flag never drains (phantom backlog)")
	}

	// 4. site shift = Σ areas (gross 30, planned 300), recomputed.
	if g := f(`SELECT gross FROM golden.site_oee_shift WHERE id_site=1`); g != 30 {
		t.Errorf("site gross = %v, want 30 = Σ areas (old code left the stale 99)", g)
	}
	if p := f(`SELECT planned_downtime FROM golden.site_oee_shift WHERE id_site=1`); p != 300 {
		t.Errorf("site planned_downtime = %v, want 300 = Σ areas", p)
	}

	// 5. area row flagged 60 days ago drains, with oee_p written inline.
	if b(`SELECT recalc_needed FROM golden.area_oee_shift WHERE id_area=1 AND ts_value = date_trunc('hour', now()) - interval '60 days'`) {
		t.Error("60-day-old flagged area shift never drained (1-month eligibility window)")
	}
	if g := f(`SELECT gross FROM golden.area_oee_shift WHERE id_area=1 AND ts_value = date_trunc('hour', now()) - interval '60 days'`); g != 40 {
		t.Errorf("old area shift gross = %v, want 40", g)
	}
	var oee, a, p, q float64
	if err := pool.QueryRow(ctx, `SELECT oee, oee_a, oee_p, oee_q FROM golden.area_oee_shift WHERE id_area=1 AND ts_value = date_trunc('hour', now()) - interval '60 days'`).
		Scan(&oee, &a, &p, &q); err != nil {
		t.Fatal(err)
	}
	if oee <= 0 || math.Abs(oee-a*p*q) > 1e-9 {
		t.Errorf("old area shift waterfall: oee=%v a=%v p=%v q=%v (oee_p must be written for rows outside the oeep month window)", oee, a, p, q)
	}
}
