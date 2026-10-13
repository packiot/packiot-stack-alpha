//go:build golden

// Hourly production-day label (invariant K7, 2026-10-13). The legacy
// piot_create_equipment_oee_hourly labelled each future hour bucket with the
// production day of `now() + i hours` — NOT truncated to the hour — and re-wrote
// the label on every run. For a day that begins off the hour (CPACK: day_begin =
// -3000 s → 23:10 America/Sao_Paulo = 02:10 UTC) the boundary bucket [02:00, 03:00)
// UTC therefore took the day of the run's minute: a run at :05 named the OLD day, a
// run at :45 the NEW one. The engine ran it at an arbitrary minute, so production
// days carried 23 or 25 hour rows.
//
// The engine-owned provisionHourlySQL labels a bucket with the day containing
// bucket + 59 min (legacy prod ran at minute > 58 — same answer, now explicit). The
// fixture uses the REAL piot_get_day_begin_by_equipment body (F3 snapshot) so the
// day boundary is the production function's, not a stub.
//
// Proves: (a) the boundary bucket gets the new day whatever the run minute,
// (b) re-runs are idempotent (0 rows rewritten, labels stable, a wrong label
// left by the old bug is corrected, customized targets kept), (c) on-the-hour
// tenants are unchanged vs the legacy expression and every day has 24 rows,
// (d) the hour→day cascade flags the day the hour is labelled with.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run GoldenProvisionHourly
package rollup

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

const provisionLabelFixture = `
	DROP SCHEMA IF EXISTS gplab CASCADE;
	CREATE SCHEMA gplab;
	CREATE TABLE gplab.enterprises (id_enterprise int PRIMARY KEY, active boolean);
	CREATE TABLE gplab.sites (id_site int PRIMARY KEY, id_enterprise int, timezone text, day_begin int);
	CREATE TABLE gplab.areas (id_area int PRIMARY KEY, id_site int, id_enterprise int, day_begin int);
	CREATE TABLE gplab.equipments (id_equipment int PRIMARY KEY, id_site int, id_area int, id_enterprise int, tp_equipment int);
	CREATE TABLE gplab.production_targets (id_equipment int, vl_day int, vl_hour int);
	CREATE TABLE gplab.equipment_oee_hourly (
	    id_equipment int NOT NULL, ts_value timestamptz NOT NULL,
	    target double precision DEFAULT 0, target_customized boolean DEFAULT false,
	    ts_value_production date, recalc_needed boolean DEFAULT false,
	    PRIMARY KEY (id_equipment, ts_value));
	CREATE TABLE gplab.equipment_oee_daily (
	    id_equipment int NOT NULL, ts_value date NOT NULL, recalc_needed boolean DEFAULT false,
	    PRIMARY KEY (id_equipment, ts_value));
	-- The production day-boundary function, body verbatim from the F3 snapshot
	-- (db/init-f3/snapshot/00-packiot_analytics-schema.sql): area day_begin first, site fallback.
	CREATE FUNCTION gplab.piot_get_day_begin_by_equipment(in_id_equipment integer, in_ts_value timestamp with time zone)
	  RETURNS TABLE(ts_value timestamp with time zone, ts_value_production date) LANGUAGE plpgsql STABLE AS $f$
	declare
	    in_id_site int := (select id_site from equipments s where s.id_equipment=in_id_equipment );
	    in_id_area int := (select id_area from equipments s where s.id_equipment=in_id_equipment );
	begin
	 return query
	    select s1.ts_value, s1.ts_value_production from
	    (
	    select date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone)) - interval '1 second' * (s.day_begin) ) at time zone (s.timezone) + interval '1 second' * (s.day_begin) as ts_value,
	           date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone) - interval '1 second' * (s.day_begin)))::date as ts_value_production,
	           null as id_area, id_site
	      from sites s where id_site = in_id_site
	    union all
	    select date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone)) - interval '1 second' * (a.day_begin)) at time zone (s.timezone) + interval '1 second' * (a.day_begin) as ts_value,
	           date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone) - interval '1 second' * (a.day_begin)))::date as ts_value_production,
	           a.id_area, s.id_site
	      from areas a join sites s on a.id_site = s.id_site where a.id_area = in_id_area
	    order by id_area, id_site limit 1
	    ) s1;
	end
	$f$;
	-- ent 3: day begins 23:10 local (-3000 s, the CPACK shape); ent 5: 06:00 local (on the hour);
	-- ent 9: inactive (never provisioned).
	INSERT INTO gplab.enterprises VALUES (3, true), (5, true), (9, false);
	INSERT INTO gplab.sites VALUES (30, 3, 'America/Sao_Paulo', -3000), (50, 5, 'America/Sao_Paulo', 21600), (90, 9, 'UTC', 0);
	INSERT INTO gplab.areas VALUES (31, 30, 3, -3000), (51, 50, 5, 21600), (91, 90, 9, 0);
	INSERT INTO gplab.equipments VALUES (300, 30, 31, 3, 3), (500, 50, 51, 5, 3), (900, 90, 91, 9, 3);
	INSERT INTO gplab.production_targets VALUES (300, 2400, NULL), (500, 0, 7);
	-- A future row the OLD code left with the wrong label (the 02:00 UTC boundary bucket
	-- labelled with the previous day), with an operator-customized target.
	INSERT INTO gplab.equipment_oee_hourly (id_equipment, ts_value, target, target_customized, ts_value_production)
	VALUES (300, '2026-10-10 02:00+00', 55, true, '2026-10-09');`

