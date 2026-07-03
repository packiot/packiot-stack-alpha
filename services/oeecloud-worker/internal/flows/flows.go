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
// public) when the shadow pool is configured.
func Standard(pool, shadowPool *pgxpool.Pool) []Dest {
	d := []Dest{{Name: "shadow_go_port", Pool: pool, EvSchema: "shadow_go_port", RefSchema: "public"}}
	if shadowPool != nil {
		d = append(d, Dest{Name: "packiot_shadow", Pool: shadowPool, EvSchema: "public", RefSchema: "public"})
	}
	return d
}
