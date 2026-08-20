//go:build golden

// Behavioural proof for the ADR-0036 §4 Silver invariant clamp (silver.go).
//
// Proves the three contract properties in one ephemeral-Postgres run:
//  1. An OUT-OF-RANGE row is CLAMPED to the invariant bounds — AND every clamp
//     emits an INVARIANT_CLAMPED_* data_quality_event (never silent).
//  2. A CLEAN row is left BYTE-IDENTICAL and emits NO event (the WHERE selects
//     only genuine violators → zero writes → parity/identity hold).
//  3. The pass is IDEMPOTENT: a second run clamps 0 rows and mints no new events.
//
// It drives RunSilverClamp end-to-end (the same function the worker loop calls),
// so it exercises the detect+clamp tx, the dqGrainMatrix iteration, and the
// data_quality_event dedup upsert — not just the raw SQL.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/rollup -run Golden
package rollup

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// silverGrainTables is dqGrainMatrix's table set — RunSilverClamp iterates all of
// them, so the fixture must create every one (empty tables are a clean no-op).
var silverGrainTables = []string{
	"equipment_runtime_shift", "equipment_runtime_1hour", "equipment_runtime_1day",
	"equipment_runtime_1week", "equipment_runtime_1month",
}

// silverRuntimeCols mirrors the columns the clamp touches; every equipment_runtime_*
// table carries them (dq.go reads them from all five).
const silverRuntimeCols = `
    id_equipment int, ts_value timestamptz,
    oee double precision, oee_a double precision, oee_p double precision, oee_q double precision,
    gross double precision, net double precision, scrap double precision,
    available_time double precision, running_time double precision, stopped_time double precision,
    planned_downtime double precision, downtime double precision, changeover_time double precision,
    idle_time double precision, idle_starved double precision, idle_blocked double precision,
    ideal_production double precision`

func silverSchemaDDL() string {
	var b strings.Builder
	b.WriteString(`
	DROP SCHEMA IF EXISTS silver CASCADE;
	CREATE SCHEMA silver;
	SET search_path TO silver, public;

	CREATE TABLE silver.equipments (
	    id_equipment int PRIMARY KEY, id_enterprise int NOT NULL
	);

	-- Mirror of migration 34 (data_quality_event) — created inline because the
	-- migration is applied out-of-band via scripts/ssm-psql.sh, not in db/init.
	CREATE TABLE silver.data_quality_event (
	    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	    id_enterprise INTEGER NOT NULL,
	    id_equipment INTEGER,
	    grain TEXT NOT NULL,
	    bucket_ts TIMESTAMPTZ NOT NULL,
	    rule TEXT NOT NULL,
	    observed_value DOUBLE PRECISION,
	    severity TEXT NOT NULL DEFAULT 'warn',
	    detected_at TIMESTAMPTZ NOT NULL DEFAULT now()
	);
	CREATE UNIQUE INDEX data_quality_event_dedup_un
	    ON silver.data_quality_event (id_enterprise, COALESCE(id_equipment, 0), grain, bucket_ts, rule);
`)
	for _, t := range silverGrainTables {
		fmt.Fprintf(&b, "\tCREATE TABLE silver.%s (%s);\n", t, silverRuntimeCols)
	}
	return b.String()
}

