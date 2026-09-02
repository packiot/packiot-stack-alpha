// port-parity — the differential-testing harness (PORTING.md upgrade
// #1): run the LEGACY PL/pgSQL and the GO port against IDENTICAL
// input snapshots in two sandbox schemas, then row-diff the outputs.
// Converts equivalence ARGUMENTS into MEASUREMENTS.
//
// Mechanics per subject:
//
//	snapshot: copy input tables into parity_legacy + parity_go
//	legacy:   SET search_path TO parity_legacy, public; SELECT fn()
//	          (PL/pgSQL resolves unqualified names at execution)
//	go:       the port's own SQL const with schema params = parity_go
//	diff:     FULL JOIN on the natural key, numeric tolerance
//
// Subjects registry below — one entry per ported unit. First subject:
// po-runtime-recalc vs piot_get_equipment_production_order_runtime_final.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/rollup"
)

const (
	legacySchema = "parity_legacy"
	goSchema     = "parity_go"
)

// recalc subject: input tables + legacy call + output diff.
var recalcSnapshotSQL = []string{
	// fresh sandboxes
	`DROP SCHEMA IF EXISTS ` + legacySchema + ` CASCADE`,
	`DROP SCHEMA IF EXISTS ` + goSchema + ` CASCADE`,
	`CREATE SCHEMA ` + legacySchema,
	`CREATE SCHEMA ` + goSchema,
	// identical input snapshots (source: public = staging F1, where the
	// legacy engine's data lives). Window matches the port's default.
	`CREATE TABLE ` + legacySchema + `.production_orders AS
	   SELECT * FROM public.production_orders
	    WHERE ts_start >= now() - interval '1 month' AND status > 1`,
	`CREATE TABLE ` + legacySchema + `.production_orders_runtime AS
	   SELECT r.* FROM public.production_orders_runtime r
	    JOIN ` + legacySchema + `.production_orders p USING (id_production_order)`,
	`CREATE TABLE ` + legacySchema + `.equipments AS SELECT * FROM public.equipments`,
	`CREATE TABLE ` + legacySchema + `.sites AS SELECT * FROM public.sites`,
	// force every snapshot PO into the recalc set (deterministic input)
	`UPDATE ` + legacySchema + `.production_orders SET recalc_needed = true`,
	`CREATE TABLE ` + goSchema + `.production_orders AS SELECT * FROM ` + legacySchema + `.production_orders`,
	`CREATE TABLE ` + goSchema + `.production_orders_runtime AS SELECT * FROM ` + legacySchema + `.production_orders_runtime`,
	`CREATE TABLE ` + goSchema + `.equipments AS SELECT * FROM ` + legacySchema + `.equipments`,
	`CREATE TABLE ` + goSchema + `.sites AS SELECT * FROM ` + legacySchema + `.sites`,
	// CREATE TABLE AS copies NO indexes — without prod-like keys the
	// legacy per-PO loop goes O(n²) and hits statement_timeout (the
	// harness accidentally benchmarked the refactor's point). Restore
	// the access paths prod has:
	`ALTER TABLE ` + legacySchema + `.production_orders ADD PRIMARY KEY (id_production_order)`,
	`ALTER TABLE ` + goSchema + `.production_orders ADD PRIMARY KEY (id_production_order)`,
	`CREATE INDEX ON ` + legacySchema + `.production_orders_runtime (id_production_order)`,
	`CREATE INDEX ON ` + goSchema + `.production_orders_runtime (id_production_order)`,
	`CREATE INDEX ON ` + legacySchema + `.equipments (id_equipment)`,
	`CREATE INDEX ON ` + goSchema + `.equipments (id_equipment)`,
}

const recalcLegacyRun = `SELECT piot_get_equipment_production_order_runtime_final()`

// The diff: numeric OEE outputs compared with tolerance; text verdict.
const recalcDiffSQL = `
	SELECT count(*) FILTER (WHERE NOT ok) AS mismatches,
	       count(*)                        AS compared
	  FROM (
	    SELECT l.id_production_order,
	           (COALESCE(l.gross_production,-1) = COALESCE(g.gross_production,-1)
	        AND COALESCE(l.net_production,-1)   = COALESCE(g.net_production,-1)
	        AND abs(COALESCE(l.oee,0)              - COALESCE(g.oee,0))              < 1e-9
	        AND abs(COALESCE(l.oee_quality,0)      - COALESCE(g.oee_quality,0))      < 1e-9
	        AND abs(COALESCE(l.oee_availability,0) - COALESCE(g.oee_availability,0)) < 1e-9
	        AND abs(COALESCE(l.oee_performance,0)  - COALESCE(g.oee_performance,0))  < 1e-9
	        AND (l.recalc_needed = g.recalc_needed
	             -- boundary guard: the 48h re-flag reads now(), which
	             -- ADVANCES between the legacy and go runs; POs within
	             -- ±20min of the boundary race by construction (the legacy
	             -- loop runs for minutes; epsilon must exceed run gap), not by
	             -- logic. Values above are always compared.
	             OR abs(extract(epoch FROM (l.ts_start - (now() - interval '48 hours')))) < 1200)) AS ok
	      FROM ` + legacySchema + `.production_orders l
	      FULL JOIN ` + goSchema + `.production_orders g USING (id_production_order)
	  ) d`

