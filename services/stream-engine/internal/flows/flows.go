// Package flows defines the worker's shadow-flow destinations — the
// one place that knows the EvSchema/RefSchema split (flow tables live
// per-schema; reference tables live in public on BOTH databases).
// Replaces the per-package Dest structs that events and reports each
// grew independently (periodic-refactor round).
package flows

import "github.com/jackc/pgx/v5/pgxpool"

// Dest carries the per-LAYER schema each SQL site qualifies its tables with.
// The medallion split (ADR-0045 #228/#231/#233) and the t237 public-schema reorg
// give every table a real home schema; a table's SET SCHEMA move is absorbed by
// flipping ONE field here (no per-SQL-site edit), which is why the phased reorg
// (P-silver: GrainSchema→silver; P-core: RefSchema→core; #228: SilverSchema; #233:
// GoldSchema; #239: the caggs off EvSchema) each collapses to a one-line change.
//
// Historically Dest carried only EvSchema/RefSchema and every flow table hid behind
// a public shim view; this struct peels those shims apart so they can be dropped.
type Dest struct {
	Name string
	Pool *pgxpool.Pool
	// EvSchema — the flow residue that has NOT yet been re-homed: the legacy caggs
	// (ca_agg_equipment_values_1min/_1hour), the event side-tables
	// (equipment_events_cpac_shadow/_man/_low_speed) and data_quality_event. Also the
	// search_path anchor RunProvision sets before calling the PL/pgSQL provision fns.
	EvSchema string
	// RefSchema — the dimension plane: equipments, sites, areas, production_orders,
	// packml_register, shifts, shift_hours, production_targets, box_production_bridges,
	// oee_targets, scrap_targets. t237 P-core flips this to `core`.
	RefSchema string
	// SilverSchema — facts + silver caggs: equipment_values, equipment_events,
	// equipment_live_metrics, equipment_metrics_1min/_1hour, equipment_categorical_*.
	SilverSchema string
	// GoldSchema — OEE grains: equipment_oee_* (hourly/daily/weekly/monthly/shift/…),
	// area_oee_*, site_oee_*, production_orders_runtime.
	GoldSchema string
	// GrainSchema — current-state grains: equipment_live_{day,hour,job,month,shift,week},
	// area_live_{day,shift}, site_live_day. t237 P-silver flips this to `silver`.
	GrainSchema string
	// ConfigSchema — the i18n/label config plane read by the boxes flow: label_formats.
	// t241 app-split moved label_formats `app → config` (user_logs, the other former
	// AppSchema table, is threaded separately via route.auth → `auth`, since the split
	// sends them to different schemas). Keeping this a knob lets the app shims drop.
	ConfigSchema string
}

// Standard returns the worker's background-job destinations. The old F1/F2/F3
// shadow-comparison model is retired (#252) — there is exactly ONE live flow:
//
//   - analyticsPool != nil (staging): packiot_analytics IS the live flow (the
//     medallion + t237 reorg re-homed the tables). Roll up ONLY that.
//   - analyticsPool == nil (new-prod, single-flow, ADR-0045 G3): the flow lives
//     in `public` on the main pool (medallion not yet forward-ported there).
//
// (Producers emit only source_type="refactored" on every env — SHADOW_EMIT_GO /
// SHADOW_EMIT_PRODUCTION are false — so there is no `shadow_go_port` F2 leg nor
// F1 `public` comparator leg left to route.)
func Standard(pool, analyticsPool *pgxpool.Pool) []Dest {
	if analyticsPool != nil {
		// STAGING live flow — the medallion + t237 reorg have re-homed the tables:
		// facts→silver, OEE grains→gold, label_formats→config + user_logs→auth (app-split), current-state
		// grains→silver (P-silver), dims→core (P-core). RefSchema is now `core`: the
		// rollup/reports/events RefSchema reads (equipments, sites, areas, enterprises,
		// clients, production_orders, products, product_families, shifts, production_targets,
		// box_production_bridges, packml_register) hit core.<dim> directly (core.packml_register
		// is a compat view over core.topic_routing). GrainSchema is `silver` (P-silver).
		// NOTE two paths still read `public` via PERMANENT compat shims → core: (a) the
		// shiftresolver hardcodes public.{sites,equipments,shift_hours} (literal, not RefSchema);
		// (b) the rollup grain UPDATE writes public.equipment_live_* (EvSchema, deferred to
		// #228/#233). EvSchema keeps the caggs/event side-tables/data_quality_event no ticket
		// has re-homed.
		return []Dest{{
			Name: "packiot_analytics", Pool: analyticsPool,
			EvSchema: "public", RefSchema: "core",
			SilverSchema: "silver", GoldSchema: "gold",
			GrainSchema: "silver", ConfigSchema: "config",
		}}
	}
	// Single-flow deployment (new-prod, analyticsPool==nil): the three flows have
	// collapsed to one that lives in `public` on the main pool (F3-native), so
	// the main-pool dest IS the live flow — every layer resolves in `public` there
	// (the medallion/reorg has not been forward-ported to that env yet, §9).
	return []Dest{{
		Name: "public", Pool: pool,
		EvSchema: "public", RefSchema: "public",
		SilverSchema: "public", GoldSchema: "public",
		GrainSchema: "public", ConfigSchema: "public",
	}}
}
