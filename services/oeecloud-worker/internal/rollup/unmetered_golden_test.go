//go:build golden

// Golden-fixture test for the not-metered-machine correction (OEE audit
// Defect B). Runs the VERIFIED unmetered SQL (single source via
// UnmeteredStatementsForParity) against an ephemeral Postgres and
// asserts the NULL-not-0 semantics:
//   - a tp=1 machine of a NON-machine-level enterprise → OEE nulled;
//   - a tp=1 machine of a MACHINE-level enterprise      → unchanged;
//   - a tp=3 line and a tp=2 sector                      → unchanged.
//
// Run: DATABASE_URL=postgres://... go test -tags golden -run Golden ./internal/rollup
package rollup

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Dedicated schema: the seven per-machine grain tables, each with the
// four OEE columns (verified present in prod via edge-api/schema.sql),
// plus a minimal equipments table for the gate join.
const unmeteredGoldenSchema = `
	DROP SCHEMA IF EXISTS ug CASCADE;
	CREATE SCHEMA ug;
	CREATE TABLE ug.equipments (
	    id_equipment int PRIMARY KEY, id_enterprise int, tp_equipment int
	);
	CREATE TABLE ug.equipment_runtime_1hour (
	    id_equipment int, ts_value timestamptz,
	    oee double precision, oee_a double precision,
	    oee_p double precision, oee_q double precision,
	    -- ADR-0036 §5A lineage columns (T0-2); propagate to every grain via LIKE.
	    computed_at timestamptz, source_watermark timestamptz
	);
	CREATE TABLE ug.equipment_runtime_1day        (LIKE ug.equipment_runtime_1hour INCLUDING ALL);
	CREATE TABLE ug.equipment_runtime_1week       (LIKE ug.equipment_runtime_1hour INCLUDING ALL);
	CREATE TABLE ug.equipment_runtime_1month      (LIKE ug.equipment_runtime_1hour INCLUDING ALL);
	CREATE TABLE ug.equipment_runtime_shift       (LIKE ug.equipment_runtime_1hour INCLUDING ALL);
	CREATE TABLE ug.equipment_runtime_shift_1week (LIKE ug.equipment_runtime_1hour INCLUDING ALL);
	CREATE TABLE ug.equipment_runtime_shift_1month(LIKE ug.equipment_runtime_1hour INCLUDING ALL);`

// Fixture: four equipments, and one flat-0 row per equipment in EVERY
// grain table (within the 90d window).
//   100 — ent 3 (line-metered), tp=1 machine  → MUST be nulled
//   101 — ent 6 (machine-metered), tp=1 machine → MUST stay 0
//   102 — ent 3, tp=3 line                      → MUST stay 0
//   103 — ent 3, tp=2 sector                    → MUST stay 0
const unmeteredGoldenFixture = `
	INSERT INTO ug.equipments VALUES (100,3,1),(101,6,1),(102,3,3),(103,3,2);
	DO $$
	DECLARE t text;
	BEGIN
	  FOREACH t IN ARRAY ARRAY[
	    'equipment_runtime_1hour','equipment_runtime_1day','equipment_runtime_1week',
	    'equipment_runtime_1month','equipment_runtime_shift','equipment_runtime_shift_1week',
	    'equipment_runtime_shift_1month'] LOOP
	    EXECUTE format(
	      'INSERT INTO ug.%I (id_equipment, ts_value, oee, oee_a, oee_p, oee_q)
	         VALUES (100, now()-interval ''1 hour'', 0,0,0,0),
	                (101, now()-interval ''1 hour'', 0,0,0,0),
	                (102, now()-interval ''1 hour'', 0,0,0,0),
	                (103, now()-interval ''1 hour'', 0,0,0,0)', t);
	  END LOOP;
	END $$;`

func TestGoldenUnmetered(t *testing.T) {
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
	for _, s := range []string{unmeteredGoldenSchema, unmeteredGoldenFixture} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}

	// The verified pass, verbatim (single source). Machine-level set = {6}.
	for _, st := range UnmeteredStatementsForParity("ug", "ug") {
		if _, err := pool.Exec(ctx, st.SQL, []int{6}); err != nil {
			t.Fatalf("unmetered %s: %v", st.Name, err)
		}
	}

	// COALESCE sentinel: -999 means "the value is NULL".
	oeeOf := func(tbl string, eq int) (float64, float64, float64, float64) {
		var o, a, p, q float64
		if err := pool.QueryRow(ctx, fmt.Sprintf(
			`SELECT COALESCE(oee,-999), COALESCE(oee_a,-999), COALESCE(oee_p,-999), COALESCE(oee_q,-999)
			   FROM ug.%s WHERE id_equipment=$1`, tbl), eq).Scan(&o, &a, &p, &q); err != nil {
			t.Fatalf("read %s eq%d: %v", tbl, eq, err)
		}
		return o, a, p, q
	}

	for _, st := range UnmeteredStatementsForParity("ug", "ug") {
		tbl := st.Name
		// eq100: line-metered machine → ALL four OEE columns NULL.
		if o, a, p, q := oeeOf(tbl, 100); o != -999 || a != -999 || p != -999 || q != -999 {
			t.Errorf("%s eq100 (line-metered machine) not nulled: oee=%v a=%v p=%v q=%v (want NULL)", tbl, o, a, p, q)
		}
		// eq101: machine-metered enterprise → untouched (stays 0).
		if o, _, _, _ := oeeOf(tbl, 101); o != 0 {
			t.Errorf("%s eq101 (machine-metered) OEE changed: %v (must stay 0 — never touch machine-metered tenants)", tbl, o)
		}
		// eq102: line (tp=3) → untouched.
		if o, _, _, _ := oeeOf(tbl, 102); o != 0 {
			t.Errorf("%s eq102 (tp=3 line) OEE changed: %v (lines must be untouched)", tbl, o)
		}
		// eq103: sector (tp=2) → untouched.
		if o, _, _, _ := oeeOf(tbl, 103); o != 0 {
			t.Errorf("%s eq103 (tp=2 sector) OEE changed: %v (sectors must be untouched)", tbl, o)
		}
	}
}
