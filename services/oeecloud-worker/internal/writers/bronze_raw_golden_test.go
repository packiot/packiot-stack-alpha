//go:build golden

// ADR-0036 B1 golden fixture — proves the medallion Bronze collision property
// against a REAL Postgres carrying the exact merged/raw table shapes + the
// immutability trigger the migration installs.
//
// The point: two samples for the SAME equipment inside the SAME whole second
// (12:00:00.250 and 12:00:00.800) must
//   - collapse to ONE row in the merged equipment_values (ts_value truncated to
//     :00, the second sample's increment overwriting the first via the ON
//     CONFLICT DO UPDATE) — the operational per-second column-merge, UNCHANGED;
//   - be preserved as TWO rows in equipment_values_raw (full sub-second precision
//     retained, distinct source_seq from the sequence default) — Bronze keeps
//     every sample.
//
// And the Bronze rows are IMMUTABLE: an UPDATE or DELETE against equipment_values_raw
// raises (the superuser-proof bronze_raw_no_mutate trigger), while the append
// INSERT that made them is fine.
//
//	Run: DATABASE_URL=postgres://user:pass@host/db go test -tags golden \
//	       ./internal/writers -run BronzeRaw -v
package writers

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// brSchema — the merged fact table (per-second UNIQUE) + the immutable Bronze raw
// hypertable-shaped table (source_seq sequence default, PK incl. source_seq) + the
// exact append-only guard the migration installs. Plain tables (no timescaledb
// needed to prove the row-count / immutability contract).
const brSchema = `
DROP SCHEMA IF EXISTS br CASCADE;
CREATE SCHEMA br;

CREATE TABLE br.equipment_values (
    ts_value timestamptz NOT NULL,
    id_enterprise int, id_site int, id_area int, id_equipment int NOT NULL,
    tp_equipment int,
    net_production_incr real, net_production_val real, speed real,
    signal_quality int, faults jsonb, check_number bigint,
    UNIQUE (ts_value, id_equipment)
);

CREATE SEQUENCE br.equipment_values_source_seq_seq;
CREATE TABLE br.equipment_values_raw (
    ts_value timestamptz NOT NULL,
    id_enterprise int, id_site int, id_area int, id_equipment int NOT NULL,
    tp_equipment int,
    net_production_incr real, net_production_val real, speed real,
    signal_quality int, faults jsonb, check_number bigint,
    ingested_at timestamptz DEFAULT now(),
    source_seq bigint DEFAULT nextval('br.equipment_values_source_seq_seq') NOT NULL,
    PRIMARY KEY (id_equipment, ts_value, source_seq)
);

CREATE OR REPLACE FUNCTION br.bronze_raw_no_mutate() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'Bronze raw table %.% is append-only (attempted %); corrections are new appended rows, never in-place edits',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP USING ERRCODE = 'restrict_violation';
END; $$;

CREATE TRIGGER trg_equipment_values_raw_no_mutate
    BEFORE UPDATE OR DELETE ON br.equipment_values_raw
    FOR EACH ROW EXECUTE FUNCTION br.bronze_raw_no_mutate();`