const recalcMismatchDetail = `
	SELECT l.id_production_order,
	       l.oee AS legacy_oee, g.oee AS go_oee,
	       l.oee_performance AS legacy_perf, g.oee_performance AS go_perf,
	       l.recalc_needed AS legacy_flag, g.recalc_needed AS go_flag
	  FROM ` + legacySchema + `.production_orders l
	  FULL JOIN ` + goSchema + `.production_orders g USING (id_production_order)
	 WHERE NOT (abs(COALESCE(l.oee,0) - COALESCE(g.oee,0)) < 1e-9
	        AND abs(COALESCE(l.oee_performance,0) - COALESCE(g.oee_performance,0)) < 1e-9
	        AND (l.recalc_needed = g.recalc_needed
	             OR abs(extract(epoch FROM (l.ts_start - (now() - interval '48 hours')))) < 1200))
	 LIMIT 10`

func main() {
	subject := flag.String("subject", "recalc", "parity subject")
	dsn := flag.String("dsn", os.Getenv("PARITY_DSN"), "postgres dsn (staging main DB)")
	emit := flag.Bool("emit", false, "print the run as one psql script (same consts) and exit")
	flag.Parse()
	if *emit {
		switch *subject {
		case "compute":
			emitComputeScript()
		case "hour":
			emitHourScript()
		case "day":
			emitDayScript()
		case "shift":
			emitShiftScript()
		default:
			emitRecalcScript()
		}
		return
	}
	if *subject != "recalc" {
		fmt.Fprintln(os.Stderr, "unknown subject")
		os.Exit(2)
	}
	ctx := context.Background()
	pc, err := pgxpool.ParseConfig(*dsn)
	fatal(err)
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	fatal(err)
	defer pool.Close()

	fmt.Println("== snapshot")
	for _, s := range recalcSnapshotSQL {
		_, err := pool.Exec(ctx, s)
		fatal(err)
	}

	fmt.Println("== legacy run (search_path sandbox)")
	// One session: search_path must live on the same connection as the call.
	conn, err := pool.Acquire(ctx)
	fatal(err)
	_, err = conn.Exec(ctx, `SET search_path TO `+legacySchema+`, public`)
	fatal(err)
	_, err = conn.Exec(ctx, recalcLegacyRun)
	fatal(err)
	conn.Release()

	fmt.Println("== go run (schema-parameterized port SQL)")
	d := flows.Dest{Name: goSchema, Pool: pool, EvSchema: goSchema, RefSchema: goSchema}
	_, err = rollup.RunRecalc(ctx, d, "1 month", []int{6})
	fatal(err)

	fmt.Println("== diff")
	var mism, comp int64
	fatal(pool.QueryRow(ctx, recalcDiffSQL).Scan(&mism, &comp))
	fmt.Printf("compared=%d mismatches=%d\n", comp, mism)
	if mism > 0 {
		rows, err := pool.Query(ctx, recalcMismatchDetail)
		fatal(err)
		defer rows.Close()
		for rows.Next() {
			var id int64
			var lo, gooee, lp, gp *float64
			var lf, gf *bool
			fatal(rows.Scan(&id, &lo, &gooee, &lp, &gp, &lf, &gf))
			fmt.Printf("  po=%d legacy_oee=%v go_oee=%v legacy_perf=%v go_perf=%v flags=%v/%v\n",
				id, f(lo), f(gooee), f(lp), f(gp), lf, gf)
		}
		os.Exit(1)
	}
	fmt.Println("PARITY: identical within tolerance")
}

func f(p *float64) any {
	if p == nil {
		return "∅"
	}
	return *p
}

func fatal(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(1)
	}
}

