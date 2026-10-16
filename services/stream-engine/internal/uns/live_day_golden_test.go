//go:build golden

// Golden regression for the LIVE DAY key (2026-10-13): area_live_day /
// equipment_live_day must carry the CURRENT PRODUCTION DAY's row — the label the
// shift calendar gives (piot_get_day_begin_by_*), not the UTC calendar date.
// CPACK's production day begins 02:10 UTC, so from UTC midnight to 02:10 the
// running day still carries YESTERDAY's label while the UTC-dated row is the next,
// not-yet-started day (zeros). The stubs below model exactly that window.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/uns -run LiveDay
package uns

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const liveDaySchema = `
	DROP SCHEMA IF EXISTS golden_uns CASCADE;
	CREATE SCHEMA golden_uns;
	CREATE TABLE golden_uns.enterprises (id_enterprise int, active boolean);
	CREATE TABLE golden_uns.areas (id_area int, id_enterprise int);
	CREATE TABLE golden_uns.equipments (id_equipment int, id_area int, id_enterprise int, tp_equipment int);
	CREATE TABLE golden_uns.area_oee_daily (
	    id_area int, ts_value date, gross real, net real, scrap real, speed real,
	    oee real, oee_p real, oee_a real, oee_q real, available_time int, running_time int,
	    stopped_time int, planned_downtime int, ideal_production double precision,
	    idle_time int, idle_starved int, idle_blocked int, target double precision,
	    proportional_target double precision);
	CREATE TABLE golden_uns.equipment_oee_daily (LIKE golden_uns.area_oee_daily);
	ALTER TABLE golden_uns.equipment_oee_daily RENAME COLUMN id_area TO id_equipment;
	CREATE TABLE golden_uns.area_live_day (
	    id_area int, oee real, oee_a real, oee_p real, oee_q real,
	    gross_production real, net_production real, scrap real, target real,
	    begin_time date, end_time date, idle_time int, elapsed_time int,
	    idle_blocked int, idle_starved int, running_time int, stopped_time int,
	    available_time int, planned_downtime int, ideal_production real,
	    proportional_target real, proportional_ideal_production real);
	CREATE TABLE golden_uns.equipment_live_day (LIKE golden_uns.area_live_day);
	ALTER TABLE golden_uns.equipment_live_day RENAME COLUMN id_area TO id_equipment;
	ALTER TABLE golden_uns.equipment_live_day ADD COLUMN speed real, ADD COLUMN last_updated timestamptz;
	-- stub anchors: the running production day began yesterday 02:10 UTC and carries
	-- YESTERDAY's label (the CPACK 00:00–02:10 UTC window, held for the whole test).
	CREATE FUNCTION golden_uns.piot_get_day_begin_by_area(a int, t timestamptz)
	  RETURNS TABLE (ts_value timestamptz, ts_value_production date)
	  AS 'SELECT date_trunc(''day'', $2) - interval ''1 day'' + interval ''2 hours 10 minutes'', ($2 - interval ''1 day'')::date' LANGUAGE sql;
	CREATE FUNCTION golden_uns.piot_get_day_begin_by_equipment(e int, t timestamptz)
	  RETURNS TABLE (ts_value timestamptz, ts_value_production date)
	  AS 'SELECT date_trunc(''day'', $2) - interval ''1 day'' + interval ''2 hours 10 minutes'', ($2 - interval ''1 day'')::date' LANGUAGE sql;

	INSERT INTO golden_uns.enterprises VALUES (3, true);
	INSERT INTO golden_uns.areas VALUES (10, 3);
	INSERT INTO golden_uns.equipments VALUES (47, 10, 3, 3), (53, 10, 3, 1);
	-- running production day (yesterday's label) has the live numbers; the UTC-dated
	-- row is the next production day, provisioned with zeros.
	INSERT INTO golden_uns.area_oee_daily (id_area, ts_value, gross, net, scrap, oee)
	VALUES (10, current_date - 1, 177254, 162383, 14871, 0.61), (10, current_date, 0, 0, 0, 0);
	INSERT INTO golden_uns.equipment_oee_daily (id_equipment, ts_value, gross, net, scrap, oee)
	VALUES (47, current_date - 1, 121759, 116624, 5135, 0.59), (47, current_date, 0, 0, 0, 0);
	INSERT INTO golden_uns.area_live_day (id_area) VALUES (10);
	INSERT INTO golden_uns.equipment_live_day (id_equipment) VALUES (47), (53);`

func TestGoldenLiveDayIsProductionDay(t *testing.T) {
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
	cfg.ConnConfig.RuntimeParams["search_path"] = "golden_uns, public"
	cfg.ConnConfig.RuntimeParams["timezone"] = "UTC"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, liveDaySchema); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	defer pool.Exec(context.Background(), `DROP SCHEMA IF EXISTS golden_uns CASCADE`) //nolint:errcheck

	if _, err := pool.Exec(ctx, fmt.Sprintf(refreshDayAreaSQL, "golden_uns", "golden_uns", "golden_uns")); err != nil {
		t.Fatalf("area day refresh: %v", err)
	}
	if _, err := pool.Exec(ctx, fmt.Sprintf(refreshDayEquipmentSQL, "golden_uns", "golden_uns", "golden_uns"), []int{}, []int{}); err != nil {
		t.Fatalf("equipment day refresh: %v", err)
	}

	type live struct {
		gross, net *float64
		begin      *time.Time
		elapsed    *int32
	}
	read := func(q string) live {
		t.Helper()
		var l live
		if err := pool.QueryRow(ctx, q).Scan(&l.gross, &l.net, &l.begin, &l.elapsed); err != nil {
			t.Fatal(err)
		}
		return l
	}
	wantDay := time.Now().UTC().AddDate(0, 0, -1).Format("2006-01-02")
	check := func(name string, l live, gross, net float64) {
		t.Helper()
		if l.gross == nil || *l.gross != gross || l.net == nil || *l.net != net {
			t.Errorf("%s: gross/net = %v/%v, want %v/%v (the running production day)", name, deref(l.gross), deref(l.net), gross, net)
		}
		if l.begin == nil || l.begin.UTC().Format("2006-01-02") != wantDay {
			t.Errorf("%s: begin_time = %v, want production-day label %s (not the UTC date)", name, l.begin, wantDay)
		}
		if l.elapsed == nil || *l.elapsed <= 0 {
			t.Errorf("%s: elapsed_time = %v, want > 0 seconds since the production-day begin", name, l.elapsed)
		}
	}
	check("area_live_day", read(`SELECT gross_production::float8, net_production::float8, begin_time::timestamptz, elapsed_time FROM golden_uns.area_live_day WHERE id_area = 10`), 177254, 162383)
	check("equipment_live_day", read(`SELECT gross_production::float8, net_production::float8, begin_time::timestamptz, elapsed_time FROM golden_uns.equipment_live_day WHERE id_equipment = 47`), 121759, 116624)

	// tp_equipment = 1 machines are outside the live-day population (unchanged contract).
	var machineGross *float64
	if err := pool.QueryRow(ctx, `SELECT gross_production::float8 FROM golden_uns.equipment_live_day WHERE id_equipment = 53`).Scan(&machineGross); err != nil {
		t.Fatal(err)
	}
	if machineGross != nil {
		t.Errorf("machine (tp=1) live day was written: %v", *machineGross)
	}
}

func deref(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}
