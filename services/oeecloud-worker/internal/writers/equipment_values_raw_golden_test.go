//go:build golden

// Behavioural proof for the ADR-0036 §3.6 B1 append-only Bronze dual-write.
//
// §3.6.4 makes the golden fixture the LOAD-BEARING proof for B1: the live
// behavior is *collision recovery*, and the sim-fed staging feed produces zero
// live same-second collisions, so a staging bake cannot exercise it. This test
// drives the REAL writer (Build + BuildRaw, the same methods the handler calls)
// against an ephemeral Postgres and asserts both guarantees TOGETHER:
//
//	feed two ProdProcessedCount samples for the same equipment inside one second
//	  sample A: ts = ...:00.250   (same whole second, different ms)
//	  sample B: ts = ...:00.800
//	assert:
//	  equipment_values      → 1 row   (merged UPSERT: Truncate → :00, B overwrites A)  ← UNCHANGED
//	  equipment_values_raw  → 2 rows  (both retained; source_seq tiebreak)              ← Bronze guarantee
//	repeat with A,B at the SAME ms
//	  equipment_values_raw  → +2 rows (key admits dupes: source_seq alone disambiguates)
//
// It also proves the raw row keeps ms-precision ts_value (NO Truncate) while the
// merged row is truncated to the whole second.
//
// Run: DATABASE_URL=postgres://... go test -tags golden ./internal/writers -run GoldenBronze
package writers

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// bronzeSchemaDDL mirrors the operational equipment_values (UNIQUE(ts_value,
// id_equipment)) + the append-only equipment_values_raw from
// 0036-b1-bronze-raw-append.sql (plain-table variant — the collision proof is
// the PK + INSERT semantics, orthogonal to the hypertable/compression the
// migration adds). Plus the resolver's packml_register × areas × equipments.
const bronzeSchemaDDL = `
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
SET search_path TO public;

CREATE TABLE areas       (id_area int PRIMARY KEY, day_begin int);
CREATE TABLE equipments  (id_equipment int PRIMARY KEY, status_type int);
CREATE TABLE packml_register (
    packml_topic  varchar PRIMARY KEY,
    id_enterprise int, id_site int, id_area int, id_equipment int,
    signal_quality smallint, active boolean DEFAULT true
);

CREATE TABLE equipment_values (
    ts_value              timestamptz NOT NULL,
    id_enterprise int, id_site int, id_area int,
    id_equipment          int NOT NULL,
    tp_equipment          smallint,
    net_production_incr   double precision, net_production_val   double precision,
    gross_production_incr double precision, gross_production_val double precision,
    scrap_incr            double precision, scrap_val            double precision,
    speed real, state int, mode int, sub_mode varchar,
    signal_quality smallint, faults jsonb, check_number bigint,
    UNIQUE (ts_value, id_equipment)
);

-- The append-only twin (migration db/42, plain-table form).
CREATE TABLE equipment_values_raw (LIKE equipment_values INCLUDING DEFAULTS);
ALTER TABLE equipment_values_raw ADD COLUMN ingested_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE equipment_values_raw ADD COLUMN source_seq  bigint      NOT NULL DEFAULT 0;
ALTER TABLE equipment_values_raw ADD PRIMARY KEY (id_equipment, ts_value, source_seq);

INSERT INTO areas       (id_area, day_begin) VALUES (3, 0);
INSERT INTO equipments  (id_equipment, status_type) VALUES (42, 4);
INSERT INTO packml_register (packml_topic, id_enterprise, id_site, id_area, id_equipment, signal_quality, active)
    VALUES ('T/S/A/EQ/EQ', 1, 2, 3, 42, 100, true);
`

const bronzeTopic = "T/S/A/EQ/EQ/Admin/ProdProcessedCount/1/Unit"

func newProcessedMetric(tsMillis int64, value string) *sparkplug.Metric {
	return &sparkplug.Metric{
		Name:      bronzeTopic,
		Timestamp: tsMillis,
		Value:     json.RawMessage(value),
	}
}

// count returns SELECT count(*) FROM t.
func count(t *testing.T, pool *pgxpool.Pool, ctx context.Context, table string) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM "+table).Scan(&n); err != nil {
		t.Fatalf("count %s: %v", table, err)
	}
	return n
}

// writeSample runs the writer's real dual-write for one metric: the merged
// UPSERT (Build) then the append-only Bronze INSERT (BuildRaw), each executed
// exactly as the handler would queue them into the batch.
func writeSample(t *testing.T, pool *pgxpool.Pool, ctx context.Context, w *EquipmentValues, m *sparkplug.Metric) {
	t.Helper()
	q, err := w.Build(ctx, m, "", "public")
	if err != nil || q == nil {
		t.Fatalf("Build: q=%v err=%v", q, err)
	}
	if _, err := pool.Exec(ctx, q.SQL, q.Args...); err != nil {
		t.Fatalf("exec merged upsert: %v", err)
	}
	raw, err := w.BuildRaw(ctx, m, "public")
	if err != nil || raw == nil {
		t.Fatalf("BuildRaw: raw=%v err=%v (flag on?)", raw, err)
	}
	if _, err := pool.Exec(ctx, raw.SQL, raw.Args...); err != nil {
		t.Fatalf("exec bronze raw append: %v", err)
	}
}