// emitRecalcScript renders the identical run for psql -f execution —
// single-sourced from the same constants the binary uses.
func emitRecalcScript() {
	fmt.Println("SET statement_timeout = 0;")
	for _, s := range recalcSnapshotSQL {
		fmt.Println(s + ";")
	}
	fmt.Println("SET search_path TO " + legacySchema + ", public;")
	fmt.Println(recalcLegacyRun + ";")
	fmt.Println("RESET search_path;")
	goSQL := fmt.Sprintf(rollup.RecalcSQLForParity(), goSchema, goSchema)
	goSQL = strings.ReplaceAll(goSQL, "$1::interval", "interval '1 month'")
	goSQL = strings.ReplaceAll(goSQL, "ANY($2)", "ANY(ARRAY[6])")
	fmt.Println(goSQL + ";")
	fmt.Println(fmt.Sprintf(rollup.ReflagRunningForParity(), goSchema) + ";")
	fmt.Println(fmt.Sprintf(rollup.ReflagRecentForParity(), goSchema) + ";")
	fmt.Println(recalcDiffSQL + ";")
	fmt.Println(recalcMismatchDetail + ";")
}

// compute subject: heavier snapshot (month slices of values+events,
// INDEXED — the accidental-benchmark lesson applied up front).
var computeSnapshotSQL = []string{
	`DROP SCHEMA IF EXISTS ` + legacySchema + ` CASCADE`,
	`DROP SCHEMA IF EXISTS ` + goSchema + ` CASCADE`,
	`CREATE SCHEMA ` + legacySchema,
	`CREATE SCHEMA ` + goSchema,
	`CREATE TABLE ` + legacySchema + `.production_orders_runtime AS
	   SELECT * FROM public.production_orders_runtime
	    WHERE runtime_timerange && tstzrange(now() - interval '1 month', now())`,
	`CREATE TABLE ` + legacySchema + `.equipments AS SELECT * FROM public.equipments`,
	`CREATE TABLE ` + legacySchema + `.sites AS SELECT * FROM public.sites`,
	`CREATE TABLE ` + legacySchema + `.equipment_values AS
	   SELECT id_equipment, ts_value, gross_production_incr, net_production_incr,
	          speed, ideal_production_speed
	     FROM public.equipment_values WHERE ts_value >= now() - interval '1 month'`,
	`CREATE TABLE ` + legacySchema + `.equipment_events AS
	   SELECT id_equipment, ts_event, ts_end, status
	     FROM public.equipment_events WHERE ts_event >= now() - interval '1 month'`,
	`UPDATE ` + legacySchema + `.production_orders_runtime SET recalc_needed = true`,
	`CREATE TABLE ` + goSchema + `.production_orders_runtime AS SELECT * FROM ` + legacySchema + `.production_orders_runtime`,
	`CREATE TABLE ` + goSchema + `.equipments AS SELECT * FROM ` + legacySchema + `.equipments`,
	`CREATE TABLE ` + goSchema + `.sites AS SELECT * FROM ` + legacySchema + `.sites`,
	`CREATE TABLE ` + goSchema + `.equipment_values AS SELECT * FROM ` + legacySchema + `.equipment_values`,
	`CREATE TABLE ` + goSchema + `.equipment_events AS SELECT * FROM ` + legacySchema + `.equipment_events`,
	`CREATE INDEX ON ` + legacySchema + `.equipment_values (id_equipment, ts_value)`,
	`CREATE INDEX ON ` + goSchema + `.equipment_values (id_equipment, ts_value)`,
	`CREATE INDEX ON ` + legacySchema + `.equipment_events (id_equipment, ts_event)`,
	`CREATE INDEX ON ` + goSchema + `.equipment_events (id_equipment, ts_event)`,
	`CREATE INDEX ON ` + legacySchema + `.production_orders_runtime (id_equipment)`,
	`CREATE INDEX ON ` + goSchema + `.production_orders_runtime (id_equipment)`,
}

const computeLegacyRun = `SELECT piot_get_equipment_production_order_runtime_test()`

