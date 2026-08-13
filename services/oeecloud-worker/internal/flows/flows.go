// Package flows defines the worker's shadow-flow destinations — the
// one place that knows the EvSchema/RefSchema split (flow tables live
// per-schema; reference tables live in public on BOTH databases).
// Replaces the per-package Dest structs that events and reports each
// grew independently (periodic-refactor round).
package flows

import "github.com/jackc/pgx/v5/pgxpool"

type Dest struct {
	Name      string
	Pool      *pgxpool.Pool
	EvSchema  string // flow tables (equipment_values, events, boxes…)
	RefSchema string // reference plane (equipments, packml_register…)
}

// Standard returns the worker's shadow destinations. When a shadow pool is
// configured (staging), it's F3-only (packiot_shadow) — the main-pool dest is
// a dead comparator artifact (see StandardFiltered). Equivalent to
// StandardFiltered(..., true), which now ignores the flag when shadowPool!=nil.
func Standard(pool, shadowPool *pgxpool.Pool) []Dest {
	return StandardFiltered(pool, shadowPool, true)
}

// StandardFiltered returns the worker's background-job destinations,
// choosing the MAIN-POOL flow with shadowGoPortEnabled:
//
//   - true  — the F2 comparator layout (staging default): the main-pool
//     flow is the `shadow_go_port` schema, sitting alongside F1 (`public`)
//     for the differential bake.
//   - false — a single-flow deployment (ADR-0045 G3, new-prod): the three
//     flows have collapsed to one and it lives in `public` on the main
//     pool (F3-native — the same schema the ingest path writes to via the
//     nil-shadow fallback for source_type ""/"refactored"). The
//     `shadow_go_port` schema does NOT exist there, so pointing the
//     background jobs at it made every tick error 42P01; the jobs must
//     target `public` instead — otherwise the single flow has no rollup
//     engine at all.
//
// The F3 comparator dest (packiot_shadow, a separate database) is appended
// whenever a shadow pool is configured, independent of the flag.
func StandardFiltered(pool, shadowPool *pgxpool.Pool, shadowGoPortEnabled bool) []Dest {
	// When a dedicated F3 shadow pool is configured (the staging comparator
	// setup), packiot_shadow IS the live flow — roll up ONLY that. The main-pool
	// dest is a dead comparator artifact now that F2 is retired (shadow_go_port
	// DROPped) and the bake is off (BAKE_COMPARATOR_ENABLED=false): rolling up
	// shadow_go_port errors 42P01 (schema gone), and rolling up legacy `public`
	// (F1, unread — dashboards read F3) just errors against its incompletely
	// provisioned schema (missing grain/cagg/shadow tables). shadowGoPortEnabled
	// is therefore moot here. See ADR-0045 G3 + the 2026-08-13 residuals sweep.
	if shadowPool != nil {
		return []Dest{{Name: "packiot_shadow", Pool: shadowPool, EvSchema: "public", RefSchema: "public"}}
	}
	// Single-flow deployment (new-prod, shadowPool==nil): the three flows have
	// collapsed to one that lives in `public` on the main pool (F3-native), so
	// the main-pool dest IS the live flow. shadow_go_port only if F2 is alive.
	main := Dest{Name: "public", Pool: pool, EvSchema: "public", RefSchema: "public"}
	if shadowGoPortEnabled {
		main = Dest{Name: "shadow_go_port", Pool: pool, EvSchema: "shadow_go_port", RefSchema: "public"}
	}
	return []Dest{main}
}