func TestGoldenBronzeCollisionRecovery(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, bronzeSchemaDDL); err != nil {
		t.Fatalf("schema ddl: %v", err)
	}

	resolver := sparkplug.NewResolver(pool, time.Minute, time.Minute)
	w := NewEquipmentValues(resolver, slog.New(slog.NewTextHandler(io.Discard, nil)))
	w.SetBronzeRawAppend(true) // BRONZE_RAW_APPEND on — exercise the dual-write.

	// Two samples, SAME whole second, DIFFERENT ms — the sub-second collision.
	base := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC).UnixMilli()
	writeSample(t, pool, ctx, w, newProcessedMetric(base+250, "5"))
	writeSample(t, pool, ctx, w, newProcessedMetric(base+800, "7"))

	// Guarantee 1 — merged table collapses to ONE row (behavior UNCHANGED).
	if got := count(t, pool, ctx, "equipment_values"); got != 1 {
		t.Errorf("equipment_values: want 1 merged row, got %d (merge/parity broken)", got)
	}
	// Guarantee 2 — Bronze retains BOTH (no raw sample lost).
	if got := count(t, pool, ctx, "equipment_values_raw"); got != 2 {
		t.Errorf("equipment_values_raw: want 2 retained rows, got %d (Bronze lost a sample)", got)
	}
	// The merged row's counter is the LAST writer's value (B overwrote A).
	var merged float64
	if err := pool.QueryRow(ctx, "SELECT net_production_incr FROM equipment_values").Scan(&merged); err != nil {
		t.Fatalf("read merged: %v", err)
	}
	if merged != 7 {
		t.Errorf("merged net_production_incr: want 7 (B overwrote A), got %v", merged)
	}

	// Guarantee 3 — the key admits DUPLICATES: two samples at the SAME ms still
	// coexist in *_raw via the source_seq tiebreak alone.
	writeSample(t, pool, ctx, w, newProcessedMetric(base+500, "9"))
	writeSample(t, pool, ctx, w, newProcessedMetric(base+500, "11"))
	if got := count(t, pool, ctx, "equipment_values_raw"); got != 4 {
		t.Errorf("equipment_values_raw after same-ms pair: want 4, got %d (source_seq not admitting dupes)", got)
	}

	// Bronze keeps ms-precision ts_value (NO Truncate); the merged write does not.
	var subsecond bool
	if err := pool.QueryRow(ctx,
		`SELECT bool_or(date_part('milliseconds', ts_value)::int <> 0) FROM equipment_values_raw`,
	).Scan(&subsecond); err != nil {
		t.Fatalf("read raw ts precision: %v", err)
	}
	if !subsecond {
		t.Error("equipment_values_raw: expected sub-second ts_value retained, found none (Truncate leaked into Bronze)")
	}
	var mergedTrunc bool
	if err := pool.QueryRow(ctx,
		`SELECT bool_and(date_part('milliseconds', ts_value)::int = 0) FROM equipment_values`,
	).Scan(&mergedTrunc); err != nil {
		t.Fatalf("read merged ts precision: %v", err)
	}
	if !mergedTrunc {
		t.Error("equipment_values: merged row must be truncated to the whole second")
	}
}

// TestGoldenBronzeFlagOffNoRawWrite proves the default-OFF path is a true no-op:
// with BRONZE_RAW_APPEND off, BuildRaw returns nil and NOTHING lands in *_raw —
// byte-identical to pre-B1.
func TestGoldenBronzeFlagOffNoRawWrite(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, bronzeSchemaDDL); err != nil {
		t.Fatalf("schema ddl: %v", err)
	}

	resolver := sparkplug.NewResolver(pool, time.Minute, time.Minute)
	w := NewEquipmentValues(resolver, slog.New(slog.NewTextHandler(io.Discard, nil)))
	// Flag left OFF (default).

	m := newProcessedMetric(time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC).UnixMilli()+250, "5")
	q, err := w.Build(ctx, m, "", "public")
	if err != nil || q == nil {
		t.Fatalf("Build: q=%v err=%v", q, err)
	}
	if _, err := pool.Exec(ctx, q.SQL, q.Args...); err != nil {
		t.Fatalf("exec merged upsert: %v", err)
	}
	raw, err := w.BuildRaw(ctx, m, "public")
	if err != nil {
		t.Fatalf("BuildRaw (flag off) err: %v", err)
	}
	if raw != nil {
		t.Errorf("BuildRaw must return nil when flag off, got %+v", raw)
	}
	if got := count(t, pool, ctx, "equipment_values_raw"); got != 0 {
		t.Errorf("equipment_values_raw: want 0 rows with flag off, got %d", got)
	}
	if got := count(t, pool, ctx, "equipment_values"); got != 1 {
		t.Errorf("equipment_values: merged write must still land, got %d", got)
	}
}