const computeDiffSQL = `
	SELECT count(*) FILTER (WHERE NOT ok) AS mismatches, count(*) AS compared
	  FROM (
	    SELECT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 1e-6 * greatest(abs(COALESCE(l.gross_production,0)), abs(COALESCE(g.gross_production,0)))
	        AND abs(COALESCE(l.net_production,0)   - COALESCE(g.net_production,0))
	              < 1e-6 + 1e-6 * greatest(abs(COALESCE(l.net_production,0)), abs(COALESCE(g.net_production,0)))
	        AND abs(COALESCE(l.oee_q,0)            - COALESCE(g.oee_q,0))            < 1e-9
	        AND abs(COALESCE(l.speed,0)            - COALESCE(g.speed,0))
	              < 1e-6 + 1e-6 * greatest(abs(COALESCE(l.speed,0)), abs(COALESCE(g.speed,0)))
	        AND (upper(l.runtime_timerange) IS NULL  -- open rows: durations
	             -- grow with now(); the legs' gap lands here verbatim
	             OR (abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 1.5
	                 AND abs(COALESCE(l.stopped_time,0) - COALESCE(g.stopped_time,0)) < 1.5))
	        AND (l.recalc_needed = g.recalc_needed
	             OR upper(l.runtime_timerange) IS NULL
	             -- epsilon must dominate the LEGACY LEG'S RUN DURATION
	             -- (per-row month scans: tens of minutes) — 3600s.
	             OR abs(extract(epoch FROM (upper(l.runtime_timerange) - (now() - interval '48 hours')))) < 3600)) AS ok
	      FROM ` + legacySchema + `.production_orders_runtime l
	      FULL JOIN ` + goSchema + `.production_orders_runtime g
	        ON l.id_equipment = g.id_equipment
	       AND lower(l.runtime_timerange) = lower(g.runtime_timerange)
	     -- month-boundary eligibility racer: now() drifts between the
	     -- legs; rows whose window start sits at the 1-month edge are
	     -- eligible for one leg only. Exclude the edge band.
	     WHERE abs(extract(epoch FROM (lower(l.runtime_timerange) - (now() - interval '1 month')))) > 3600
	  ) d`

// running/stopped tolerance 1.5s: open events use now(), which
// advances between the legacy and go runs.

const computeMismatchDetail = `
	SELECT l.id_equipment, lower(l.runtime_timerange),
	       l.gross_production, g.gross_production,
	       l.running_time, g.running_time, l.recalc_needed, g.recalc_needed
	  FROM ` + legacySchema + `.production_orders_runtime l
	  FULL JOIN ` + goSchema + `.production_orders_runtime g
	    ON l.id_equipment = g.id_equipment
	   AND lower(l.runtime_timerange) = lower(g.runtime_timerange)
	 WHERE NOT (abs(COALESCE(l.gross_production,0) - COALESCE(g.gross_production,0))
	              < 1e-6 + 1e-6 * greatest(abs(COALESCE(l.gross_production,0)), abs(COALESCE(g.gross_production,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 1.5
	        AND (l.recalc_needed = g.recalc_needed
	             OR upper(l.runtime_timerange) IS NULL
	             OR abs(extract(epoch FROM (upper(l.runtime_timerange) - (now() - interval '48 hours')))) < 3600))
	 LIMIT 8`

// emitComputeScript mirrors emitRecalcScript for the compute subject.
func emitComputeScript() {
	fmt.Println("SET statement_timeout = 0;")
	for _, s := range computeSnapshotSQL {
		fmt.Println(s + ";")
	}
	fmt.Println("SET search_path TO " + legacySchema + ", public;")
	fmt.Println(computeLegacyRun + ";")
	fmt.Println("RESET search_path;")
	for _, s := range []string{
		fmt.Sprintf(rollup.ComputeEventsSQLForParity(), goSchema, goSchema),
		fmt.Sprintf(rollup.ComputeValuesSQLForParity(), goSchema, goSchema),
		fmt.Sprintf(rollup.ComputeReflagOpenForParity(), goSchema),
		fmt.Sprintf(rollup.ComputeReflagRecentForParity(), goSchema),
	} {
		s = strings.ReplaceAll(s, "$1::interval", "interval '1 month'")
		fmt.Println(s + ";")
	}
	fmt.Println(computeDiffSQL + ";")
	fmt.Println(computeMismatchDetail + ";")
}

