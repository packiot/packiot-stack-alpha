// Package tenants resolves the current set of active tenants from the
// database, so the AMQP topology can declare per-tenant queues without
// requiring a static config file.
//
// "Tenant" here means the lowercased Sparkplug group_id — the first
// '/'-separated segment of packml_topic. e.g.:
//
//	packml_topic: CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent
//	              ^^^^^
//	              group_id → tenant "cpack"
//
// Source of truth is packml_register.active = true; CS Admin owns this
// onboarding flow per the project CLAUDE.md.
//
// Phase 1 of Strategy C (see services/oeecloud-worker/docs/strategy-c-per-tenant-queues.md):
// per-tenant queues are declared alongside the legacy oeecloud-worker-q,
// but the worker still CONSUMES the legacy queue. No traffic change.
package tenants

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// DiscoverActive returns the lowercased, sorted list of distinct
// group_ids across all active packml_register rows. Empty result means
// no tenants are onboarded; caller should decide whether that's a fatal
// boot condition or recoverable.
//
// The query relies on Postgres's split_part — it's stable across Postgres
// versions and faster than pulling all rows and splitting in Go.
func DiscoverActive(ctx context.Context, pool *pgxpool.Pool) ([]string, error) {
	const q = `
		SELECT DISTINCT lower(split_part(packml_topic, '/', 1)) AS tenant
		FROM packml_register
		WHERE active = true
		  AND packml_topic LIKE '%/%'  -- guard against malformed rows
		ORDER BY 1
	`
	rows, err := pool.Query(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("query packml_register: %w", err)
	}
	defer rows.Close()

	var tenants []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, fmt.Errorf("scan tenant: %w", err)
		}
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		tenants = append(tenants, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iter packml_register: %w", err)
	}
	return tenants, nil
}
