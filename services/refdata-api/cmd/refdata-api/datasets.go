// datasets.go — front4 read-census datasets on the composable query API.
//
// The 2026-07-07 front4 audit counted 67 distinct Hasura root fields;
// 10 map to the fixed /v1/* routes (main.go's endpoint table), the rest
// cluster into the dataset groups below. Each dataset is a NAMED,
// allowlisted query — POST /v1/query {"dataset", "window", "filters"} —
// compiled to the same h_piot_* SQL function (or scoped table read)
// Hasura fronted. Every backing object was verified live on staging
// (2026-07-07 pg_proc / information_schema enumeration).
//
// Safety is by construction, same as the metric catalog in query.go:
//   - customer_id comes from the API key, NEVER the body ($1 always).
//   - unknown datasets / filter keys / out-of-enum values are rejected
//     at compile time; windows have per-dataset budgets; every SQL gets
//     the shared row cap appended.
//   - per-equipment functions (which take only an equipment id) are
//     wrapped in an EXISTS ownership guard on equipments.id_enterprise.
//   - enterprise-config projects enterprises MINUS api_key; users
//     projects MINUS operator_pw_hash / id_user_firebase.
//
// Wire-format notes (Hasura parity):
//   - id-list args are postgres int-array literals ("{1,2}") because
//     the functions cast their text args with ::int[] and treat
//     cardinality 0 as "no filter".
//   - enum args (time_grain / nav_level / group_by / partition_by) are
//     bound UPPERCASE — the functions compare raw against 'HOUR',
//     'SHIFTS', 'EQUIPMENT', … . "none" deliberately misses every CASE
//     arm (the functions' else-branch = no grouping).
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
)

// errRoleDatasetNeedsUser is returned by compileDataset when a per-user-role
// dataset is requested without a server-resolved user identity — i.e. via the
// X-Api-Key operator path (no user axis) or by a role-less user. The handler
// maps it to 403: the request is well-formed and authenticated, but this
// dataset is front4-JWT-only. Failing closed here is the whole point — it is
// the guard that stops anyone accidentally shipping an unscoped, tenant-wide
// role list to a caller that never proved which role is theirs (task #70 §3).
var errRoleDatasetNeedsUser = errors.New("dataset requires user context (front4 Firebase JWT); not available via X-Api-Key")

// callerRole is the server-derived per-user axis threaded into compileDataset
// for the two role bootstrap datasets. It comes from userRoleFromContext (set
// only on the verified-JWT path), NEVER from the request body. present=false ⇒
// no user identity ⇒ the role datasets fail closed with errRoleDatasetNeedsUser.
type callerRole struct {
	id      int
	present bool
}

// ── Parameter model ──────────────────────────────────────────────────
//
// A dataset's params list IS its SQL argument list: params[i] binds
// $(i+1). Injected kinds (enterprise, window bounds, derived flags)
// never come from the client; the rest are looked up in "filters".

type pKind int

const (
	pEnterprise    pKind = iota // customer_id from the API key
	pFrom                       // window.from
	pTo                         // window.to
	pIDList                     // filters.<name>: []int → "{1,2}" ("{}" when absent = no filter)
	pEquipmentID                // filters.<name>: single int, required (ownership guard in SQL)
	pEnum                       // filters.<name>: string from allowlist; enum[0] is the default
	pBool                       // filters.<name>: bool, default false
	pShiftFiltered              // derived: len(filters.shifts) > 0
	pTeamFiltered               // derived: len(filters.teams) > 0
	pUserRole                   // task #70: server-derived id_user_role → $2; NEVER client-supplied; absent ⇒ errRoleDatasetNeedsUser
	pDateScalar                 // task #54: filters.<name>: a required date/datetime string, validated + bound as a positional ::date/::timestamp arg
)

type dsParam struct {
	kind pKind
	name string
	enum []string
}

func ids(name string) dsParam { return dsParam{kind: pIDList, name: name} }
func oneOf(name string, vals ...string) dsParam {
	return dsParam{kind: pEnum, name: name, enum: vals}
}

// pDate declares a required scalar date/datetime filter, bound positionally as
// a ::date/::timestamp arg (the SQL decides the cast). The value is validated
// against a fixed set of layouts (YYYY-MM-DD, 'YYYY-MM-DD HH:MM:SS', RFC3339)
// and bound as a time.Time — never interpolated into the SQL text — so it is a
// client FILTER (like ids()/oneOf()), never the tenant axis. It is intentionally
// NOT a window bound: these datasets bucket a single point in time (a month, a
// from-instant, an hour) rather than scan a [from,to] range.
func pDate(name string) dsParam { return dsParam{kind: pDateScalar, name: name} }