// hour subject: tiny window (65min eligibility) → fast legs. Both
// legs receive the SAME 1min tier copy (legacy reads it as
// agg_equipment_values_1min_t, go as ca_agg_equipment_values_1min) —
// the subject isolates the ROLLUP math; the CAgg-vs-feeder
// equivalence is the mechanism-swap argument, documented separately.
var hourSnapshotSQL = []string{
	`DROP SCHEMA IF EXISTS ` + legacySchema + ` CASCADE`,
	`DROP SCHEMA IF EXISTS ` + goSchema + ` CASCADE`,
	`CREATE SCHEMA ` + legacySchema,
	`CREATE SCHEMA ` + goSchema,
	`CREATE TABLE ` + legacySchema + `.equipment_runtime_1hour AS
	   SELECT * FROM public.equipment_runtime_1hour WHERE ts_value >= now() - interval '4 hours' AND ts_value <= now() + interval '1 hour'`,
	`UPDATE ` + legacySchema + `.equipment_runtime_1hour SET recalc_needed = true WHERE ts_value >= now() - interval '65 minutes' AND ts_value <= now()`,
	`CREATE TABLE ` + legacySchema + `.equipment_runtime_1day AS
	   SELECT * FROM public.equipment_runtime_1day WHERE ts_value >= now() - interval '3 days'`,
	`CREATE TABLE ` + legacySchema + `.area_runtime_1hour AS
	   SELECT * FROM public.area_runtime_1hour WHERE ts_value >= now() - interval '4 hours'`,
	`CREATE TABLE ` + legacySchema + `.ca_agg_equipment_values_1hour AS
	   SELECT * FROM public.ca_agg_equipment_values_1hour WHERE ts_value >= now() - interval '4 hours'`,
	`CREATE TABLE ` + legacySchema + `.agg_equipment_values_1min_t AS
	   SELECT * FROM public.agg_equipment_values_1min_t WHERE ts_value >= now() - interval '4 hours'`,
	`CREATE TABLE ` + legacySchema + `.equipment_events AS
	   SELECT * FROM public.equipment_events WHERE ts_event >= now() - interval '10 days'`,
	`CREATE TABLE ` + legacySchema + `.equipments AS SELECT * FROM public.equipments`,
	`CREATE TABLE ` + legacySchema + `.production_targets AS SELECT * FROM public.production_targets`,
	`CREATE TABLE ` + goSchema + `.equipment_runtime_1hour AS SELECT * FROM ` + legacySchema + `.equipment_runtime_1hour`,
	`CREATE TABLE ` + goSchema + `.equipment_runtime_1day AS SELECT * FROM ` + legacySchema + `.equipment_runtime_1day`,
	`CREATE TABLE ` + goSchema + `.area_runtime_1hour AS SELECT * FROM ` + legacySchema + `.area_runtime_1hour`,
	`CREATE TABLE ` + goSchema + `.ca_agg_equipment_values_1hour AS SELECT * FROM ` + legacySchema + `.ca_agg_equipment_values_1hour`,
	`CREATE TABLE ` + goSchema + `.ca_agg_equipment_values_1min AS SELECT * FROM ` + legacySchema + `.agg_equipment_values_1min_t`,
	`CREATE TABLE ` + goSchema + `.equipment_events AS SELECT * FROM ` + legacySchema + `.equipment_events`,
	`CREATE TABLE ` + goSchema + `.equipments AS SELECT * FROM ` + legacySchema + `.equipments`,
	`CREATE TABLE ` + goSchema + `.production_targets AS SELECT * FROM ` + legacySchema + `.production_targets`,
	`CREATE INDEX ON ` + legacySchema + `.equipment_events (id_equipment, ts_event)`,
	`CREATE INDEX ON ` + goSchema + `.equipment_events (id_equipment, ts_event)`,
	`CREATE INDEX ON ` + legacySchema + `.agg_equipment_values_1min_t (id_equipment, ts_value)`,
	`CREATE INDEX ON ` + goSchema + `.ca_agg_equipment_values_1min (id_equipment, ts_value)`,
}

const hourLegacyRun = `SELECT piot_get_equipment_runtime_1hour_production()`

// diff: hour rows; exclude the current in-flight hour (ts_total reads
// now() → open-bucket drift class); flag guard on the 2h tail band.
const hourDiffSQL = `
	SELECT count(*) FILTER (WHERE NOT ok) AS mismatches, count(*) AS compared
	  FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.net,0) - COALESCE(g.net,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.net,0)),abs(COALESCE(g.net,0)))
	        AND abs(COALESCE(l.speed,0) - COALESCE(g.speed,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.speed,0)),abs(COALESCE(g.speed,0)))
	        AND abs(COALESCE(l.ideal_speed,0) - COALESCE(g.ideal_speed,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.ideal_speed,0)),abs(COALESCE(g.ideal_speed,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 1.5
	        AND abs(COALESCE(l.stopped_time,0) - COALESCE(g.stopped_time,0)) < 1.5
	        AND abs(COALESCE(l.planned_downtime,0) - COALESCE(g.planned_downtime,0)) < 1.5
	        AND (l.recalc_needed = g.recalc_needed
	             OR abs(extract(epoch FROM (l.ts_value - date_trunc('hour', now() - interval '2 hour')))) < 3600)) AS ok
	      FROM ` + legacySchema + `.equipment_runtime_1hour l
	      FULL JOIN ` + goSchema + `.equipment_runtime_1hour g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE l.ts_value < date_trunc('hour', now())  -- open-bucket drift
	  ) d`

