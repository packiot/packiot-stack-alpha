// Package refsync keeps F3's master/reference tables (packiot_analytics.public) in
// step with the main DB (packiot.public), so F3's rollups compute against the
// SAME inputs as F2 and the F2/F3 identity check can pass.
//
// Why this exists: F2 and F3 run the same Go engine, but they read their
// reference plane from two DIFFERENT physical databases (flows.go: F2 uses the
// main pool, F3 the shadow pool, both RefSchema="public"). shadow-mirror replays
// operational PO/event changes to F3 but NOT master data, so packiot_analytics was
// seeded once and drifted: production_targets 24→0 (zeroes every F3 target),
// packml_register 162→137, equipments 72→74, products/clients missing, etc.
// (audit 2026-07-11). The entity hierarchy (enterprises/sites/areas/shifts/
// shift_hours) and every piot_* function already match — only these master
// tables drift.
//
// Mechanism: for each table, COPY all main rows into a shadow temp table, then
// INSERT … ON CONFLICT DO UPDATE (upsert). Pure upsert — no DELETE — so it never
// trips a foreign key from a flow table (equipment_runtime, production_orders_
// runtime) that references these reference rows, and readers see a consistent
// snapshot (the upsert commits atomically). Rows removed from main are NOT
// pruned from shadow here; that "shadow has extra" case (equipments 74 vs 72) is
// rare and FK-entangled, tracked as a follow-up.
package refsync

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// referenceTables is the drifting master set this job can reconcile with a
// plain PK upsert, in FK-safe order (parents first). Verified live: these were
// empty-or-id-aligned in packiot_analytics, so upsert brings them to parity cleanly
// (production_targets 0→24 was the biggest identity driver).
//
// Deliberately EXCLUDED and why:
//   - enterprises/sites/areas/shifts/shift_hours — already in sync.
//   - flow/output tables (equipment_values/_runtime_*, uns_*) — per-flow outputs.
//   - equipments — shadow carries machines main doesn't (ids 109-112) AND shares
//     only a subset of ids; a PK upsert ADDS main's rows without removing the
//     extras (count drifts further) and the extras are FK-pinned by
//     equipment_runtime. Needs a natural-key + FK-aware reconciliation.
//   - packml_register — shadow has an independent id space; PK upsert collides on
//     the packml_topic UNIQUE. Needs a natural-key (packml_topic) merge that
//     lets shadow keep its own serial ids.
//   - production_orders — written per-flow by pocontrol (hybrid seed+tail); a
//     blanket upsert would clobber F3's minted rows; its historical seed needs a
//     separate strategy.
// The three above are tracked as follow-up reconciliation work.
var referenceTables = []string{
	"clients",
	"product_families",
	"products",
	"production_targets",
}

// primaryKey returns the ordered PK columns of schema.table (for ON CONFLICT).
func primaryKey(ctx context.Context, db *pgxpool.Pool, schema, table string) ([]string, error) {
	rows, err := db.Query(ctx, `
		SELECT a.attname
		  FROM pg_index i
		  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
		 WHERE i.indrelid = ($1 || '.' || $2)::regclass AND i.indisprimary
		 ORDER BY array_position(i.indkey, a.attnum)`, schema, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var pk []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		pk = append(pk, c)
	}
	return pk, rows.Err()
}

// syncTable upserts every row of main.schema.table into shadow.schema.table.
func syncTable(ctx context.Context, main, shadow *pgxpool.Pool, schema, table string) (int64, error) {
	pk, err := primaryKey(ctx, shadow, schema, table)
	if err != nil || len(pk) == 0 {
		return 0, fmt.Errorf("no primary key for %s.%s: %w", schema, table, err)
	}

	// Read the full source table from main.
	rows, err := main.Query(ctx, fmt.Sprintf("SELECT * FROM %s.%s", schema, table))
	if err != nil {
		return 0, fmt.Errorf("read main: %w", err)
	}
	fds := rows.FieldDescriptions()
	cols := make([]string, len(fds))
	for i, f := range fds {
		cols[i] = f.Name
	}
	var data [][]any
	for rows.Next() {
		v, err := rows.Values()
		if err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan main: %w", err)
		}
		data = append(data, v)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if len(data) == 0 {
		return 0, nil
	}

	// Stage in a temp table (shadow's own column shape), then upsert. One tx →
	// the change is atomic to concurrent rollup readers.
	tx, err := shadow.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)

	tmp := "_refsync_" + table
	if _, err := tx.Exec(ctx, fmt.Sprintf("CREATE TEMP TABLE %s ON COMMIT DROP AS SELECT * FROM %s.%s WITH NO DATA", tmp, schema, table)); err != nil {
		return 0, fmt.Errorf("temp: %w", err)
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{tmp}, cols, pgx.CopyFromRows(data)); err != nil {
		return 0, fmt.Errorf("copy: %w", err)
	}

	pkSet := map[string]bool{}
	for _, c := range pk {
		pkSet[c] = true
	}
	var sets []string
	for _, c := range cols {
		if !pkSet[c] {
			sets = append(sets, fmt.Sprintf("%s = EXCLUDED.%s", c, c))
		}
	}
	action := "DO NOTHING"
	if len(sets) > 0 {
		action = "DO UPDATE SET " + strings.Join(sets, ", ")
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(
		"INSERT INTO %s.%s SELECT * FROM %s ON CONFLICT (%s) %s",
		schema, table, tmp, strings.Join(pk, ", "), action)); err != nil {
		return 0, fmt.Errorf("upsert: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return int64(len(data)), nil
}

// SyncOnce upserts every reference table; best-effort per table (a failure on
// one doesn't stop the rest).
func SyncOnce(ctx context.Context, main, shadow *pgxpool.Pool, logger *slog.Logger) error {
	var firstErr error
	for _, t := range referenceTables {
		n, err := syncTable(ctx, main, shadow, "public", t)
		if err != nil {
			logger.Warn("refsync table failed", slog.String("table", t), slog.String("err", err.Error()))
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		logger.Debug("refsync table ok", slog.String("table", t), slog.Int64("rows", n))
	}
	return firstErr
}

// Loop runs SyncOnce on a schedule. Reference data changes rarely (CS Admin
// onboarding), so a few-minute cadence is ample.
func Loop(ctx context.Context, main, shadow *pgxpool.Pool, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("refsync started — mirrors master tables main→packiot_analytics",
		slog.Any("tables", referenceTables), slog.Duration("every", every))
	jobs.Loop(ctx, jobs.Job{Name: "refsync", Every: every, Run: func(ctx context.Context) error {
		return SyncOnce(ctx, main, shadow, logger)
	}}, logger, obs)
}