var (
	pEnt     = dsParam{kind: pEnterprise}
	pRole    = dsParam{kind: pUserRole} // no name ⇒ not a client-settable filter (server-derived only)
	pWinFrom = dsParam{kind: pFrom}
	pWinTo   = dsParam{kind: pTo}
	pEquip   = dsParam{kind: pEquipmentID, name: "equipment"}
	pPO      = dsParam{kind: pEquipmentID, name: "production_order"} // single required int, tenant-fenced by the SQL's outer WHERE id_enterprise = $1
	pShiftF  = dsParam{kind: pShiftFiltered}
	pTeamF   = dsParam{kind: pTeamFiltered}
	pMicro   = dsParam{kind: pBool, name: "microstops"}
	pGrain   = oneOf("time_grain", "day", "hour", "week", "month")
	pNav     = oneOf("nav_level", "equipment", "area", "site", "enterprise")
	pGroupBy = oneOf("group_by", "none", "shifts", "teams")
	pPartBy  = oneOf("partition_by", "none", "shifts", "teams")
)

// Window budgets: runtime-shift-level aggregation functions are cheap
// per row and front4 has month/year views (analyticsWindow); event-level
// functions fan out to equipment_events (eventWindow).
const (
	analyticsWindow = 400 * 24 * time.Hour
	eventWindow     = 90 * 24 * time.Hour
)

type dataset struct {
	group     string // front4-census dataset group (coverage table key)
	doc       string
	sql       string // placeholders follow params order; row cap appended at compile
	windowed  bool
	maxWindow time.Duration
	params    []dsParam
}

// perEquipment wraps an idequipment-only overview function in the
// tenancy guard: $1 = enterprise (injected), $2 = equipment (client).
func perEquipment(group, doc, fn string) dataset {
	return dataset{
		group: group, doc: doc,
		sql: `SELECT f.* FROM ` + fn + `($2) f WHERE EXISTS
			(SELECT 1 FROM equipments e WHERE e.id_equipment = $2 AND e.id_enterprise = $1)`,
		params: []dsParam{pEnt, pEquip},
	}
}

// liveUNS scopes a per-equipment uns_equipment_current_* snapshot table
// (no id_enterprise column of its own) through the equipments hierarchy.
func liveUNS(doc, table string) dataset {
	return dataset{
		group: "live-uns-equipment", doc: doc,
		sql: `SELECT t.* FROM ` + table + ` t JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND (cardinality($2::int[]) = 0 OR t.id_equipment = ANY($2::int[]))`,
		params: []dsParam{pEnt, ids("equipments")},
	}
}