const hourMismatchDetail = `
	SELECT l.id_equipment, l.ts_value, l.gross, g.gross, l.running_time, g.running_time,
	       l.speed, g.speed, l.recalc_needed, g.recalc_needed
	  FROM ` + legacySchema + `.equipment_runtime_1hour l
	  FULL JOIN ` + goSchema + `.equipment_runtime_1hour g
	    ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	 WHERE l.ts_value < date_trunc('hour', now())
	   AND NOT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 1.5)
	 LIMIT 8`

func emitHourScript() {
	fmt.Println("SET statement_timeout = 0;")
	for _, s := range hourSnapshotSQL {
		fmt.Println(s + ";")
	}
	fmt.Println("SET search_path TO " + legacySchema + ", public;")
	fmt.Println(hourLegacyRun + ";")
	fmt.Println("RESET search_path;")
	for _, st := range rollup.HourStatementsForParity(goSchema, goSchema) {
		sql := st.SQL
		sql = strings.ReplaceAll(sql, "= ANY($1)", "= ANY(ARRAY[]::int[])")
		sql = strings.ReplaceAll(sql, "= ANY($2)", "= ANY(ARRAY[]::int[])")
		fmt.Println(sql + ";")
	}
	fmt.Println(hourDiffSQL + ";")
	fmt.Println(hourMismatchDetail + ";")
}

// day2 subject: day rows roll from the STATIC hour-table copy — sums
// are now()-independent; only eligibility bounds + tail carry drift.
var daySnapshotSQL = []string{
	`DROP SCHEMA IF EXISTS ` + legacySchema + ` CASCADE`,
	`DROP SCHEMA IF EXISTS ` + goSchema + ` CASCADE`,
	`CREATE SCHEMA ` + legacySchema,
	`CREATE SCHEMA ` + goSchema,
	`CREATE TABLE ` + legacySchema + `.equipment_runtime_1day AS
	   SELECT * FROM public.equipment_runtime_1day WHERE ts_value >= now() - interval '35 days' AND ts_value <= now() + interval '2 days'`,
	`UPDATE ` + legacySchema + `.equipment_runtime_1day SET recalc_needed = true WHERE ts_value >= now() - interval '1 month'`,
	`CREATE TABLE ` + legacySchema + `.equipment_runtime_1hour AS
	   SELECT * FROM public.equipment_runtime_1hour WHERE ts_value >= now() - interval '35 days'`,
	`CREATE TABLE ` + legacySchema + `.equipment_runtime_1week AS
	   SELECT * FROM public.equipment_runtime_1week WHERE ts_value >= now() - interval '40 days'`,
	`CREATE TABLE ` + legacySchema + `.equipment_runtime_1month AS
	   SELECT * FROM public.equipment_runtime_1month WHERE ts_value >= now() - interval '70 days'`,
	`CREATE TABLE ` + legacySchema + `.equipments AS SELECT * FROM public.equipments`,
	`CREATE TABLE ` + goSchema + `.equipment_runtime_1day AS SELECT * FROM ` + legacySchema + `.equipment_runtime_1day`,
	`CREATE TABLE ` + goSchema + `.equipment_runtime_1hour AS SELECT * FROM ` + legacySchema + `.equipment_runtime_1hour`,
	`CREATE TABLE ` + goSchema + `.equipment_runtime_1week AS SELECT * FROM ` + legacySchema + `.equipment_runtime_1week`,
	`CREATE TABLE ` + goSchema + `.equipment_runtime_1month AS SELECT * FROM ` + legacySchema + `.equipment_runtime_1month`,
	`CREATE TABLE ` + goSchema + `.equipments AS SELECT * FROM ` + legacySchema + `.equipments`,
	`CREATE INDEX ON ` + legacySchema + `.equipment_runtime_1hour (id_equipment, ts_value_production)`,
	`CREATE INDEX ON ` + goSchema + `.equipment_runtime_1hour (id_equipment, ts_value_production)`,
}

const dayLegacyRun = `SELECT piot_get_equipment_runtime_1day_production2()`

const dayDiffSQL = `
	SELECT count(*) FILTER (WHERE NOT ok) AS mismatches, count(*) AS compared
	  FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.net,0) - COALESCE(g.net,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.net,0)),abs(COALESCE(g.net,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 1.5
	        AND abs(COALESCE(l.available_time,0) - COALESCE(g.available_time,0)) < 1.5
	        AND abs(COALESCE(l.oee,0) - COALESCE(g.oee,0)) < 1e-9 + 1e-6*greatest(abs(COALESCE(l.oee,0)),abs(COALESCE(g.oee,0)))
	        AND abs(COALESCE(l.target,0) - COALESCE(g.target,0)) < 1e-6
	        AND (l.recalc_needed = g.recalc_needed
	             OR l.ts_value >= now() - interval '2 days'))  -- tail band (per-eq day anchors)
	           AS ok
	      FROM ` + legacySchema + `.equipment_runtime_1day l
	      FULL JOIN ` + goSchema + `.equipment_runtime_1day g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     -- month-edge eligibility band
	     WHERE abs(extract(epoch FROM (l.ts_value - (now() - interval '1 month')))) > 7200
	  ) d`

