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
	// sqlF3 (ADR-0032 Step 1, optional) overrides sql when the process read-plane
	// flow is f3 (REFDATA_FLOW=f3). Empty ⇒ the same sql serves both flows, which
	// is EVERY dataset today: packiot_shadow keeps packiot's object names where
	// the object exists, so no dataset needs a textual rewrite (flow.go). The
	// field is the pre-wired seam for a genuine F3 rename; the parameter order and
	// row-cap append are identical for both variants (compileDataset uses
	// activeSQL), so an sqlF3 must bind the SAME $N positions as sql.
	sqlF3 string
	// cacheTTL (ADR-0035, optional) is the cache-aside TTL for this dataset. It
	// trades freshness for DB-load relief: a client re-polling within the window
	// is served from Redis instead of re-hitting the SQL. A per-dataset override
	// (> 0) wins; 0 (the zero value, i.e. unset on almost every literal) falls
	// back to the dataset's GROUP default (cacheTTLForGroup). A NEGATIVE value is
	// the explicit opt-out sentinel → never cache (resolves to 0 in cacheTTL()).
	// The value is chosen to match the backing data's own update cadence:
	// reference/config datasets tolerate minutes; live OEE snapshots get seconds
	// so operators still see fresh numbers. See cacheTTLForGroup.
	cacheTTL time.Duration
}

// activeSQL returns the dataset's SQL for the given flow: the f3 override when
// flow==f3 and one is set, else the F1 sql. The row cap is appended by the
// caller (compileDataset) AFTER this choice, so both variants share it.
func (d dataset) activeSQL(f flow) string {
	if f == flowF3 && d.sqlF3 != "" {
		return d.sqlF3
	}
	return d.sql
}

// ── Cache-aside TTLs (ADR-0035) ──────────────────────────────────────────────
//
// TTL is set per GROUP, not per dataset, so the ~50 dataset literals stay
// untouched (their `group` already classifies them) and the freshness policy is
// one readable table. The split is by the backing data's update cadence:
//
//   - REFERENCE / CONFIG groups (enterprise settings, users, roles, per-role
//     entity/menu trees, targets, custom targets, settings) change on a CS
//     onboarding or a manual edit — MINUTES-stale is fine, so a LONG TTL lets a
//     re-polling dashboard skip the DB almost entirely.
//   - LIVE groups (uns_* snapshots, OEE scores, mission control, overview
//     detail, downtimes/events, production flow/speed) track the 1-min cagg
//     cascade — a SHORT TTL (~the cagg cadence) keeps the operator's numbers
//     fresh while still collapsing a burst of same-tick polls to one DB hit.
//
// A group absent from the map falls back to defaultCacheTTL (conservative short).
const defaultCacheTTL = 20 * time.Second

var groupCacheTTL = map[string]time.Duration{
	// reference / config — LONG (slow-moving, edited by CS / operators, not by the
	// telemetry pipeline):
	"enterprise-config": 300 * time.Second, // enterprises / users / user_roles
	"variables-context": 180 * time.Second, // per-role entity + menu bootstrap trees
	"settings":          300 * time.Second, // downtime-reason config, etc.
	"targets":           300 * time.Second, // production/scrap/oee target config
	"tenant-custom":     300 * time.Second, // manually-overridden custom targets

	// live — SHORT (driven by the 1-min cagg cascade; keep operator numbers fresh):
	"live-uns-equipment":  15 * time.Second, // uns_equipment_current_* snapshots
	"oee":                 30 * time.Second,
	"mission-control":     20 * time.Second,
	"overview-detail":     20 * time.Second,
	"downtimes-analytics": 30 * time.Second,
	"events-timeline":     20 * time.Second,
	"single-period":       30 * time.Second,
	"total-production":    30 * time.Second,
	"production-flow":     30 * time.Second,
	"machine-speed":       20 * time.Second,
	"home":                30 * time.Second,
	"production-orders":   20 * time.Second, // PO list/details flip on operator start/stop → keep short
}

// cacheTTL resolves the effective cache-aside TTL for this dataset: an explicit
// positive per-dataset override wins; a negative override opts out (0 ⇒ bypass);
// otherwise the group default; otherwise the conservative short default.
func (d dataset) cacheTTLResolved() time.Duration {
	if d.cacheTTL > 0 {
		return d.cacheTTL
	}
	if d.cacheTTL < 0 {
		return 0 // explicit opt-out sentinel
	}
	if t, ok := groupCacheTTL[d.group]; ok {
		return t
	}
	return defaultCacheTTL
}