var datasets = map[string]dataset{
	// ── oee ──────────────────────────────────────────────────────────
	// h_piot_oee_score_with_teams is an 11-arg fn on BOTH staging AND prod
	// (verified live via pg_get_function_arguments, task #90): it ends at
	// is_shift_filtered and has NO is_team_filtered — unlike its 12-arg sibling
	// h_piot_oee_progress_new2 (below), from which the extra pTeamF binding was
	// mistakenly copied. Binding 12 positional args would 500 on both DBs, so
	// we bind the 11 args the real signature accepts. in_ids_teams (the teams
	// vector, $6) is still passed; only the phantom is_team_filtered flag is
	// dropped — no functionality lost (the fn never implemented that flag).
	"oee-score-teams": {
		group: "oee", doc: "OEE score split by shifts/teams (h_piot_oee_score_with_teams)",
		sql:      `SELECT * FROM h_piot_oee_score_with_teams($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("equipments"), ids("areas"), ids("sites"), ids("shifts"),
			ids("teams"), pWinFrom, pWinTo, pGrain, pNav, pShiftF},
	},
	"oee-score-full": {
		group: "oee", doc: "Full OEE score breakdown (h_piot_oee_score_full_3)",
		sql:      `SELECT * FROM h_piot_oee_score_full_3($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("equipments"), ids("areas"), ids("sites"), ids("shifts"),
			pWinFrom, pWinTo, pGrain, pNav, pShiftF},
	},
	"oee-progress": {
		group: "oee", doc: "OEE progress over time (h_piot_oee_progress_new2)",
		sql:      `SELECT * FROM h_piot_oee_progress_new2($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("equipments"), ids("areas"), ids("sites"), ids("shifts"),
			ids("teams"), pWinFrom, pWinTo, pGrain, pNav, pShiftF, pTeamF},
	},
	// oee-by-month (task #54, ADR-0031 §2b-1 — was back4 GET /api/admin/oeeavgmonth/{id},
	// OeeRepository.getAvgOeebyMonth). equipment_runtime_shift has NO id_enterprise
	// column, so — exactly like custom-target-* / liveUNS — we scope through
	// `equipments` ($1 = tenant, $2 = the ownership-guarded equipment). back4 took a
	// bare (id_equipment, date) with NO tenant fence; the fence is the load-bearing
	// rewrite. Projection-shaped per ADR-0027 rule #2 (avg(oee) AS oee, not SELECT *);
	// the month scalar is bound via pDate ($3), never a window. Not windowed.
	"oee-by-month": {
		group: "oee", doc: "Avg OEE per shift for one equipment's month (equipment_runtime_shift, scoped through equipments)",
		sql: `SELECT avg(r.oee) AS oee, r.cd_shift
			FROM equipment_runtime_shift r JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND e.id_equipment = $2
			AND date_trunc('month', r.ts_value) = date_trunc('month', $3::date)
			AND r.cd_shift IS NOT NULL
			GROUP BY r.cd_shift ORDER BY r.cd_shift`,
		params: []dsParam{pEnt, pEquip, pDate("month")},
	},

	// ── live-uns-equipment (snapshot tables — no window by design) ───
	"live-equipment-metrics": {
		group: "live-uns-equipment", doc: "Live equipment state/speed/status snapshot (uns_equipment_current_metrics)",
		sql: `SELECT * FROM uns_equipment_current_metrics
			WHERE id_enterprise = $1 AND (cardinality($2::int[]) = 0 OR id_equipment = ANY($2::int[]))`,
		params: []dsParam{pEnt, ids("equipments")},
	},
	"live-equipment-job":   liveUNS("Current job snapshot per equipment (uns_equipment_current_job)", "uns_equipment_current_job"),
	"live-equipment-day":   liveUNS("Current day snapshot per equipment (uns_equipment_current_day)", "uns_equipment_current_day"),
	"live-equipment-shift": liveUNS("Current shift snapshot per equipment (uns_equipment_current_shift)", "uns_equipment_current_shift"),
	"live-equipment-month": liveUNS("Current month snapshot per equipment (uns_equipment_current_month)", "uns_equipment_current_month"),

	// ── mission-control ──────────────────────────────────────────────
	"mission-control": {
		group: "mission-control", doc: "Mission control equipment grid (h_piot_get_mission_control_uns_3)",
		sql:    `SELECT * FROM h_piot_get_mission_control_uns_3($1,$2,$3,$4)`,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments")},
	},
	"mission-control-area": {
		group: "mission-control", doc: "Mission control area rollup (h_piot_get_mission_control_area_uns_2)",
		sql:    `SELECT * FROM h_piot_get_mission_control_area_uns_2($1,$2,$3)`,
		params: []dsParam{pEnt, ids("areas"), ids("sites")},
	},
	"mission-control-timeline": {
		group: "mission-control", doc: "Mission control status timeline (h_piot_get_mission_control_timeline)",
		sql:    `SELECT * FROM h_piot_get_mission_control_timeline($1,$2,$3,$4)`,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments")},
	},

	// ── overview-detail (per-equipment, tenancy-guarded) ─────────────
	"overview-job-info": perEquipment("overview-detail",
		"Current job info for one equipment (h_piot_overview_i_get_job_info)", "h_piot_overview_i_get_job_info"),
	"overview-events": perEquipment("overview-detail",
		"Overview event list, live generation (h_piot_overview_i_get_events_3)", "h_piot_overview_i_get_events_3"),
	"overview-events-legacy": perEquipment("overview-detail",
		"Overview event list, legacy generation (h_piot_overview_i_get_events)", "h_piot_overview_i_get_events"),
	"overview-production-chart": perEquipment("overview-detail",
		"Overview production chart, live generation (h_piot_overview_production_chart_v6)", "h_piot_overview_production_chart_v6"),
	"overview-production-chart-legacy": perEquipment("overview-detail",
		"Overview production chart, legacy generation (h_piot_overview_i_production_chart)", "h_piot_overview_i_production_chart"),
	"overview-production-health": perEquipment("overview-detail",
		"Production health gauge (h_piot_get_production_health)", "h_piot_get_production_health"),
	"overview-downtimes-by-category": perEquipment("overview-detail",
		"Downtime duration by category for one equipment (h_piot_downtimes_duration_by_category)", "h_piot_downtimes_duration_by_category"),

	// ── downtimes-analytics ──────────────────────────────────────────
	"downtimes-summary": {
		group: "downtimes-analytics", doc: "Downtimes summary (h_piot_get_downtimes_resumo)",
		sql:      `SELECT * FROM h_piot_get_downtimes_resumo($1,$2,$3,$4,$5,$6,$7,$8)`,
		windowed: true, maxWindow: eventWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("shifts"),
			pWinFrom, pWinTo, ids("teams")},
	},
	"downtimes-per-category": {
		group: "downtimes-analytics", doc: "Downtimes grouped by category (h_piot_get_downtimes_per_category)",
		sql:      `SELECT * FROM h_piot_get_downtimes_per_category($1,$2,$3,$4,$5,$6,$7,$8)`,
		windowed: true, maxWindow: eventWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("shifts"),
			pWinFrom, pWinTo, ids("teams")},
	},
	"downtimes-events": {
		group: "downtimes-analytics", doc: "Downtime event list, live generation (h_piot_get_downtimes_events_2)",
		sql:      `SELECT * FROM h_piot_get_downtimes_events_2($1,$2,$3,$4,$5,$6,$7,$8)`,
		windowed: true, maxWindow: eventWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("sectors"),
			pWinFrom, pWinTo, pMicro},
	},
	"downtimes-events-legacy": {
		group: "downtimes-analytics", doc: "Downtime event list, legacy generation (h_piot_get_downtimes_events)",
		sql:      `SELECT * FROM h_piot_get_downtimes_events($1,$2,$3,$4,$5,$6,$7,$8)`,
		windowed: true, maxWindow: eventWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("sectors"),
			pWinFrom, pWinTo, pMicro},
	},

	// ── total-production / single-period / machine-speed / flow ─────
	"total-production": {
		group: "total-production", doc: "Total production partitioned by shifts/teams (h_piot_total_production_teams_2)",
		sql:      `SELECT * FROM h_piot_total_production_teams_2($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("shifts"),
			ids("teams"), pWinFrom, pWinTo, pPartBy, pGrain},
	},
	"single-period": {
		group: "single-period", doc: "Single-period comparison, live generation (h_piot_single_period_with_teams_4)",
		sql:      `SELECT * FROM h_piot_single_period_with_teams_4($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("shifts"),
			ids("teams"), pWinFrom, pWinTo, pGrain, pGroupBy},
	},
	"single-period-legacy": {
		group: "single-period", doc: "Single-period comparison, legacy generation (h_piot_single_period_with_teams_3)",
		sql:      `SELECT * FROM h_piot_single_period_with_teams_3($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("shifts"),
			ids("teams"), pWinFrom, pWinTo, pGrain, pGroupBy},
	},
	"machine-speed": {
		group: "machine-speed", doc: "Machine speed series (h_piot_machine_speed)",
		sql:      `SELECT * FROM h_piot_machine_speed($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
		windowed: true, maxWindow: eventWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("shifts"),
			ids("teams"), pWinFrom, pWinTo, pGrain, pGroupBy},
	},
	"production-flow": {
		group: "production-flow", doc: "Production flow (infeed/outfeed) series (h_piot_production_flow)",
		sql:      `SELECT * FROM h_piot_production_flow($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
		windowed: true, maxWindow: eventWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("shifts"),
			ids("teams"), pWinFrom, pWinTo, pGrain},
	},

	// ── targets ──────────────────────────────────────────────────────
	"targets": {
		group: "targets", doc: "Computed targets vs actuals (h_piot_get_targets)",
		sql:      `SELECT * FROM h_piot_get_targets($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("equipments"), ids("areas"), ids("sites"), ids("shifts"),
			ids("teams"), pWinFrom, pWinTo, pGrain, pNav, pGroupBy},
	},
	"production-targets": {
		group: "targets", doc: "Configured production targets (production_targets)",
		sql:    `SELECT * FROM production_targets WHERE id_enterprise = $1`,
		params: []dsParam{pEnt},
	},
	"scrap-targets": {
		group: "targets", doc: "Configured scrap targets (scrap_targets)",
		sql:    `SELECT * FROM scrap_targets WHERE id_enterprise = $1`,
		params: []dsParam{pEnt},
	},
	"oee-targets": {
		group: "targets", doc: "Configured OEE targets (oee_targets)",
		sql:    `SELECT * FROM oee_targets WHERE id_enterprise = $1`,
		params: []dsParam{pEnt},
	},

	// ── home (front4 Home page) ──────────────────────────────────────
	// h_piot_home_uns self-scopes: enterprise is arg 1 and the body filters
	// id_enterprise = in_id_enterprise on both areas and equipments
	// (tp_equipment=3, line level). No wrapper needed. Not windowed — it
	// returns the current live sites→areas→lines OEE tree.
	"home-uns": {
		group: "home", doc: "Home page live OEE tree (h_piot_home_uns)",
		sql:    `SELECT * FROM h_piot_home_uns($1)`,
		params: []dsParam{pEnt},
	},

	// ── events-timeline (front4 events timelines) ────────────────────
	// events-timeline-from-po: the function takes ONLY a PO id and derives
	// the equipment from the PO — it does NOT take an enterprise arg, so
	// without a fence a caller could probe another tenant's PO ids. Its
	// output carries id_enterprise, so we wrap `WHERE id_enterprise = $1`:
	// $1 = the caller's tenant, $2 = the PO id. A PO in another tenant
	// yields zero rows. Not windowed.
	"events-timeline-from-po": {
		group: "events-timeline", doc: "Event timeline for one production order (h_piot_get_events_timeline_from_po)",
		sql:    `SELECT * FROM h_piot_get_events_timeline_from_po($2) WHERE id_enterprise = $1`,
		params: []dsParam{pEnt, pPO},
	},
	// events-timeline-full: enterprise is arg 1 (self-scoping). The id-filter
	// text args are postgres array literals ('{1,2}') the function ::int[]-
	// casts — exactly pIDList's wire format; '{}' = no narrowing. The optional
	// middle arg _id_production_order (DEFAULT NULL) is pinned to a literal
	// NULL so the window binds cleanly at $6/$7 without a null-param kind.
	"events-timeline-full": {
		group: "events-timeline", doc: "Full filtered event timeline (h_piot_get_events_timeline_full_with_filter_3)",
		sql:      `SELECT * FROM h_piot_get_events_timeline_full_with_filter_3($1,$2,$3,$4,$5,NULL,$6,$7)`,
		windowed: true, maxWindow: eventWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("event_types"), pWinFrom, pWinTo},
	},

	// ── production-orders (front4 PO runtime views) ──────────────────
	// Both functions share downtimes-summary's exact arg shape: enterprise
	// arg 1 (self-scoping), then the site/area/equipment/shift id-filter
	// literals, the [tsstart,tsend] window, and a trailing teams filter.
	// _runtimes = one row per PO runtime segment; _with_runtimes4 = one row
	// per PO with a nested `runtimes` json array. Windowed at analyticsWindow
	// (front4's PO views span months).
	"production-orders-runtimes": {
		group: "production-orders", doc: "One row per PO runtime segment (h_piot_production_orders_runtimes)",
		sql:      `SELECT * FROM h_piot_production_orders_runtimes($1,$2,$3,$4,$5,$6,$7,$8)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("shifts"),
			pWinFrom, pWinTo, ids("teams")},
	},
	"production-orders-with-runtimes": {
		group: "production-orders", doc: "One row per PO with nested runtimes (h_piot_production_orders_with_runtimes4)",
		sql:      `SELECT * FROM h_piot_production_orders_with_runtimes4($1,$2,$3,$4,$5,$6,$7,$8)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("sites"), ids("areas"), ids("equipments"), ids("shifts"),
			pWinFrom, pWinTo, ids("teams")},
	},

	// ── enterprise-config ────────────────────────────────────────────
	// Explicit projections: enterprises minus api_key (the tenancy
	// secret must never transit this API), users minus operator_pw_hash
	// and id_user_firebase (credentials / auth-provider internals).
	"enterprise-config": {
		group: "enterprise-config", doc: "Enterprise settings (enterprises minus api_key)",
		sql: `SELECT id_enterprise, nm_enterprise, week_begin, day_begin, week_size, timezone,
			logo_url, active, basic_menu, custom_menu, language_packs, scrap_calc_type
			FROM enterprises WHERE id_enterprise = $1`,
		params: []dsParam{pEnt},
	},
	"users": {
		group: "enterprise-config", doc: "Enterprise users (minus credential columns)",
		sql: `SELECT id_user, user_email, user_name, id_enterprise, phone_number, user_roles,
			timezone, languages, user_menu, internal_user, active
			FROM users WHERE id_enterprise = $1`,
		params: []dsParam{pEnt},
	},
	"user-roles": {
		group: "enterprise-config", doc: "Role definitions and permissions (user_roles)",
		sql: `SELECT id_user_role, nm_user_role, id_enterprise, permissions, super_user
			FROM user_roles WHERE id_enterprise = $1`,
		params: []dsParam{pEnt},
	},

	// ── variables-context (front4 GET_VARIABLES_CONTEXT bootstrap) ───────
	// The front4 bootstrap read (src/Context/Query.js) fans out over six
	// root fields, ALL scoped server-side by the Firebase JWT's uid via
	// Hasura row-permissions (no where-clause, no vars in the query). Four
	// of the six are already covered as tenant-scoped datasets:
	// `enterprise-config` (enterprises MINUS api_key — the whole point of
	// this migration is to STOP shipping api_key to the browser), `users`,
	// `user-roles`, and the /v1/language-packs route. The two below add the
	// per-role entity + menu views. TWO-AXIS scoping (task #70): $1 =
	// id_enterprise (tenant) AND $2 = id_user_role (the caller's single role).
	// The role is SERVER-DERIVED from the verified Firebase uid (users.user_roles
	// → userRoleFromContext), never client-supplied — pRole has no filter name,
	// so a request body can neither set nor override it. Absent user context
	// (the X-Api-Key operator path, or a role-less user) ⇒ compileDataset fails
	// closed with errRoleDatasetNeedsUser (403), so no unscoped tenant-wide role
	// list is ever emitted. This replaces #68's uid-discarding gap: the JWT path
	// now resolves uid→(tenant, role) and stashes the role in request context.
	"entities-per-user-role": {
		group: "variables-context", doc: "Per-role entity tree for the bootstrap (v_entities_per_user_role), scoped to the caller's role",
		// Explicit projection MINUS the `enterprise` jsonb blob: that column
		// embeds enterprise config that includes api_key on this view, so a
		// SELECT * would re-leak the secret this migration exists to remove.
		// front4 reads enterprise scalars from `enterprise-config` instead.
		sql: `SELECT id_enterprise, id_user_role, nm_user_role,
			sites, areas, equipments, sectors, shifts, teams
			FROM v_entities_per_user_role WHERE id_enterprise = $1 AND id_user_role = $2`,
		params: []dsParam{pEnt, pRole},
	},
	"menu-per-user-role": {
		group: "variables-context", doc: "Per-role menu for the bootstrap (v_menu_per_user_role), scoped to the caller's role",
		sql:    `SELECT id_enterprise, id_user_role, menu FROM v_menu_per_user_role WHERE id_enterprise = $1 AND id_user_role = $2`,
		params: []dsParam{pEnt, pRole},
	},

	// ── settings (front4 Settings/* config reads) ────────────────────────
	// equipment-downtime-reasons: DowntimeReasons2 reads the per-equipment
	// downtime_reasons JSON by equipment id (Hasura scopes the enterprise by
	// permission). We scope enterprise as $1 and take the equipment id as the
	// client filter ($2), same ownership shape as the overview-detail group.
	"equipment-downtime-reasons": {
		group: "settings", doc: "Per-equipment downtime reasons config (equipments.downtime_reasons)",
		sql: `SELECT id_equipment, nm_equipment, downtime_reasons FROM equipments
			WHERE id_enterprise = $1 AND id_equipment = $2`,
		params: []dsParam{pEnt, pEquip},
	},

	// custom-target-{month,week,day}: Settings/Targets reads the customized
	// (manually-overridden) target series per equipment from the
	// equipment_runtime_1{month,week,day} rollup tables. Those tables carry
	// no id_enterprise, so — like liveUNS — we scope through the equipments
	// hierarchy ($1) and take the equipment id as the client filter ($2).
	// The rows are sparse (only target_customized=true), so we omit front4's
	// ts_value lower-bound and return newest-first under the row cap; the
	// adapter applies the date bound client-side. front4's nested
	// `equipment { nm_equipment }` is flattened to an nm_equipment column.
	"custom-target-month": {
		group: "settings", doc: "Customized monthly targets per equipment (equipment_runtime_1month)",
		sql: `SELECT r.ts_value, r.target, e.nm_equipment
			FROM equipment_runtime_1month r JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND e.id_equipment = $2
			AND r.target IS NOT NULL AND r.target_customized = true
			ORDER BY r.ts_value DESC`,
		params: []dsParam{pEnt, pEquip},
	},
	"custom-target-week": {
		group: "settings", doc: "Customized weekly targets per equipment (equipment_runtime_1week)",
		sql: `SELECT r.ts_value, r.target, e.nm_equipment
			FROM equipment_runtime_1week r JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND e.id_equipment = $2
			AND r.target IS NOT NULL AND r.target_customized = true
			ORDER BY r.ts_value DESC`,
		params: []dsParam{pEnt, pEquip},
	},
	"custom-target-day": {
		group: "settings", doc: "Customized daily targets per equipment (equipment_runtime_1day)",
		sql: `SELECT r.ts_value, r.target, e.nm_equipment
			FROM equipment_runtime_1day r JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND e.id_equipment = $2
			AND r.target IS NOT NULL AND r.target_customized = true
			ORDER BY r.ts_value DESC`,
		params: []dsParam{pEnt, pEquip},
	},

	// ── overview-detail extras (OverviewV6 side reads) ───────────────────
	// site-by-equipment: OverviewV6's AREA_NAME query reads the `sites` table
	// for the site that CONTAINS a given equipment (Hasura nested filter
	// sites.Areas.Equipments.id_equipment). equipments carries id_site
	// denormalized, so an EXISTS on equipments scopes both the ownership
	// ($2 in the caller's tenant) and the site linkage. Projects the exact
	// seven columns AREA_NAME selects.
	"site-by-equipment": {
		group: "overview-detail", doc: "Site metadata for an equipment (sites, OverviewV6 AREA_NAME)",
		sql: `SELECT s.id_enterprise, s.nm_site, s.day_begin, s.week_begin, s.week_size, s.timezone, s.language_tag
			FROM sites s WHERE s.id_enterprise = $1
			AND EXISTS (SELECT 1 FROM equipments e WHERE e.id_site = s.id_site AND e.id_equipment = $2)`,
		params: []dsParam{pEnt, pEquip},
	},

	// ── tenant-custom (client-shaped reads; NOT general-purpose datasets) ────
	// These carry a client-specific projection/shape and are grouped apart so it
	// is visible they are bespoke. They are still first-class tenant-safe datasets:
	// $1 is the injected customer_id, every hardcoded client id from back4 is
	// removed and replaced by a $1-fenced filter (the "no hardcoded ids" rule).

	// suzano-analogs (task #54, ADR-0031 §2b-2 — was back4 GET /analogs/{id} +
	// /api/admin/analogs/{id}, SuzanoTagsDAO.getCurrentByMonth). back4 HARDCODED
	// `id_equipment IN (404,411)` — a Suzano-specific literal set. Per the "no
	// hardcoded ids" directive that literal does NOT move into refdata: it becomes
	// a tenant-fenced equipments id-filter (cardinality 0 ⇒ all my equipment), and
	// the enterprise self-scopes to $1. The Suzano-shaped `analogs->'DATA'` PPM
	// projection, the `analogs->'DATA' @> '[{"type":"PPM"}]'` predicate (the
	// containment is on the DATA sub-object, exactly as back4 wrote it — NOT on the
	// bare analogs blob), and the America/Sao_Paulo lower-bound window are all
	// preserved. The `from` instant is bound via pDate ($3::timestamp). Not windowed;
	// the shared row cap replaces back4's LIMIT 300.
	"suzano-analogs": {
		group: "tenant-custom", doc: "Analog PPM readings from equipment_values (Suzano scrap report; analogs->'DATA')",
		sql: `SELECT analogs->'DATA' AS data, ts_value, id_equipment, id_enterprise, id_site, id_area
			FROM equipment_values
			WHERE id_enterprise = $1
			AND (cardinality($2::int[]) = 0 OR id_equipment = ANY($2::int[]))
			AND ts_value >= date_trunc('minute', $3::timestamp) AT TIME ZONE 'America/Sao_Paulo'
			AND analogs->'DATA' @> '[{"type": "PPM"}]'
			AND analogs IS NOT NULL
			ORDER BY ts_value ASC`,
		params: []dsParam{pEnt, ids("equipments"), pDate("from")},
	},

	// report-downtimes (task #54, ADR-0031 §2b-3 — was back4 GET /reportDowntimes/{datetime},
	// get-report-downtimes.service.js → reportDAO.getDowntimes).
	//
	// BACKING OBJECT: the back4 read is NOT a view/fn — it is an inline 6-relation
	// join over a `(equipment_events UNION ALL equipment_events_man)` derived table,
	// with a HARDCODED `id_enterprise = 37` (Suzano) and no clean single relation.
	// That shape is (a) un-fenceable by a single WHERE and (b) unclassifiable by the
	// fail-loud contract-drift parser (contract.go), which models a dataset as one
	// primary relation/function + guard relations. The correct fix — matching how
	// ADR-0031 handles frozen external reads (named `v_*` views) — is a dedicated
	// tenant-CARRYING view `v_report_downtimes` that encapsulates the UNION + joins
	// and EXPOSES id_enterprise + ts_value so refdata can fence on them. The dba owns
	// creating that view (DDL handed off with this change); the pre-prod-flip
	// contract-drift GATE (scripts/refdata-contract-drift-check.sh) will BLOCK the
	// flip — fail-closed — until the view exists in prod, so this never serves a
	// missing object silently. The hardcoded 37 is gone: the tenant is $1, the hour
	// bucket is bound via pDate ($2::timestamp). Not windowed (a single hour point).
	"report-downtimes": {
		group: "tenant-custom", doc: "Downtime report rows for one hour bucket (v_report_downtimes; dba-owned view, see report-downtimes note)",
		sql: `SELECT op, linha, turno, inicio, fim, duracao, maquina,
			codigo_categoria, codigo_subcategoria, descricao_categoria, descricao_subcategoria, anotacao
			FROM v_report_downtimes
			WHERE id_enterprise = $1 AND ts_value = date_trunc('hour', $2::timestamp)
			ORDER BY inicio DESC`,
		params: []dsParam{pEnt, pDate("datetime")},
	},
}

// ── Compile ──────────────────────────────────────────────────────────

type dsWindow struct {
	From time.Time `json:"from"`
	To   time.Time `json:"to"`
}

type datasetReq struct {
	Dataset string                     `json:"dataset"`
	Window  *dsWindow                  `json:"window"`
	Filters map[string]json.RawMessage `json:"filters"`
}

// compileDataset validates a dataset request against the registry and
// produces SQL + args. customerID (→ $1) and, for the per-user-role datasets,
// the caller's role (→ $2) both come from auth (server-derived), never the
// body. role.present=false makes any pUserRole dataset fail closed.
func compileDataset(q datasetReq, customerID int, role callerRole) (string, []any, error) {
	ds, ok := datasets[q.Dataset]
	if !ok {
		return "", nil, fmt.Errorf("unknown dataset %q", q.Dataset)
	}
	if ds.windowed {
		if q.Window == nil || q.Window.From.IsZero() || q.Window.To.IsZero() || !q.Window.To.After(q.Window.From) {
			return "", nil, fmt.Errorf("dataset %q requires window {from,to} with to > from", q.Dataset)
		}
		if q.Window.To.Sub(q.Window.From) > ds.maxWindow {
			return "", nil, fmt.Errorf("window exceeds %s budget for dataset %q", ds.maxWindow, q.Dataset)
		}
	} else if q.Window != nil {
		return "", nil, fmt.Errorf("dataset %q does not take a window", q.Dataset)
	}
	allowed := map[string]bool{}
	for _, p := range ds.params {
		if p.name != "" {
			allowed[p.name] = true
		}
	}
	for k := range q.Filters {
		if !allowed[k] {
			return "", nil, fmt.Errorf("dataset %q does not accept filter %q", q.Dataset, k)
		}
	}
	args := make([]any, 0, len(ds.params))
	for _, p := range ds.params {
		switch p.kind {
		case pEnterprise:
			args = append(args, customerID)
		case pUserRole:
			// Server-derived from the verified Firebase uid, NEVER from the
			// body. Absent (X-Api-Key path, or a role-less user) ⇒ fail closed
			// so an unscoped tenant-wide role list can never be emitted.
			if !role.present {
				return "", nil, errRoleDatasetNeedsUser
			}
			args = append(args, role.id)
		case pFrom:
			args = append(args, q.Window.From)
		case pTo:
			args = append(args, q.Window.To)
		case pIDList:
			v, err := intList(q.Filters, p.name)
			if err != nil {
				return "", nil, err
			}
			args = append(args, pgIntArray(v))
		case pEquipmentID:
			raw, ok := q.Filters[p.name]
			if !ok {
				return "", nil, fmt.Errorf("dataset %q requires filter %q (a single equipment id)", q.Dataset, p.name)
			}
			var id int
			if err := json.Unmarshal(raw, &id); err != nil {
				return "", nil, fmt.Errorf("filter %q must be a single integer id", p.name)
			}
			args = append(args, id)
		case pEnum:
			val := p.enum[0]
			if raw, ok := q.Filters[p.name]; ok {
				var s string
				if err := json.Unmarshal(raw, &s); err != nil {
					return "", nil, fmt.Errorf("filter %q must be a string", p.name)
				}
				s = strings.ToLower(s)
				if !slices.Contains(p.enum, s) {
					return "", nil, fmt.Errorf("filter %q must be one of %s", p.name, strings.Join(p.enum, "|"))
				}
				val = s
			}
			args = append(args, strings.ToUpper(val))
		case pBool:
			b := false
			if raw, ok := q.Filters[p.name]; ok {
				if err := json.Unmarshal(raw, &b); err != nil {
					return "", nil, fmt.Errorf("filter %q must be a boolean", p.name)
				}
			}
			args = append(args, b)
		case pDateScalar:
			// A required client filter, validated + bound as a time.Time (never
			// interpolated). The dataset's ::date/::timestamp cast decides how the
			// bound value is truncated. It is NOT the tenant axis — $1 stays the
			// injected customerID regardless of this filter.
			raw, ok := q.Filters[p.name]
			if !ok {
				return "", nil, fmt.Errorf("dataset %q requires filter %q (a date YYYY-MM-DD or datetime)", q.Dataset, p.name)
			}
			var s string
			if err := json.Unmarshal(raw, &s); err != nil {
				return "", nil, fmt.Errorf("filter %q must be a date/datetime string", p.name)
			}
			t, err := parseDateFilter(s)
			if err != nil {
				return "", nil, fmt.Errorf("filter %q: %w", p.name, err)
			}
			args = append(args, t)
		case pShiftFiltered:
			v, err := intList(q.Filters, "shifts")
			if err != nil {
				return "", nil, err
			}
			args = append(args, len(v) > 0)
		case pTeamFiltered:
			v, err := intList(q.Filters, "teams")
			if err != nil {
				return "", nil, err
			}
			args = append(args, len(v) > 0)
		}
	}
	return ds.sql + fmt.Sprintf(" LIMIT %d", queryRowLimit), args, nil
}

// parseDateFilter validates a pDate value against a fixed layout allowlist and
// returns it as a time.Time (bound positionally, never string-interpolated). It
// accepts a bare date, a space-separated datetime, or RFC3339 so a single
// pDate kind serves both the month/day scalars (oee-by-month, suzano-analogs)
// and the datetime bucket (report-downtimes). A value outside the allowlist is
// rejected — the filter can never carry arbitrary SQL text.
func parseDateFilter(s string) (time.Time, error) {
	for _, layout := range []string{"2006-01-02", "2006-01-02 15:04:05", time.RFC3339} {
		if t, err := time.Parse(layout, s); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("must be YYYY-MM-DD, 'YYYY-MM-DD HH:MM:SS', or RFC3339")
}

func intList(filters map[string]json.RawMessage, name string) ([]int, error) {
	raw, ok := filters[name]
	if !ok {
		return nil, nil
	}
	var v []int
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, fmt.Errorf("filter %q must be an array of integer ids", name)
	}
	return v, nil
}

// pgIntArray renders []int as a postgres array literal — the id-list
// wire format the h_piot_* functions ::int[]-cast internally.
func pgIntArray(v []int) string {
	if len(v) == 0 {
		return "{}"
	}
	parts := make([]string, len(v))
	for i, n := range v {
		parts[i] = strconv.Itoa(n)
	}
	return "{" + strings.Join(parts, ",") + "}"
}

// datasetCatalog renders the registry for GET /v1/catalog.
func datasetCatalog() map[string]any {
	out := make(map[string]any, len(datasets))
	for name, ds := range datasets {
		filters := map[string]string{}
		requiresUser := false
		for _, p := range ds.params {
			switch p.kind {
			case pIDList:
				filters[p.name] = "ids"
			case pEquipmentID:
				filters[p.name] = "id (required)"
			case pEnum:
				filters[p.name] = "enum: " + strings.Join(p.enum, "|") + " (default " + p.enum[0] + ")"
			case pBool:
				filters[p.name] = "bool (default false)"
			case pDateScalar:
				filters[p.name] = "date YYYY-MM-DD or datetime (required)"
			case pUserRole:
				// Not a client filter — flag it so callers know this dataset is
				// front4-JWT-only (server-derived id_user_role; 403 via X-Api-Key).
				requiresUser = true
			}
		}
		entry := map[string]any{
			"group": ds.group, "description": ds.doc,
			"windowed": ds.windowed, "filters": filters,
		}
		if requiresUser {
			entry["requires_user_context"] = true
		}
		if ds.windowed {
			entry["max_window"] = ds.maxWindow.String()
		}
		out[name] = entry
	}
	return out
}