const dayMismatchDetail = `
	SELECT l.id_equipment, l.ts_value, l.gross, g.gross, l.running_time, g.running_time,
	       l.oee, g.oee, l.recalc_needed, g.recalc_needed
	  FROM ` + legacySchema + `.equipment_runtime_1day l
	  FULL JOIN ` + goSchema + `.equipment_runtime_1day g
	    ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	 WHERE NOT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 1.5)
	 LIMIT 8`

func emitDayScript() {
	fmt.Println("SET statement_timeout = 0;")
	for _, s := range daySnapshotSQL {
		fmt.Println(s + ";")
	}
	fmt.Println("SET search_path TO " + legacySchema + ", public;")
	fmt.Println(dayLegacyRun + ";")
	fmt.Println("RESET search_path;")
	fmt.Println("BEGIN;")
	for _, st := range rollup.DayStatementsForParity(goSchema, goSchema) {
		sql := st.SQL
		// day2's OWN hardcoded lists (ends ...,115,118).
		sql = strings.ReplaceAll(sql, "= ANY($1)", "= ANY(ARRAY[24])")
		sql = strings.ReplaceAll(sql, "= ANY($2)", "= ANY(ARRAY[2,30,34,35,36,38,99,100,101,102,111,112,113,114,115,118])")
		fmt.Println(sql + ";")
	}
	fmt.Println("COMMIT;")
	fmt.Println(dayDiffSQL + ";")
	fmt.Println(dayMismatchDetail + ";")
}

// shift subject: 30d window; events phase reads now() on open spans →
// compare CLOSED shifts outside a safety band; forward re-flag band
// [now−12h, now+18h] guarded on flags.
var shiftSnapshotSQL = []string{
	`DROP SCHEMA IF EXISTS ` + legacySchema + ` CASCADE`,
	`DROP SCHEMA IF EXISTS ` + goSchema + ` CASCADE`,
	`CREATE SCHEMA ` + legacySchema,
	`CREATE SCHEMA ` + goSchema,
	`CREATE TABLE ` + legacySchema + `.equipment_runtime_shift AS
	   SELECT * FROM public.equipment_runtime_shift WHERE ts_value >= now() - interval '32 days' AND ts_value <= now() + interval '1 day'`,
	`UPDATE ` + legacySchema + `.equipment_runtime_shift SET recalc_needed = true WHERE ts_value >= now() - interval '30 days' AND ts_value <= now()`,
	`CREATE TABLE ` + legacySchema + `.area_runtime_shift AS
	   SELECT * FROM public.area_runtime_shift WHERE ts_value >= now() - interval '32 days'`,
	`CREATE TABLE ` + legacySchema + `.ca_agg_equipment_values_1hour AS
	   SELECT * FROM public.ca_agg_equipment_values_1hour WHERE ts_value >= now() - interval '32 days'`,
	`CREATE TABLE ` + legacySchema + `.equipment_events AS
	   SELECT * FROM public.equipment_events WHERE ts_event >= now() - interval '25 days'`,
	`CREATE TABLE ` + legacySchema + `.equipments AS SELECT * FROM public.equipments`,
	`CREATE TABLE ` + legacySchema + `.shifts AS SELECT * FROM public.shifts`,
	`CREATE TABLE ` + legacySchema + `.production_targets AS SELECT * FROM public.production_targets`,
	`CREATE TABLE ` + goSchema + `.equipment_runtime_shift AS SELECT * FROM ` + legacySchema + `.equipment_runtime_shift`,
	`CREATE TABLE ` + goSchema + `.area_runtime_shift AS SELECT * FROM ` + legacySchema + `.area_runtime_shift`,
	`CREATE TABLE ` + goSchema + `.ca_agg_equipment_values_1hour AS SELECT * FROM ` + legacySchema + `.ca_agg_equipment_values_1hour`,
	`CREATE TABLE ` + goSchema + `.equipment_events AS SELECT * FROM ` + legacySchema + `.equipment_events`,
	`CREATE TABLE ` + goSchema + `.equipments AS SELECT * FROM ` + legacySchema + `.equipments`,
	`CREATE TABLE ` + goSchema + `.shifts AS SELECT * FROM ` + legacySchema + `.shifts`,
	`CREATE TABLE ` + goSchema + `.production_targets AS SELECT * FROM ` + legacySchema + `.production_targets`,
	`CREATE INDEX ON ` + legacySchema + `.ca_agg_equipment_values_1hour (id_equipment, ts_value_production)`,
	`CREATE INDEX ON ` + goSchema + `.ca_agg_equipment_values_1hour (id_equipment, ts_value_production)`,
	`CREATE INDEX ON ` + legacySchema + `.equipment_events (id_equipment, ts_event)`,
	`CREATE INDEX ON ` + goSchema + `.equipment_events (id_equipment, ts_event)`,
	`CREATE INDEX ON ` + legacySchema + `.equipment_runtime_shift (id_equipment, ts_value)`,
	`CREATE INDEX ON ` + goSchema + `.equipment_runtime_shift (id_equipment, ts_value)`,
}