func TestGoldenSilverInvariantClamp(t *testing.T) {
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

	if _, err := pool.Exec(ctx, silverSchemaDDL()); err != nil {
		t.Fatalf("schema: %v", err)
	}

	ts := time.Now().Add(-3 * time.Hour) // inside every grain's recency window
	setup := fmt.Sprintf(`
		SET search_path TO silver, public;
		INSERT INTO silver.equipments VALUES (81,3),(82,3),(83,3);

		-- 81: maximally out-of-range shift row. oee/oee_a/oee_p/oee_q all >1;
		-- net(200) > gross(100); scrap negative; running_time negative.
		INSERT INTO silver.equipment_runtime_shift
		    (id_equipment, ts_value, oee, oee_a, oee_p, oee_q, gross, net, scrap,
		     available_time, running_time, stopped_time, planned_downtime, downtime,
		     changeover_time, idle_time, idle_starved, idle_blocked, ideal_production)
		VALUES (81, '%[1]s', 8142, 1.5, 3.0, 2.0, 100, 200, -100,
		     3600, -3600, 0, 0, 0, 0, 0, 0, 0, 0);

		-- 82: fully clean shift row — must be byte-identical after the pass.
		INSERT INTO silver.equipment_runtime_shift
		    (id_equipment, ts_value, oee, oee_a, oee_p, oee_q, gross, net, scrap,
		     available_time, running_time, stopped_time, planned_downtime, downtime,
		     changeover_time, idle_time, idle_starved, idle_blocked, ideal_production)
		VALUES (82, '%[1]s', 0.82, 0.9, 0.95, 0.96, 1000, 960, 40,
		     25200, 22000, 3200, 600, 3200, 300, 0, 0, 0, 1050);

		-- 83: "not metered" NULL row (RunUnmetered's shape) with clean counts —
		-- must NOT be selected (NULL never satisfies the WHERE) → oee stays NULL.
		INSERT INTO silver.equipment_runtime_shift
		    (id_equipment, ts_value, oee, oee_a, oee_p, oee_q, gross, net, scrap,
		     available_time, running_time, stopped_time, planned_downtime, downtime,
		     changeover_time, idle_time, idle_starved, idle_blocked, ideal_production)
		VALUES (83, '%[1]s', NULL, 0, 0, 0, 0, 0, 0,
		     0, 0, 0, 0, 0, 0, 0, 0, 0, 0);`, ts.Format(time.RFC3339Nano))
	if _, err := pool.Exec(ctx, setup); err != nil {
		t.Fatalf("fixture: %v", err)
	}

	d := flows.Dest{Name: "test", Pool: pool, EvSchema: "silver", RefSchema: "silver"}

	// ── First run: clamps exactly the one violating row across all grains. ──
	n, err := RunSilverClamp(ctx, d, true)
	if err != nil {
		t.Fatalf("RunSilverClamp: %v", err)
	}
	if n != 1 {
		t.Errorf("first run clamped %d rows, want 1 (only eq81)", n)
	}

	type row struct {
		oee, oeeA, oeeP, oeeQ, gross, net, scrap, running float64
		oeeNull                                           bool
	}
	get := func(id int) row {
		var r row
		var oee *float64
		if err := pool.QueryRow(ctx, `
			SELECT oee, oee_a, oee_p, oee_q, gross, net, scrap, running_time
			  FROM silver.equipment_runtime_shift WHERE id_equipment=$1`, id).
			Scan(&oee, &r.oeeA, &r.oeeP, &r.oeeQ, &r.gross, &r.net, &r.scrap, &r.running); err != nil {
			t.Fatalf("get %d: %v", id, err)
		}
		if oee == nil {
			r.oeeNull = true
		} else {
			r.oee = *oee
		}
		return r
	}

	// (a) eq81 clamped to bounds. GROSS is NOT lowered (comparator identity column),
	// but NET (200) IS lowered to gross (100) — the net≤gross invariant. scrap→0.
	r81 := get(81)
	if r81.oee != 1 || r81.oeeA != 1 || r81.oeeP != 1 || r81.oeeQ != 1 {
		t.Errorf("eq81 oee factors not clamped to 1: %+v", r81)
	}
	if r81.running != 0 {
		t.Errorf("eq81 running_time = %v, want 0 (negative clamped)", r81.running)
	}
	if r81.scrap != 0 {
		t.Errorf("eq81 scrap = %v, want 0 (GREATEST(scrap,0))", r81.scrap)
	}
	if r81.gross != 100 {
		t.Errorf("eq81 gross = %v, want 100 — clamp must NOT lower gross (comparator column)", r81.gross)
	}
	if r81.net != 100 {
		t.Errorf("eq81 net = %v, want 100 — net must be lowered to gross (net≤gross invariant)", r81.net)
	}

	// (b) eq82 byte-identical.
	r82 := get(82)
	if r82 != (row{oee: 0.82, oeeA: 0.9, oeeP: 0.95, oeeQ: 0.96, gross: 1000, net: 960, scrap: 40, running: 22000}) {
		t.Errorf("eq82 clean row changed by clamp: %+v", r82)
	}

	// (c) eq83 NULL preserved.
	if r83 := get(83); !r83.oeeNull {
		t.Errorf("eq83 oee = %v, want NULL preserved (not-metered row must not be clamped)", r83.oee)
	}

	// (d) DQ events: exactly the six INVARIANT_CLAMPED_* rules for eq81, none for
	// 82/83. net>gross (200>100) now fires its OWN rule (NET_GT_GROSS, observed =
	// pre-clamp net = 200) AND surfaces as OEE_Q clamped to 1 (net/gross=2 → 1);
	// scrap starts negative (-100) → caught by the NEGATIVE rule, whose observed is
	// the most-negative of {scrap=-100, running_time=-3600} = -3600.
	wantRules := map[string]float64{
		"INVARIANT_CLAMPED_OEE":          8142,
		"INVARIANT_CLAMPED_OEE_A":        1.5,
		"INVARIANT_CLAMPED_OEE_P":        3.0,
		"INVARIANT_CLAMPED_OEE_Q":        2.0,
		"INVARIANT_CLAMPED_NEGATIVE":     -3600,
		"INVARIANT_CLAMPED_NET_GT_GROSS": 200,
	}
	rows, err := pool.Query(ctx, `
		SELECT id_equipment, rule, observed_value, severity
		  FROM silver.data_quality_event ORDER BY rule`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	gotRules := map[string]float64{}
	for rows.Next() {
		var eq int
		var rule, sev string
		var obs *float64
		if err := rows.Scan(&eq, &rule, &obs, &sev); err != nil {
			t.Fatal(err)
		}
		if eq != 81 {
			t.Errorf("unexpected DQ event for eq%d rule=%s — only eq81 should trip", eq, rule)
		}
		if sev != "error" {
			t.Errorf("rule %s severity=%q, want error", rule, sev)
		}
		if obs == nil {
			t.Errorf("rule %s observed_value is NULL, want the pre-clamp value", rule)
			continue
		}
		gotRules[rule] = *obs
	}
	for rule, wantObs := range wantRules {
		got, ok := gotRules[rule]
		if !ok {
			t.Errorf("missing DQ event %s", rule)
			continue
		}
		if got != wantObs {
			t.Errorf("%s observed=%v, want %v (pre-clamp value)", rule, got, wantObs)
		}
	}
	if len(gotRules) != len(wantRules) {
		t.Errorf("got %d DQ rules, want %d: %v", len(gotRules), len(wantRules), gotRules)
	}

	// ── Second run: idempotent — clamps 0 rows and mints no NEW event rows. ──
	var before int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM silver.data_quality_event`).Scan(&before); err != nil {
		t.Fatal(err)
	}
	n2, err := RunSilverClamp(ctx, d, true)
	if err != nil {
		t.Fatalf("RunSilverClamp (2nd): %v", err)
	}
	if n2 != 0 {
		t.Errorf("second run clamped %d rows, want 0 (idempotent)", n2)
	}
	var after int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM silver.data_quality_event`).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Errorf("second run changed DQ event count %d → %d (dedup upsert must refresh in place)", before, after)
	}
}