func TestGoldenProvisionHourlyLabel(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, provisionLabelFixture); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	d := flows.Dest{Name: "gplab", EvSchema: "gplab", RefSchema: "gplab", SilverSchema: "gplab",
		GoldSchema: "gplab", GrainSchema: "gplab", ConfigSchema: "gplab"}
	stmt := provisionHourlyStmt(d)

	// run provisions as if the job fired at `at`; returns rows inserted+updated.
	run := func(at string) int64 {
		t.Helper()
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, `SET LOCAL search_path TO gplab, public`); err != nil {
			t.Fatal(err)
		}
		// The bug lived in the session-TZ-dependent cast; pin the env's value.
		if _, err := tx.Exec(ctx, `SET LOCAL TimeZone = 'UTC'`); err != nil {
			t.Fatal(err)
		}
		tag, err := tx.Exec(ctx, stmt, at)
		if err != nil {
			t.Fatalf("provision at %s: %v", at, err)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
		return tag.RowsAffected()
	}
	label := func(eq int, ts string) string {
		t.Helper()
		var s string
		if err := pool.QueryRow(ctx, `SELECT COALESCE(ts_value_production::text, 'NULL') FROM gplab.equipment_oee_hourly
		                               WHERE id_equipment = $1 AND ts_value = $2::timestamptz`, eq, ts).Scan(&s); err != nil {
			t.Fatalf("label %d@%s: %v", eq, ts, err)
		}
		return s
	}

	// NEGATIVE CONTROL — the legacy expression really is run-minute dependent: for the
	// 2026-10-09 02:00 UTC bucket of a 23:10-local day, a run at :05 names the old day.
	var legacyAt05, legacyAt45 string
	if err := pool.QueryRow(ctx, `
		SELECT (date_trunc('day', ($1::timestamptz) AT TIME ZONE 'America/Sao_Paulo' - interval '1 second' * -3000)
		        AT TIME ZONE 'America/Sao_Paulo' + interval '1 second' * -3000)::date::text,
		       (date_trunc('day', ($2::timestamptz) AT TIME ZONE 'America/Sao_Paulo' - interval '1 second' * -3000)
		        AT TIME ZONE 'America/Sao_Paulo' + interval '1 second' * -3000)::date::text`,
		"2026-10-09 02:05+00", "2026-10-09 02:45+00").Scan(&legacyAt05, &legacyAt45); err != nil {
		t.Fatal(err)
	}
	if legacyAt05 != "2026-10-08" || legacyAt45 != "2026-10-09" {
		t.Fatalf("negative control: legacy labels %s/%s, want 2026-10-08/2026-10-09 — fixture no longer reproduces the bug", legacyAt05, legacyAt45)
	}

	// (a) boundary bucket 2026-10-09 02:00 UTC (= 23:00 local, day begins 23:10) → the NEW
	// day 2026-10-09, whether the run fires at :05 or :45, in the bucket's own hour or the hour before.
	const boundary = "2026-10-09 02:00+00"
	for i, at := range []string{"2026-10-09 01:05+00", "2026-10-09 01:45+00", "2026-10-09 02:05+00", "2026-10-09 02:45+00"} {
		if n := run(at); i == 0 && n == 0 {
			t.Fatalf("first run at %s provisioned nothing", at)
		}
		if got := label(300, boundary); got != "2026-10-09" {
			t.Errorf("run at %s: boundary bucket labelled %s, want 2026-10-09 (minute-59 rule)", at, got)
		}
		// The bucket before belongs entirely to the previous day.
		if at < "2026-10-09 02:00" {
			if got := label(300, "2026-10-09 01:00+00"); got != "2026-10-08" {
				t.Errorf("run at %s: 01:00 bucket labelled %s, want 2026-10-08", at, got)
			}
		}
	}

	// (b) idempotent: the same run again rewrites nothing; a different minute changes nothing.
	if n := run("2026-10-09 02:45+00"); n != 0 {
		t.Errorf("re-run at the same instant rewrote %d rows, want 0 (label must not depend on run time)", n)
	}
	if n := run("2026-10-09 02:05+00"); n != 0 {
		t.Errorf("re-run at another minute of the same hour rewrote %d rows, want 0", n)
	}
	// The wrong label the old code left on a future row is corrected; its customized target kept.
	if got := label(300, "2026-10-10 02:00+00"); got != "2026-10-10" {
		t.Errorf("pre-existing mislabelled future bucket = %s, want corrected to 2026-10-10", got)
	}
	var tgt300, tgt500 float64
	if err := pool.QueryRow(ctx, `SELECT target FROM gplab.equipment_oee_hourly WHERE id_equipment = 300 AND ts_value = '2026-10-10 02:00+00'`).Scan(&tgt300); err != nil {
		t.Fatal(err)
	}
	if tgt300 != 55 {
		t.Errorf("customized target overwritten: %v, want 55", tgt300)
	}
	if err := pool.QueryRow(ctx, `SELECT target FROM gplab.equipment_oee_hourly WHERE id_equipment = 500 AND ts_value = '2026-10-10 02:00+00'`).Scan(&tgt500); err != nil {
		t.Fatal(err)
	}
	if tgt500 != 7 {
		t.Errorf("non-customized target = %v, want vl_hour 7", tgt500)
	}
	// Horizon = current hour + 722 (legacy), inactive enterprise skipped.
	var n300, n900 int
	if err := pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE id_equipment = 300 AND ts_value >= '2026-10-09 02:00+00' AND ts_value < '2026-10-09 02:00+00'::timestamptz + interval '723 hours'),
	                                     count(*) FILTER (WHERE id_equipment = 900) FROM gplab.equipment_oee_hourly`).Scan(&n300, &n900); err != nil {
		t.Fatal(err)
	}
	if n300 != 723 || n900 != 0 {
		t.Errorf("horizon rows eq300 = %d (want 723), inactive eq900 = %d (want 0)", n300, n900)
	}

	// Every complete production day now has exactly 24 hour rows — for both tenants.
	rows, err := pool.Query(ctx, `
		SELECT id_equipment, ts_value_production::text, count(*) FROM gplab.equipment_oee_hourly
		 WHERE ts_value_production BETWEEN '2026-10-10' AND '2026-11-05' GROUP BY 1, 2 HAVING count(*) <> 24`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var eq, n int
		var day string
		if err := rows.Scan(&eq, &day, &n); err != nil {
			t.Fatal(err)
		}
		t.Errorf("eq %d day %s has %d hour rows, want 24", eq, day, n)
	}
	rows.Close()

	// (c) on-the-hour tenant (06:00 local): the label equals the legacy expression evaluated
	// at ANY minute of the bucket — nothing changes for tenants unaffected by the bug.
	var diff int
	if err := pool.QueryRow(ctx, `
		SELECT count(*) FROM gplab.equipment_oee_hourly h, generate_series(0, 59, 5) m
		 WHERE h.id_equipment = 500
		   AND h.ts_value_production IS DISTINCT FROM
		       (date_trunc('day', (h.ts_value + m * interval '1 minute') AT TIME ZONE 'America/Sao_Paulo' - interval '1 second' * 21600)
		        AT TIME ZONE 'America/Sao_Paulo' + interval '1 second' * 21600)::date`).Scan(&diff); err != nil {
		t.Fatal(err)
	}
	if diff != 0 {
		t.Errorf("on-the-hour tenant: %d (bucket, minute) labels differ from legacy, want 0", diff)
	}

	// (d) the hour→day cascade flags the day the boundary hour is LABELLED with (2026-10-09),
	// not the day of its start instant (2026-10-08) — blocking (backfill) and live variants.
	// A row with no label falls back to the same bucket+59min rule.
	if _, err := pool.Exec(ctx, `
		INSERT INTO gplab.equipment_oee_hourly (id_equipment, ts_value, ts_value_production)
		VALUES (300, '2026-10-08 02:00+00', NULL);
		INSERT INTO gplab.equipment_oee_daily (id_equipment, ts_value)
		SELECT 300, d::date FROM generate_series('2026-10-06'::date, '2026-10-10'::date, interval '1 day') d`); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ name, sql string }{
		{"blocking", fmtRP(hourCascadeDaySQL, "gplab")},
		{"live", fmtRP(hourCascadeDayLiveSQL, "gplab")},
	} {
		for _, bucket := range []struct{ ts, want string }{
			{"2026-10-09 02:00+00", "2026-10-09"}, // provisioned label
			{"2026-10-08 02:00+00", "2026-10-08"}, // NULL label → bucket+59min fallback
		} {
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			for _, s := range []string{
				`SET LOCAL search_path TO gplab, public`,
				`UPDATE gplab.equipment_oee_daily SET recalc_needed = false`,
				`CREATE TEMP TABLE hour_elig ON COMMIT DROP AS SELECT 300 AS id_equipment, '` + bucket.ts + `'::timestamptz AS ts_value`,
				c.sql,
			} {
				if _, err := tx.Exec(ctx, s); err != nil {
					tx.Rollback(ctx)
					t.Fatalf("%s cascade: %v", c.name, err)
				}
			}
			var flagged []string
			r, err := tx.Query(ctx, `SELECT ts_value::text FROM gplab.equipment_oee_daily WHERE recalc_needed ORDER BY 1`)
			if err != nil {
				t.Fatal(err)
			}
			for r.Next() {
				var s string
				if err := r.Scan(&s); err != nil {
					t.Fatal(err)
				}
				flagged = append(flagged, s)
			}
			r.Close()
			tx.Rollback(ctx)
			if len(flagged) != 1 || flagged[0] != bucket.want {
				t.Errorf("%s cascade for bucket %s flagged %v, want [%s]", c.name, bucket.ts, flagged, bucket.want)
			}
		}
	}
}