const shiftLegacyRun = `SELECT piot_get_equipment_runtime_shift_production()`

const shiftDiffSQL = `
	SELECT count(*) FILTER (WHERE NOT ok) AS mismatches, count(*) AS compared
	  FROM (
	    SELECT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.net,0) - COALESCE(g.net,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.net,0)),abs(COALESCE(g.net,0)))
	        AND abs(COALESCE(l.speed,0) - COALESCE(g.speed,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.speed,0)),abs(COALESCE(g.speed,0)))
	        AND COALESCE(l.cd_shift,'') = COALESCE(g.cd_shift,'')
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 1.5
	        AND abs(COALESCE(l.stopped_time,0) - COALESCE(g.stopped_time,0)) < 1.5
	        AND (l.recalc_needed = g.recalc_needed
	             OR (l.ts_value >= now() - interval '14 hours' AND l.ts_value < now() + interval '20 hours')))
	           AS ok
	      FROM ` + legacySchema + `.equipment_runtime_shift l
	      FULL JOIN ` + goSchema + `.equipment_runtime_shift g
	        ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	     WHERE COALESCE(l.ts_end, now()) < now() - interval '1 hour'  -- closed, outside drift band
	       AND abs(extract(epoch FROM (l.ts_value - (now() - interval '30 days')))) > 7200
	  ) d`

const shiftMismatchDetail = `
	SELECT l.id_equipment, l.ts_value, l.gross, g.gross, l.running_time, g.running_time,
	       l.cd_shift, g.cd_shift, l.recalc_needed, g.recalc_needed
	  FROM ` + legacySchema + `.equipment_runtime_shift l
	  FULL JOIN ` + goSchema + `.equipment_runtime_shift g
	    ON l.id_equipment = g.id_equipment AND l.ts_value = g.ts_value
	 WHERE COALESCE(l.ts_end, now()) < now() - interval '1 hour'
	   AND NOT (abs(COALESCE(l.gross,0) - COALESCE(g.gross,0)) < 1e-6 + 1e-6*greatest(abs(COALESCE(l.gross,0)),abs(COALESCE(g.gross,0)))
	        AND abs(COALESCE(l.running_time,0) - COALESCE(g.running_time,0)) < 1.5
	        AND COALESCE(l.cd_shift,'') = COALESCE(g.cd_shift,''))
	 LIMIT 8`

func emitShiftScript() {
	fmt.Println("SET statement_timeout = 0;")
	for _, s := range shiftSnapshotSQL {
		fmt.Println(s + ";")
	}
	fmt.Println("SET search_path TO " + legacySchema + ", public;")
	fmt.Println(shiftLegacyRun + ";")
	fmt.Println("RESET search_path;")
	fmt.Println("BEGIN;")
	for _, st := range rollup.ShiftStatementsForParity(goSchema, goSchema) {
		sql := st.SQL
		// shift's OWN lists: areas 24; enterprises end ...,115,118
		// (NO 35 — shift includes CPACK on prod); machine-level {6}.
		sql = strings.ReplaceAll(sql, "= ANY($1)", "= ANY(ARRAY[24])")
		sql = strings.ReplaceAll(sql, "= ANY($2)", "= ANY(ARRAY[2,30,34,36,38,99,100,101,102,111,112,113,114,115,118])")
		sql = strings.ReplaceAll(sql, "= ANY($3)", "= ANY(ARRAY[6])")
		fmt.Println(sql + ";")
	}
	fmt.Println("COMMIT;")
	fmt.Println(shiftDiffSQL + ";")
	fmt.Println(shiftMismatchDetail + ";")
}
