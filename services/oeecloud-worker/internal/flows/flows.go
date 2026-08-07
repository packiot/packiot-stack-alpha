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

// Standard returns the worker's shadow destinations: Flow 2
// (shadow_go_port on the main pool) always; Flow 3 (packiot_shadow's
// public) when the shadow pool is configured. This is the staging
// comparator layout — equivalent to StandardFiltered(..., true).
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
	main := Dest{Name: "shadow_go_port", Pool: pool, EvSchema: "shadow_go_port", RefSchema: "public"}
	if !shadowGoPortEnabled {
		main = Dest{Name: "public", Pool: pool, EvSchema: "public", RefSchema: "public"}
	}
	d := []Dest{main}
	if shadowPool != nil {
		d = append(d, Dest{Name: "packiot_shadow", Pool: shadowPool, EvSchema: "public", RefSchema: "public"})
	}
	return d
}
