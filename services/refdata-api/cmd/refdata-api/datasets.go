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
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
)

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

var (
	pEnt     = dsParam{kind: pEnterprise}
	pWinFrom = dsParam{kind: pFrom}
	pWinTo   = dsParam{kind: pTo}
	pEquip   = dsParam{kind: pEquipmentID, name: "equipment"}
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
	"oee-score-teams": {
		group: "oee", doc: "OEE score split by shifts/teams (h_piot_oee_score_with_teams)",
		sql:      `SELECT * FROM h_piot_oee_score_with_teams($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
		windowed: true, maxWindow: analyticsWindow,
		params: []dsParam{pEnt, ids("equipments"), ids("areas"), ids("sites"), ids("shifts"),
			ids("teams"), pWinFrom, pWinTo, pGrain, pNav, pShiftF, pTeamF},
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
// produces SQL + args. customerID comes from auth, never the body.
func compileDataset(q datasetReq, customerID int) (string, []any, error) {
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
			}
		}
		entry := map[string]any{
			"group": ds.group, "description": ds.doc,
			"windowed": ds.windowed, "filters": filters,
		}
		if ds.windowed {
			entry["max_window"] = ds.maxWindow.String()
		}
		out[name] = entry
	}
	return out
}
