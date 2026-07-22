//go:build golden

// Behavioural proof for the task #59 day-rollup over-mint clamp.
//
// Root cause: dayRollupSQL sums the :00-aligned HOUR grain into the
// production-day. When a site's day_begin is NOT hour-aligned (e.g.
// 02:10), a 24h production-day straddles 25 whole hour buckets, so the
// naked sum reaches 25×3600 = 90000s — impossible (> 86400). The fix
// caps each additive time metric at the TRUE per-equipment day length
// (next anchor − this anchor), which is DST-aware (90000 / 82800s).
//
// This test simulates the day length by stubbing the day-boundary
// function from a per-equipment config table, so it needs no real
// timezone/DST calendar — the session runs in UTC and the length is
// injected directly. Three scenarios:
//
//	201 — over-mint, true length 86400, 25×3600 buckets
//	      ⇒ naked sum 90000 must be CAPPED to 86400; counts untouched.
//	202 — partial day (20 buckets) below the length
//	      ⇒ sums UNCHANGED (clamp is a no-op on correct data).
//	203 — DST fall-back, true length 90000, 25×3600 buckets summing
//	      to 90000 ⇒ must stay 90000, NOT be mis-clamped to 86400.
//
// TYPE FIDELITY (task #93): the real equipment_runtime_1day.ts_value is
// DATE and the real piot_get_day_begin_by_equipment returns ts_value
// (timestamptz anchor) + ts_value_production (DATE). An earlier version
// of this fixture typed both as timestamptz, which let the buggy
// `ts_value_production - d.ts_value` resolve to `timestamptz - timestamptz`
// = interval and pass — masking the production `date - date` = integer /
// `extract(epoch FROM integer)` 42883 crash. The stub below now mirrors
// the real return types so day_len_s is exercised on the true type path.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run DayOverMintClamp
package rollup

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const dayClampSchema = `
	DROP SCHEMA IF EXISTS dayclamp CASCADE;
	CREATE SCHEMA dayclamp;
	SET search_path TO dayclamp, public;

	CREATE TABLE dayclamp.equipments (
	    id_equipment int PRIMARY KEY,
	    id_site int, id_area int, id_enterprise int, tp_equipment int
	);
	CREATE TABLE dayclamp.equipment_runtime_1day (
	    id_equipment int, ts_value date,
	    target_customized boolean DEFAULT false, recalc_needed boolean DEFAULT true,
	    oee double precision,
	    oee_a double precision, oee_p double precision, oee_q double precision,
	    available_time double precision, running_time double precision,
	    stopped_time double precision, planned_downtime double precision,
	    ideal_production double precision, target double precision,
	    gross double precision, net double precision, downtime double precision,
	    changeover_time double precision, scrap double precision, speed double precision,
	    proportional_target double precision
	);
	CREATE TABLE dayclamp.equipment_runtime_1hour (
	    id_equipment int, ts_value timestamptz, ts_value_production date,
	    available_time double precision, running_time double precision,
	    stopped_time double precision, planned_downtime double precision,
	    ideal_production double precision, target double precision,
	    gross double precision, net double precision, downtime double precision,
	    changeover_time double precision, scrap double precision, speed double precision,
	    proportional_target double precision
	);

	-- Injected TRUE production-day length per equipment (seconds). The
	-- stub returns, for the production date D containing t (D =
	-- date_trunc('day', t)::date — the calls only ever pass midnights, so
	-- this is exact), a timestamptz anchor whose value grows by true_len_s
	-- per calendar day: anchor(D) = 2000-01-01 + (D − 2000-01-01)·true_len_s.
	-- Consecutive anchors therefore differ by exactly true_len_s, so the
	-- two-call day_len_s expression epoch(anchor(D+1) − anchor(D)) yields
	-- true_len_s. ts_value_production is DATE, matching the real fn — this
	-- is what makes (date - date) reachable if the code ever regresses.
	CREATE TABLE dayclamp.day_len_cfg (id_equipment int PRIMARY KEY, true_len_s double precision);
	CREATE FUNCTION dayclamp.piot_get_day_begin_by_equipment(eq int, t timestamptz)
	  RETURNS TABLE (ts_value timestamptz, ts_value_production date)
	  AS $$
	    SELECT
	      TIMESTAMPTZ '2000-01-01 00:00:00+00'
	        + make_interval(secs => (date_trunc('day', t)::date - DATE '2000-01-01')
	                                * (SELECT true_len_s FROM dayclamp.day_len_cfg WHERE id_equipment = eq)),
	      date_trunc('day', t)::date;
	  $$ LANGUAGE sql;`