func brConnect(t *testing.T) (context.Context, *pgxpool.Pool) {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(ctx, brSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	return ctx, pool
}

func f64(v float64) *float64 { return &v }

// TestBronzeRawCollisionAndImmutability drives the SAME builders the handler uses —
// buildProcessed (merged UPSERT) and buildRawAppend (Bronze append) — for two
// intra-second samples, and asserts the collision + immutability contract.
func TestBronzeRawCollisionAndImmutability(t *testing.T) {
	ctx, pool := brConnect(t)

	sq := 100
	info := &sparkplug.EquipmentInfo{IDEnterprise: 1, IDSite: 2, IDArea: 3, IDEquipment: 42, SignalQuality: &sq}

	// Two samples in the same whole second: 12:00:00.250 and 12:00:00.800.
	ms1 := time.Date(2026, 7, 29, 12, 0, 0, 250*int(time.Millisecond), time.UTC).UnixMilli()
	ms2 := time.Date(2026, 7, 29, 12, 0, 0, 800*int(time.Millisecond), time.UTC).UnixMilli()

	type sample struct {
		ms    int64
		value float64
	}
	for _, s := range []sample{{ms1, 10}, {ms2, 20}} {
		mergedTs := time.UnixMilli(s.ms).Truncate(time.Second).UTC() // :00 — Build's rule
		rawTs := time.UnixMilli(s.ms).UTC()                          // full precision — BuildRawAppend's rule

		mq := buildProcessed(mergedTs, info, 1, s.value, f64(1000+s.value), f64(5), nil, s.ms, "br", false, nil, nil)
		if _, err := pool.Exec(ctx, mq.SQL, mq.Args...); err != nil {
			t.Fatalf("merged upsert (%v): %v", s, err)
		}
		rq := buildRawAppend(sparkplug.KindProdProcessedCount, rawTs, info, 1, s.value, f64(1000+s.value), f64(5), nil, nil, s.ms, "br")
		if _, err := pool.Exec(ctx, rq.SQL, rq.Args...); err != nil {
			t.Fatalf("bronze append (%v): %v", s, err)
		}
	}

	// ── merged: exactly ONE row, ts truncated to :00, increment = the 2nd sample ──
	var mergedCount int
	var mergedIncr float64
	var mergedSec int
	if err := pool.QueryRow(ctx,
		`SELECT count(*), max(net_production_incr), max(EXTRACT(SECOND FROM ts_value))::int
		   FROM br.equipment_values WHERE id_equipment=42`).
		Scan(&mergedCount, &mergedIncr, &mergedSec); err != nil {
		t.Fatal(err)
	}
	if mergedCount != 1 {
		t.Errorf("merged equipment_values: got %d rows, want 1 (per-second merge)", mergedCount)
	}
	if mergedIncr != 20 {
		t.Errorf("merged net_production_incr = %v, want 20 (2nd sample overwrites via EXCLUDED)", mergedIncr)
	}
	if mergedSec != 0 {
		t.Errorf("merged ts_value seconds = %d, want 0 (truncated to whole second)", mergedSec)
	}

	// ── raw: exactly TWO rows, distinct source_seq, sub-second precision kept ──
	var rawCount, distinctSeq, distinctMs int
	if err := pool.QueryRow(ctx,
		`SELECT count(*), count(DISTINCT source_seq), count(DISTINCT EXTRACT(MILLISECONDS FROM ts_value))
		   FROM br.equipment_values_raw WHERE id_equipment=42`).
		Scan(&rawCount, &distinctSeq, &distinctMs); err != nil {
		t.Fatal(err)
	}
	if rawCount != 2 {
		t.Errorf("equipment_values_raw: got %d rows, want 2 (every sample appended)", rawCount)
	}
	if distinctSeq != 2 {
		t.Errorf("equipment_values_raw distinct source_seq = %d, want 2 (sequence default disambiguates)", distinctSeq)
	}
	if distinctMs != 2 {
		t.Errorf("equipment_values_raw distinct sub-second = %d, want 2 (.250 and .800 retained, no Truncate)", distinctMs)
	}

	// ── immutability: UPDATE and DELETE on the Bronze raw table both raise ──
	if _, err := pool.Exec(ctx, `UPDATE br.equipment_values_raw SET speed = 999 WHERE id_equipment=42`); err == nil {
		t.Errorf("UPDATE on equipment_values_raw succeeded — immutability trigger did not fire")
	}
	if _, err := pool.Exec(ctx, `DELETE FROM br.equipment_values_raw WHERE id_equipment=42`); err == nil {
		t.Errorf("DELETE on equipment_values_raw succeeded — immutability trigger did not fire")
	}
	// The two rows survived the blocked mutations.
	var after int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM br.equipment_values_raw WHERE id_equipment=42`).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after != 2 {
		t.Errorf("equipment_values_raw row count after blocked UPDATE/DELETE = %d, want 2", after)
	}
}