// datasetCacheTTL returns the cache-aside TTL for a named dataset, or 0 (bypass)
// for an unknown dataset. The query handler uses it to size the cache-aside
// wrapper WITHOUT re-plumbing compileDataset's signature (kept stable for its
// many callers/tests).
func datasetCacheTTL(name string) time.Duration {
	ds, ok := datasets[name]
	if !ok {
		return 0
	}
	return ds.cacheTTLResolved()
}

// perEquipment wraps an idequipment-only overview function in the
// tenancy guard: $1 = enterprise (injected), $2 = equipment (client).
func perEquipment(group, doc, fn string) dataset {
	return dataset{
		group: group, doc: doc,
		sql: `SELECT f.* FROM ` + fn + `($2) f WHERE EXISTS
			(SELECT 1 FROM equipments e WHERE e.id_equipment = $2 AND e.id_enterprise = $1 AND e.active)`,
		params: []dsParam{pEnt, pEquip},
	}
}

// liveUNS scopes a per-equipment uns_equipment_current_* snapshot table
// (no id_enterprise column of its own) through the equipments hierarchy.
func liveUNS(doc, table string) dataset {
	return dataset{
		group: "live-uns-equipment", doc: doc,
		sql: `SELECT t.* FROM ` + table + ` t JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND e.active AND (cardinality($2::int[]) = 0 OR t.id_equipment = ANY($2::int[]))`,
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
			WHERE e.id_enterprise = $1 AND e.id_equipment = $2 AND e.active
			AND date_trunc('month', r.ts_value) = date_trunc('month', $3::date)
			AND r.cd_shift IS NOT NULL
			GROUP BY r.cd_shift ORDER BY r.cd_shift`,
		params: []dsParam{pEnt, pEquip, pDate("month")},
	},

	// ── data-quality (north-star P11 andon pillar, Tier-0) ───────────
	// data-quality-events: the alarm feed. Surfaces the data_quality_event rows the
	// rollup DETECTOR records (OEE_GT_1, NET_GT_GROSS, NEGATIVE_METRIC,
	// IDEAL_SPEED_NULL_WHILE_PRODUCING) so silent OEE corruption becomes VISIBLE on
	// the read plane. Tenant-fenced DIRECTLY on id_enterprise (the table carries it
	// natively, like production_targets / oee_targets — no equipments JOIN, so no
	// `active` predicate applies), most-recent-first. Explicit projection (ADR-0027
	// rule #2). Not windowed — the compile row cap (LIMIT 10000) bounds it and the
	// andon panel wants the freshest violations. The backing table is a NEW staging
	// object (edge-node-red migration 34, applied to BOTH packiot + packiot_shadow);
	// the pre-flip drift gate will CORRECTLY flag it MISSING on prod until that
	// migration rolls forward there as part of the P11 rollout.
	"data-quality-events": {
		group: "data-quality", doc: "Data-quality alarm feed — recorded OEE/runtime violations, most-recent-first (data_quality_event)",
		sql: `SELECT id, id_enterprise, id_equipment, grain, bucket_ts, rule, observed_value, severity, detected_at
			FROM data_quality_event WHERE id_enterprise = $1 ORDER BY detected_at DESC`,
		params: []dsParam{pEnt},
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

	// current-shift (ADR-0032 Wave-D — front4 neopacStats CURRENT_SHIFT, the last
	// non-fork Hasura read in lib/dashboard/hooks/neopacStats.js). The Neopac stats
	// card reads the current-shift snapshot AND the nested `equipment { tp_equipment }`
	// for #80's tp-aware "where you should be now" target arrow. `live-equipment-shift`
	// (liveUNS, SELECT t.*) already serves the SCALAR shift columns, but it joins
	// equipments ONLY for the tenant fence and does NOT project tp_equipment — so it
	// cannot serve the nested equipment leg, and neopacStats stayed pinned to Hasura.
	// This minimal per-equipment dataset closes it: same ownership shape as the
	// perEquipment group ($1 = tenant fence via equipments.id_enterprise, $2 = the
	// equipment), an EXPLICIT projection (ADR-0027) of exactly the seven shift columns
	// neopacStats reads PLUS e.tp_equipment (the front4 adapter re-nests it under
	// `equipment{tp_equipment}`, frozen-skin parity). All seven uns_equipment_current_shift
	// columns AND equipments.tp_equipment are column-parity verified in BOTH packiot
	// (F1) and packiot_shadow (F3) (2026-07-22 census) — both backing objects are
	// already SERVABLE_BOTH, so NO F3 migration is needed. Not windowed (a live
	// snapshot). Distinct from live-equipment-shift by the +tp_equipment projection
	// and the single-equipment ($2) axis (neopacStats fires one line id, matching its
	// sibling overview-takt / overview-scrap-rate legs).
	"current-shift": {
		group: "live-uns-equipment", doc: "Current-shift snapshot for one equipment with tp_equipment (uns_equipment_current_shift + equipments, front4 neopacStats CURRENT_SHIFT)",
		sql: `SELECT t.net_production, t.gross_production, t.scrap, t.elapsed_time, t.target,
			t.duration, t.proportional_target, t.id_equipment, e.tp_equipment
			FROM uns_equipment_current_shift t JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND t.id_equipment = $2 AND e.active`,
		params: []dsParam{pEnt, pEquip},
	},

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
	// overview-production-chart-base (ADR-0032 §5.1 — front4 PR #202 gap #2).
	// front4's productionChart hook + every Overview* fork call the BARE
	// `h_piot_overview_production_chart(idequipment)` (lib/dashboard/hooks/
	// productionChart.js:38, Overview*/queries.js), NOT the _v6 / _i_ variants
	// refdata already binds — so those two datasets are a version MISMATCH for
	// the read front4 actually issues. Live census 2026-07-21 confirmed the bare
	// fn EXISTS in BOTH packiot and packiot_shadow (idequipment integer) — file-19
	// replay materialized it in F3 — so this is a true version-match, not a new
	// object. Same perEquipment ownership shape as its siblings.
	"overview-production-chart-base": perEquipment("overview-detail",
		"Overview production chart, base generation (h_piot_overview_production_chart)", "h_piot_overview_production_chart"),
	// equipment-info (ADR-0032 §5.1 — front4 PR #202 gap #4, machineStatus).
	// front4's machineStatus composite (lib/dashboard/hooks/machineStatus.js) and
	// neopacStats read the `equipments` row for one line — nm_equipment (the V3
	// status card's title) and tp_equipment. The other two legs of machineStatus
	// (uns_equipment_current_job.speed, h_piot_overview_i_get_events_3.colorcolumn)
	// are ALREADY served by `live-equipment-job` + `overview-events`; this closes
	// the third leg. A dedicated per-equipment metadata read: enterprise fence at
	// $1 (equipments carries id_enterprise), the equipment id at $2 — same shape
	// as `site-by-equipment`. Relevant to CPACK ent 3 + Incoplast ent 4.
	"equipment-info": {
		group: "overview-detail", doc: "Equipment metadata for one line (equipments, front4 machineStatus/neopacStats)",
		sql: `SELECT id_equipment, nm_equipment, tp_equipment, id_enterprise, id_site, id_area
			FROM equipments WHERE id_enterprise = $1 AND id_equipment = $2 AND active`,
		params: []dsParam{pEnt, pEquip},
	},
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

	// per-equipment targets (ADR-0032 §5.1 — front4 PR #202 gap #3). front4's
	// GET_TARGET / OEE_OBJ_MONTH (Overview/queries.js, familyB.js) filter the
	// three target tables by a SINGLE id_equipment; the enterprise-wide
	// production-targets/scrap-targets/oee-targets datasets above return EVERY
	// equipment's row, so the front4 refdata adapter (one dataset → one GraphQL
	// root field, single-re-nest) cannot narrow to the one line the Overview card
	// renders. These add the id_equipment axis. All three tables carry
	// id_enterprise natively, so the tenant fence is a DIRECT `id_enterprise = $1`
	// (no EXISTS wrapper needed — a foreign-tenant equipment id simply matches
	// zero rows); id_equipment = $2 is the client filter. Backing tables verified
	// present + column-parity in BOTH packiot and packiot_shadow (2026-07-21).
	// Explicit projections (ADR-0027) covering exactly the vl_* columns front4
	// reads (oee_targets has no vl_hour).
	"production-targets-by-equipment": {
		group: "targets", doc: "Configured production targets for one equipment (production_targets, front4 GET_TARGET)",
		sql: `SELECT id_enterprise, id_equipment, id_area, id_site, vl_day, vl_hour, vl_month, vl_week, vl_shift
			FROM production_targets WHERE id_enterprise = $1 AND id_equipment = $2`,
		params: []dsParam{pEnt, pEquip},
	},
	"scrap-targets-by-equipment": {
		group: "targets", doc: "Configured scrap targets for one equipment (scrap_targets, front4 GET_TARGET)",
		sql: `SELECT id_enterprise, id_equipment, id_area, id_site, vl_day, vl_hour, vl_month, vl_week, vl_shift
			FROM scrap_targets WHERE id_enterprise = $1 AND id_equipment = $2`,
		params: []dsParam{pEnt, pEquip},
	},
	"oee-targets-by-equipment": {
		group: "targets", doc: "Configured OEE targets for one equipment (oee_targets, front4 OEE_OBJ_MONTH)",
		sql: `SELECT id_enterprise, id_equipment, id_area, id_site, vl_day, vl_month, vl_week, vl_shift
			FROM oee_targets WHERE id_enterprise = $1 AND id_equipment = $2`,
		params: []dsParam{pEnt, pEquip},
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

	// production-orders-by-equipment (ADR-0032 §5.1 — front4 PR #202 gap #1).
	// front4's previousJob (lib/dashboard/hooks/previousJob.js), the
	// ProductionOrders list, and the EventsTab GET_JOBS read the RAW
	// `production_orders` table directly (not a windowed runtime view/fn): the
	// fork's query is `limit 2, where id_equipment = $eq, order by ts_end
	// desc_nulls_last`, then reads `[0]` (the most-recently-ended order = the
	// "previous" one; the RUNNING order has ts_end=NULL → sorts last). The two
	// runtime-view datasets above (h_piot_production_orders_*) are windowed OEE
	// aggregates, a different shape.
	//
	// BOUNDING (constraint: no unbounded table scan): the read is fenced to ONE
	// equipment (pEquip, $2) within ONE tenant (po.id_enterprise = $1, direct —
	// production_orders carries id_enterprise, so a foreign-tenant equipment id
	// matches zero rows). That equipment fence + the shared row cap make this a
	// bounded read, NOT a table scan; ordering ts_end DESC NULLS LAST returns
	// newest-first so front4's `[0]` previous-order and any recent-orders list are
	// served under the cap. Not windowed (previousJob passes no time window).
	//
	// SHAPE: front4 reads a nested `product { nm_product }` / `client { nm_client }`;
	// like `site-by-equipment` flattens `equipment { nm_equipment }`, we LEFT JOIN
	// products/clients and project the names as flat nm_product/nm_client columns
	// (the adapter re-nests). All three relations verified present + column-parity
	// in BOTH packiot and packiot_shadow (2026-07-21). CPACK ent 3 has PO data
	// (275 rows in F3); relevant to ent 3 (Incoplast ent 4 has no POs yet).
	//
	// EXTENDED (ADR-0032 §5.1 — front4 job-selector surfaces): the two front4 job
	// pickers read `production_orders` directly for a job list, not the previousJob
	// [0] read. EventsTab GET_JOBS (src/components/EventsTab/queries.js) filters
	// `id_equipment = $line AND status != 1` and projects {id_order,
	// id_production_order}. ProductionOrders ModalEdit GET_JOB_LIST
	// (src/pages/ProductionOrders/queries.js) filters `status IN (1,4) AND
	// equipment.nm_equipment = $nm_equipment` and projects {id_order,
	// id_production_order, nm_product, status, nm_client, ts_start, ts_end}. Both
	// need two columns this projection lacked: `id_production_order` (the true PO
	// surrogate PK — id_order is a per-equipment sequence, NOT globally unique) and
	// `status` (PO lifecycle 1=available/2=running/3=finished/4=paused). Both are
	// column-parity verified in F1 AND F3 (id_production_order bigint, status int;
	// 2026-07-21). Added below.
	//
	// FILTER AXIS (deliberately unchanged): the dataset stays fenced to ONE
	// equipment by id_equipment ($2) — that fence is the bounding invariant, so we
	// do NOT add an nm_equipment filter (it would force a name→id join and risk a
	// wider scan). GET_JOB_LIST's `nm_equipment` axis is served by front4 resolving
	// nm_equipment → id_equipment (it already holds that mapping from the equipment
	// list / site-by-equipment datasets) and calling this dataset by id_equipment.
	// The `status` predicates (!=1 for GET_JOBS, IN(1,4) for GET_JOB_LIST) are
	// applied CLIENT-SIDE by front4 over the now-exposed `status` column — the
	// per-equipment row set is already bounded, so no server-side status filter is
	// warranted. Net: +2 projected columns, zero new filters, fence + cap intact.
	//
	// EXTENDED AGAIN (ADR-0032 Wave-D — front4 familyB GET_JOB_INFO, the last
	// non-fork Hasura read in lib/dashboard/hooks/familyB.js). GET_JOB_INFO bundles
	// three Hasura root fields; two already have datasets (overview-job-info,
	// equipment-info), and its third leg reads the RUNNING order (`production_orders
	// where id_equipment=$id AND status=2`) selecting `product{cd_product,
	// txt_product,nm_product}`, `id_order_text`, and `txt_production_order_description`
	// (the elpes JobStatusPanel's order title + product name). This projection had
	// nm_product (added by the PR #540 column-extend) but LACKED the other four —
	// so familyB stayed pinned to Hasura. Mirroring #540, we add them: the two
	// `production_orders` columns (txt_production_order_description, id_order_text)
	// and the two remaining `products` columns (cd_product, txt_product) off the
	// existing LEFT JOIN products. All four are column-parity verified in BOTH
	// packiot (F1) and packiot_shadow (F3) (2026-07-22 census) — no F3 migration.
	// The status=2 (running) predicate stays CLIENT-SIDE, exactly like GET_JOBS /
	// GET_JOB_LIST above (the `status` column is already projected); the per-equipment
	// fence + row cap are unchanged. Net: +4 projected columns, zero new filters.
	"production-orders-by-equipment": {
		group: "production-orders", doc: "Raw production orders for one equipment, newest-first (production_orders + product/client names, front4 previousJob + job-selectors + familyB GET_JOB_INFO)",
		sql: `SELECT po.id_order, po.id_production_order, po.id_order_text, po.status, po.production_programmed, po.net_production, po.ts_start, po.ts_end, po.id_equipment, po.txt_production_order_description, pr.nm_product, pr.cd_product, pr.txt_product, cl.nm_client
			FROM production_orders po
			LEFT JOIN products pr ON pr.id_product = po.id_product
			LEFT JOIN clients cl ON cl.id_client = po.id_client
			WHERE po.id_enterprise = $1 AND po.id_equipment = $2
			ORDER BY po.ts_end DESC NULLS LAST`,
		params: []dsParam{pEnt, pEquip},
	},

	// ── enterprise-config ────────────────────────────────────────────
	// Explicit projections: enterprises minus api_key (the tenancy
	// secret must never transit this API), users minus operator_pw_hash
	// and id_user_firebase (credentials / auth-provider internals).
	"enterprise-config": {
		group: "enterprise-config", doc: "Enterprise settings (enterprises minus api_key)",
		sql: `SELECT id_enterprise, nm_enterprise, week_begin, day_begin, week_size, timezone,
			logo_url, active, basic_menu, custom_menu, language_packs, scrap_calc_type
			FROM enterprises WHERE id_enterprise = $1 AND active IS NOT FALSE`,
		params: []dsParam{pEnt},
	},
	"users": {
		group: "enterprise-config", doc: "Enterprise users (minus credential columns)",
		sql: `SELECT id_user, user_email, user_name, id_enterprise, phone_number, user_roles,
			timezone, languages, user_menu, internal_user, active
			FROM users WHERE id_enterprise = $1 AND active IS NOT FALSE`,
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
			WHERE id_enterprise = $1 AND id_equipment = $2 AND active`,
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
			WHERE e.id_enterprise = $1 AND e.id_equipment = $2 AND e.active
			AND r.target IS NOT NULL AND r.target_customized = true
			ORDER BY r.ts_value DESC`,
		params: []dsParam{pEnt, pEquip},
	},
	"custom-target-week": {
		group: "settings", doc: "Customized weekly targets per equipment (equipment_runtime_1week)",
		sql: `SELECT r.ts_value, r.target, e.nm_equipment
			FROM equipment_runtime_1week r JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND e.id_equipment = $2 AND e.active
			AND r.target IS NOT NULL AND r.target_customized = true
			ORDER BY r.ts_value DESC`,
		params: []dsParam{pEnt, pEquip},
	},
	"custom-target-day": {
		group: "settings", doc: "Customized daily targets per equipment (equipment_runtime_1day)",
		sql: `SELECT r.ts_value, r.target, e.nm_equipment
			FROM equipment_runtime_1day r JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND e.id_equipment = $2 AND e.active
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
			FROM sites s WHERE s.id_enterprise = $1 AND s.active
			AND EXISTS (SELECT 1 FROM equipments e WHERE e.id_site = s.id_site AND e.id_equipment = $2 AND e.active)`,
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

	// ── front4 Category C (front4 PR #210 §C — net-new datasets) ─────────────
	// The seven reads below are the LAST Hasura-only front4 sites with NO refdata
	// dataset (PR #210 "Category C" table). Wave-B rewires the sites that already
	// have a dataset; these had none, so front4 cannot drop `@apollo/client` until
	// they land. Every one is tenant-fenced (enterprise NEVER from the body — $1 is
	// the injected customer_id) and bounded (per-equipment guard, id-list + window,
	// or a single enterprise scan under the shared row cap). REFDATA_FLOW stays
	// default f1; all backing objects were census-verified present + column-parity
	// in BOTH packiot (F1) and packiot_shadow (F3) on 2026-07-21, except three
	// nullable production_orders columns absent in F3 that 31-f3-front4-cat-c-objects.sql
	// adds (see production-orders-rich note).

	// overview-takt / overview-scrap-rate (C1/C2 — OverviewV5 + lib/dashboard/
	// hooks/neopacStats). front4 reads these two ent-13 ("Neopac") views by a bare
	// `id_equipment = $eq` with NO tenant predicate (Hasura scoped the enterprise by
	// row-permission). The load-bearing rewrite is the FENCE: an EXISTS on equipments
	// binds the caller's tenant ($1) to the equipment ($2), so a foreign-tenant
	// equipment id yields zero rows — same ownership shape as the perEquipment group,
	// but over a VIEW instead of a set-returning function. ⚠️ These are ent-13-SPECIFIC
	// views: on staging (tenants CPACK ent 3 + Incoplast ent 4) they return EMPTY, and
	// in F3 (`packiot_shadow`) they are STUB TABLES (relkind r), not views — the object
	// EXISTS with column-parity, which is what the read needs (front4 needs a non-Hasura
	// path even when the result is empty). Bind anyway.
	"overview-takt": {
		group: "overview-detail", doc: "Per-equipment takt/avg speed (v_13_overview_takt, ent-13 Neopac view; empty off ent 13)",
		sql: `SELECT v.id_equipment, v.avg_speed
			FROM v_13_overview_takt v
			WHERE v.id_equipment = $2
			AND EXISTS (SELECT 1 FROM equipments e WHERE e.id_equipment = $2 AND e.id_enterprise = $1 AND e.active)`,
		params: []dsParam{pEnt, pEquip},
	},
	"overview-scrap-rate": {
		group: "overview-detail", doc: "Per-equipment partial scrap rate (v_13_overview_partial_scrap_rate, ent-13 Neopac view; empty off ent 13)",
		sql: `SELECT v.cd_equipment, v.gross, v.net, v.scrap, v.scrap_rate
			FROM v_13_overview_partial_scrap_rate v
			WHERE v.id_equipment = $2
			AND EXISTS (SELECT 1 FROM equipments e WHERE e.id_equipment = $2 AND e.id_enterprise = $1 AND e.active)`,
		params: []dsParam{pEnt, pEquip},
	},

	// equipments-events-column-flag (C3 — Downtimes/index SHOULD_DISPLAY_EVENT_COLLUMN).
	// front4 issues an `equipments_aggregate` COUNT that gates whether the Downtimes
	// grid shows the events column: the count of the caller's equipment that both have
	// `event_should_be_displayed = true` AND are a machine/sector (tp_equipment IN 1,2).
	// A count>0 flips `isSectorView`. We replicate the exact aggregate predicate,
	// enterprise-fenced at $1. NOTE the projection is count(id_equipment), NOT count(*):
	// the fail-loud contract parser (contract.go) rejects `*` inside an aggregate, so a
	// single-column count is the parseable-yet-equivalent form (every row has a non-null
	// id_equipment PK, so count(id_equipment) == count(*)). Not windowed; one scalar row.
	"equipments-events-column-flag": {
		group: "downtimes-analytics", doc: "Count gating the Downtimes events column (equipments where event_should_be_displayed, tp 1/2)",
		sql: `SELECT count(id_equipment) AS count FROM equipments
			WHERE id_enterprise = $1 AND event_should_be_displayed = true AND tp_equipment IN (1, 2) AND active`,
		params: []dsParam{pEnt},
	},

	// equipments-list (C4 — Settings/ProductionOrders GetEquipmentsPosition,
	// EQUIPMENT_POSITION). front4 lists EVERY machine (tp_equipment = 1) in the
	// enterprise with its physical `position` for the PO-board ordering. Distinct from
	// the single-equipment `equipment-info` dataset (which takes an id at $2): this is
	// an enterprise-WIDE read fenced directly on equipments.id_enterprise = $1 (no
	// per-equipment axis), bounded by the tenant scope + row cap. Projects exactly the
	// four columns front4 reads. Not windowed.
	"equipments-list": {
		group: "settings", doc: "Enterprise-wide machine list with board position (equipments, front4 EQUIPMENT_POSITION)",
		sql: `SELECT id_equipment, cd_equipment, nm_equipment, position
			FROM equipments WHERE id_enterprise = $1 AND tp_equipment = 1 AND active`,
		params: []dsParam{pEnt},
	},

	// production-orders-rich (C5 — Settings/ProductionOrders GET_PRODUCTION_ORDERS).
	// front4's PO admin board reads `production_orders` filtered by a SET of equipment
	// ids AND status = 1 (available), newest-first by ts_creation, with a DEEP nest:
	// client{nm_client}, product{nm_product,cd_product,txt_product,scrap_target,
	// equipment_setup, product_family{...}}, equipment{nm_equipment}, Sites{nm_site},
	// Area{nm_area}. Distinct from `production-orders-by-equipment` (single equipment,
	// flat, all-status): this is MULTI-equipment ($2 = an id-list) + status-fenced +
	// a deeper join set.
	//
	// SHAPE: like the sibling PO dataset, we LEFT JOIN the relations and project the
	// nested names FLAT (nm_client, nm_product, nm_product_family, nm_site, nm_area,
	// …); the front4 refdata adapter re-nests them under the Hasura root-field names
	// (frozen-skin parity). `equipment_setup`/`scrap_target` are SCALAR columns on
	// products (not relations); `product_family` is the `product_families` table
	// (products.id_product_family FK). BOUND + FENCED: po.id_enterprise = $1 (direct —
	// production_orders carries id_enterprise, so a foreign-tenant equipment id in the
	// list simply matches zero rows), the id-list at $2 (cardinality 0 ⇒ zero rows,
	// safe — front4 always passes the board's machine set), status = 1 literal, and the
	// shared row cap. Not windowed (the board is a status snapshot, not a time range).
	//
	// F3 NOTE: production_orders in packiot_shadow (F3) lacks three of the projected
	// columns present in F1 — ideal_production, ts_start_tz, ts_end_tz —
	// so 31-f3-front4-cat-c-objects.sql ADDs them (nullable, IF NOT EXISTS) to keep
	// F1↔F3 object parity at F3_MISSING=0. They are inert under the default f1 flow.
	"production-orders-rich": {
		group: "production-orders", doc: "Available POs for a set of equipment, deep-nested (production_orders + client/product/product_family/equipment/site/area, front4 GET_PRODUCTION_ORDERS)",
		sql: `SELECT po.id_production_order, po.id_order, po.id_order_text, po.id_equipment, po.id_equipment_executed,
			po.id_product, po.id_user_operator, po.status, po.available_time, po.conversion_factor,
			po.gross_production, po.ideal_production, po.ideal_production_speed, po.net_production,
			po.oee, po.oee_availability, po.oee_performance, po.oee_quality, po.planned_downtime,
			po.production_final, po.production_ordered, po.production_programmed, po.production_real,
			po.qt_stops, po.running_time, po.speed, po.stopped_time, po.ts_creation,
			po.ts_start, po.ts_start_tz, po.ts_end, po.ts_end_tz,
			po.txt_production_order_description, po.txt_production_order_notes,
			cl.nm_client,
			pr.nm_product, pr.cd_product, pr.txt_product, pr.scrap_target, pr.equipment_setup,
			pf.nm_product_family, pf.id_product_family,
			eq.nm_equipment,
			s.nm_site,
			a.nm_area
			FROM production_orders po
			LEFT JOIN clients cl ON cl.id_client = po.id_client
			LEFT JOIN products pr ON pr.id_product = po.id_product
			LEFT JOIN product_families pf ON pf.id_product_family = pr.id_product_family
			LEFT JOIN equipments eq ON eq.id_equipment = po.id_equipment
			LEFT JOIN sites s ON s.id_site = po.id_site
			LEFT JOIN areas a ON a.id_area = po.id_area
			WHERE po.id_enterprise = $1 AND (cardinality($2::int[]) = 0 OR po.id_equipment = ANY($2::int[]))
			AND po.status = 1
			ORDER BY po.ts_creation DESC`,
		params: []dsParam{pEnt, ids("equipments")},
	},

	// equipment-runtime-1day (C6 — PdfSuzano EQP_RUNTIME_1DAY; also OverviewV3
	// commented). front4 reads the RAW daily runtime rollup for a SET of equipment
	// over a date range (front4 uses _gte/_lt half-open bounds). equipment_runtime_1day
	// carries NO id_enterprise, so — like custom-target-day / liveUNS — we scope
	// through the equipments hierarchy ($1) and add the equipment id-list ($2). This is
	// DISTINCT from custom-target-day (which filters target_customized = true — a
	// different, sparse row set): this is the raw, unfiltered daily series. The date
	// range is a WINDOW ([from, to)), bound as $3/$4 with `< to` to match front4's _lt;
	// budgeted at analyticsWindow (one row per equipment per day is cheap). The join to
	// equipments supplies nm_equipment (front4's nested equipment{nm_equipment}).
	"equipment-runtime-1day": {
		group: "settings", doc: "Raw daily runtime rollup for a set of equipment over a date range (equipment_runtime_1day, front4 PdfSuzano)",
		sql: `SELECT r.ts_value, r.id_equipment, r.available_time, r.changeover_time, r.downtime, r.gross,
			r.ideal_production, r.idle_blocked, r.idle_starved, r.idle_time, r.net, r.planned_downtime,
			r.proportional_target, r.recalc_needed, r.running_time, r.scrap, r.speed, r.stopped_time,
			r.target, r.target_customized, e.nm_equipment
			FROM equipment_runtime_1day r JOIN equipments e USING (id_equipment)
			WHERE e.id_enterprise = $1 AND e.active
			AND (cardinality($2::int[]) = 0 OR r.id_equipment = ANY($2::int[]))
			AND r.ts_value >= $3 AND r.ts_value < $4`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("equipments"), pWinFrom, pWinTo},
	},

	// shifts (C7 — Context/VariablesContext GET_VARIABLES_CONTEXT #6 `shifts` root
	// field + EntityFilters/Query). VERIFIED genuinely uncovered (2026-07-21): the
	// front4 bootstrap reads a STANDALONE `shifts` root field selecting {cd_shift,
	// id_shift, name_site{nm_site,id_site}, area{id_area,nm_area}} — a shape NEITHER
	// covered by `entities-per-user-role` (whose `shifts` is a scalar jsonb column on
	// the view, no id_shift / nested site+area) NOR by the /v1/shift-hours route (which
	// is packml-topic-keyed via piot_get_shift_hours_by_packml_topic_2 — a per-equipment
	// calendar expansion, not the enterprise's shift-definition list). So this is a
	// real net-new dataset. Enterprise-fenced at $1 on shifts.id_enterprise; the two
	// LEFT JOINs flatten the site/area names the adapter re-nests. Not windowed
	// (a small, static definition list bounded by the tenant + row cap).
	"shifts": {
		group: "variables-context", doc: "Enterprise shift definitions for the bootstrap (shifts + site/area names, front4 GET_VARIABLES_CONTEXT #6)",
		sql: `SELECT sh.id_shift, sh.cd_shift, sh.id_site, s.nm_site, sh.id_area, a.nm_area
			FROM shifts sh
			LEFT JOIN sites s ON s.id_site = sh.id_site
			LEFT JOIN areas a ON a.id_area = sh.id_area
			WHERE sh.id_enterprise = $1`,
		params: []dsParam{pEnt},
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
	return ds.activeSQL(activeFlow) + fmt.Sprintf(" LIMIT %d", queryRowLimit), args, nil
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