func TestDayOverMintClampBehaviour(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	if _, err := pool.Exec(ctx, dayClampSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}

	// Anchors (UTC). 201 is deliberately NOT hour-aligned (02:10).
	const setup = `
		SET search_path TO dayclamp, public;
		INSERT INTO dayclamp.equipments VALUES
		    (201,1,1,1,3),(202,1,1,1,3),(203,1,1,1,3);
		INSERT INTO dayclamp.day_len_cfg VALUES
		    (201, 86400),   -- normal-length day, but non-hour-aligned begin
		    (202, 86400),   -- normal, hour-aligned
		    (203, 90000);   -- DST fall-back: legitimately 25h

		-- Day rows (yesterday-ish so they are eligible, < now()+len anchor).
		-- ts_value is DATE (the production-date key) — the 25th straddling
		-- hour bucket that drives the over-mint comes from the hour grain,
		-- not from a non-midnight day key (which a DATE column cannot hold).
		INSERT INTO dayclamp.equipment_runtime_1day (id_equipment, ts_value) VALUES
		    (201, (now() - interval '2 days')::date),
		    (202, (now() - interval '2 days')::date),
		    (203, (now() - interval '2 days')::date);

		-- 201: 25 buckets × (3600 available, 3600 running, 3600 stopped,
		-- 3600 downtime) ⇒ each sums to 90000 (impossible). Counts:
		-- net 100, gross 120 per bucket ⇒ 2500 / 3000 (must NOT clamp).
		INSERT INTO dayclamp.equipment_runtime_1hour
		    (id_equipment, ts_value, ts_value_production,
		     available_time, running_time, stopped_time, downtime,
		     planned_downtime, ideal_production, target, gross, net, changeover_time, scrap, speed, proportional_target)
		SELECT 201,
		       date_trunc('day', now() - interval '2 days') + make_interval(hours => g),
		       (now() - interval '2 days')::date,
		       3600, 3600, 3600, 3600, 0, 200, 10, 120, 100, 0, 0, 50, 0
		  FROM generate_series(0, 24) g;

		-- 202: PARTIAL day — 20 buckets. available 3600, running 3000,
		-- stopped 600, downtime 600 ⇒ 72000/60000/12000/12000, all below
		-- 86400 ⇒ clamp must be a no-op.
		INSERT INTO dayclamp.equipment_runtime_1hour
		    (id_equipment, ts_value, ts_value_production,
		     available_time, running_time, stopped_time, downtime,
		     planned_downtime, ideal_production, target, gross, net, changeover_time, scrap, speed, proportional_target)
		SELECT 202,
		       date_trunc('day', now() - interval '2 days') + make_interval(hours => g),
		       (now() - interval '2 days')::date,
		       3600, 3000, 600, 600, 0, 200, 10, 120, 100, 0, 0, 50, 0
		  FROM generate_series(0, 19) g;

		-- 203: DST fall-back, 25 buckets × 3600 available/running ⇒ 90000,
		-- day_len_s is also 90000 ⇒ LEAST(90000, 90000) = 90000 (kept).
		INSERT INTO dayclamp.equipment_runtime_1hour
		    (id_equipment, ts_value, ts_value_production,
		     available_time, running_time, stopped_time, downtime,
		     planned_downtime, ideal_production, target, gross, net, changeover_time, scrap, speed, proportional_target)
		SELECT 203,
		       date_trunc('day', now() - interval '2 days') + make_interval(hours => g),
		       (now() - interval '2 days')::date,
		       3600, 3600, 1800, 1800, 0, 200, 10, 120, 100, 0, 0, 50, 0
		  FROM generate_series(0, 24) g;`

	if _, err := pool.Exec(ctx, setup); err != nil {
		t.Fatalf("fixture: %v", err)
	}

	// Run eligible + rollup in one tx (temp table is ON COMMIT DROP).
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SET LOCAL search_path TO dayclamp, public`); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(dayEligibleSQL, "dayclamp", "dayclamp"), []int{}, []int{}); err != nil {
		t.Fatalf("eligible: %v", err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(dayRollupSQL, "dayclamp")); err != nil {
		t.Fatalf("rollup: %v", err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	type day struct {
		avail, running, stopped, downtime, gross, net float64
	}
	get := func(id int) day {
		var d day
		if err := pool.QueryRow(ctx, `
			SELECT available_time, running_time, stopped_time, downtime, gross, net
			  FROM dayclamp.equipment_runtime_1day WHERE id_equipment = $1`, id).
			Scan(&d.avail, &d.running, &d.stopped, &d.downtime, &d.gross, &d.net); err != nil {
			t.Fatalf("get %d: %v", id, err)
		}
		return d
	}

	// (a) Non-hour-aligned over-mint: naked sum 90000 must be capped to
	// the TRUE length 86400 for every additive time metric — and NEVER
	// exceed it. Counts (gross/net) are untouched by the clamp.
	d201 := get(201)
	for name, v := range map[string]float64{"available_time": d201.avail, "running_time": d201.running, "stopped_time": d201.stopped, "downtime": d201.downtime} {
		if v > 86400 {
			t.Errorf("201 %s = %v — over-mint NOT capped (must be <= true day length 86400)", name, v)
		}
		if v != 86400 {
			t.Errorf("201 %s = %v — expected exactly 86400 (90000 capped to true length)", name, v)
		}
	}
	if d201.gross != 3000 || d201.net != 2500 {
		t.Errorf("201 counts clamped by mistake: gross=%v net=%v (want 3000/2500 — counts are NOT time)", d201.gross, d201.net)
	}

	// (b) Hour-aligned, sub-length day: clamp is a no-op, sums exact.
	d202 := get(202)
	if d202.avail != 72000 || d202.running != 60000 || d202.stopped != 12000 || d202.downtime != 12000 {
		t.Errorf("202 hour-aligned day changed by clamp: %+v (want 72000/60000/12000/12000)", d202)
	}

	// (c) DST fall-back day (true length 90000): a legit 90000s day must
	// survive — NOT be wrongly clamped to 86400.
	d203 := get(203)
	if d203.avail != 90000 {
		t.Errorf("203 DST available_time = %v — a legit 90000s day was mis-clamped (must NOT be 86400)", d203.avail)
	}
	if d203.running != 90000 {
		t.Errorf("203 DST running_time = %v — expected 90000 (LEAST(90000, 90000))", d203.running)
	}
}
