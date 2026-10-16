package mirror

import "strings"

// Mode is how a table converges.
type Mode int

const (
	// Mirror: insert what production has, update what differs, delete what production no longer has.
	Mirror Mode = iota
	// AppendOnly: insert what production has; never update or delete (the table forbids it, e.g. the
	// box_scans_no_mutate trigger). A staging row that differs is counted as divergent, not touched.
	AppendOnly
)

// Table is one reflected table. Every tenant-keyed table of the analytics DB is either in Reflected (production
// owns it) or in Local (staging computes or owns it); anything else is reported as unclassified (MR5) and NOT
// reflected — a table added later must be decided, never copied or ignored by accident (the tenant_extract.py
// rule of the go-live load).
type Table struct {
	Name string
	Mode Mode
	// TimeCol buckets the table by UTC day; "" = one bucket ("all") unless BucketExpr is set.
	TimeCol string
	// BucketExpr overrides TimeCol (SQL over alias t, must yield text).
	BucketExpr string
	// Hot: hot passes compare only buckets newer than the lookback (TimeCol required); full passes compare all.
	Hot bool
	// SelfRef columns reference the same table (FKs): inserted NULL first, set after every row of the pass exists.
	SelfRef []string
	// Exclude: never read from production, never written on staging (environment-specific values).
	Exclude []string
	// Ignore: copied on insert/update but not compared (a staging trigger rewrites them, e.g. updated_at).
	Ignore []string
	// Project: production-side SQL (alias t) replacing a column's value; {suffix} = Config.NameSuffix literal.
	Project map[string]string
	// Serving: a change here re-resolves serving.downtime_events_resolved over the changed days.
	Serving bool
}

var updatedAt = []string{"updated_at"}

// Reflected — production owns these rows for a mirrored tenant. ORDER = foreign-key order (parents first);
// deletes run in the reverse order.
var Reflected = []Table{
	// hierarchy. api_key stays per environment (staging keeps its key, production rotates its own); the name is
	// production's plus a suffix so a person always sees which environment they are in (ADR-0064 D5).
	{Name: "core.enterprises", Exclude: []string{"api_key"}, Ignore: updatedAt,
		Project: map[string]string{"nm_enterprise": "t.nm_enterprise || {suffix}"}},
	{Name: "core.sites", Ignore: updatedAt},
	{Name: "core.areas", Ignore: updatedAt},
	{Name: "core.equipments", Ignore: updatedAt,
		SelfRef: []string{"id_parentequipment", "lead_machine", "gross_machine", "net_machine", "scrap_machine"}},
	{Name: "core.topic_routing"},
	{Name: "core.device_bindings", Ignore: updatedAt},
	{Name: "core.client_descriptors"},
	{Name: "core.box_production_bridges"},
	// reasons
	{Name: "core.downtime_reason", Ignore: updatedAt, SelfRef: []string{"parent_id"}},
	{Name: "core.scrap_reason", Ignore: updatedAt, SelfRef: []string{"parent_id"}},
	{Name: "core.equipment_downtime_reason", Ignore: updatedAt},
	{Name: "core.equipment_scrap_reason", Ignore: updatedAt},
	// shifts, teams
	{Name: "core.shifts"},
	{Name: "core.shift_hours"},
	{Name: "core.shifts_exception_period"},
	{Name: "core.teams"},
	// products
	{Name: "core.product_families"},
	{Name: "core.products"},
	{Name: "core.clients"},
	// tenant configuration
	{Name: "config.labels"},
	{Name: "config.label_formats"},
	{Name: "config.dashboard_config"},
	{Name: "config.tenant_translations"},
	{Name: "config.equipment_out_of_service"},
	{Name: "config.oee_targets"},
	{Name: "config.production_targets"},
	{Name: "config.scrap_targets"},
	// identity (one shared Cognito pool: a production user logs in to the mirror too, read-only)
	{Name: "identity.user_roles"},
	{Name: "identity.users"},
	// production orders and their runtime (production's PO numbers, not a recomputation)
	{Name: "core.production_orders",
		BucketExpr: "coalesce(to_char(t.ts_creation AT TIME ZONE 'UTC', 'YYYY-MM'), 'none')"},
	{Name: "core.po_number_corrections"},
	{Name: "gold.production_orders_runtime",
		BucketExpr: "coalesce(to_char(lower(t.runtime_timerange) AT TIME ZONE 'UTC', 'YYYY-MM'), 'none')"},
	{Name: "gold.po_box_counter"},
	// downtime events: production's stops and their justifications/splits (staging mints none for a mirror)
	{Name: "silver.equipment_events", TimeCol: "ts_event", Hot: true, Serving: true},
	{Name: "silver.equipment_events_man", TimeCol: "ts_event", Hot: true, Serving: true},
	{Name: "silver.equipment_events_low_speed", TimeCol: "ts_event", Hot: true},
	// box scans and samples
	{Name: "bronze.box_scans", Mode: AppendOnly, TimeCol: "ts_value", Hot: true, SelfRef: []string{"voids_box_scan_id"}},
	{Name: "bronze.sample_boxes", TimeCol: "ts_value", Hot: true},
	{Name: "bronze.scanned_boxes", TimeCol: "ts_value", Hot: true},
	// OEE: production's numbers (staging's engine skips a mirrored tenant, ADR-0064 D4)
	{Name: "gold.equipment_oee_hourly", TimeCol: "ts_value", Hot: true},
	{Name: "gold.equipment_oee_shift", TimeCol: "ts_value", Hot: true},
	{Name: "gold.equipment_oee_daily", TimeCol: "ts_value", Hot: true},
	{Name: "gold.equipment_oee_weekly", TimeCol: "ts_value", Hot: true},
	{Name: "gold.equipment_oee_monthly", TimeCol: "ts_value", Hot: true},
	{Name: "gold.equipment_oee_shift_weekly", TimeCol: "ts_value", Hot: true},
	{Name: "gold.equipment_oee_shift_monthly", TimeCol: "ts_value", Hot: true},
	{Name: "gold.area_oee_daily", TimeCol: "ts_value", Hot: true},
	{Name: "gold.area_oee_shift", TimeCol: "ts_value", Hot: true},
	{Name: "gold.site_oee_shift", TimeCol: "ts_value", Hot: true},
	{Name: "silver.data_quality_event", TimeCol: "detected_at", Hot: true},
	// the per-grain live views the engine's UNS loop writes from gold
	{Name: "silver.equipment_live_day"},
	{Name: "silver.equipment_live_shift"},
	{Name: "silver.equipment_live_job"},
	{Name: "silver.equipment_live_month"},
	{Name: "silver.area_live_day"},
	{Name: "silver.area_live_shift"},
}

// Local — tenant-keyed tables staging keeps for itself, each with the reason. Not reflected.
var Local = map[string]string{
	"bronze.equipment_values_raw":           "staging's own PLC reader (two independent readers, ADR-0064 D4)",
	"bronze.equipment_events_raw":           "staging's own reader (raw replay buffer)",
	"silver.equipment_values":               "staging's own reader: the minute-grain series and the rollback base",
	"silver.plc_link_minutes":               "staging's reader link health (each reader reports its own)",
	"silver.equipment_live_metrics":         "current state derived every minute from staging's own reader",
	"silver.equipment_events_cpac_shadow":   "CPACK shadow-deriver comparison table (enterprise 3)",
	"ops.capture_observations":              "box capture discovery reported by staging's box instance",
	"identity.user_logs":                    "staging's own audit trail (who did what HERE)",
	"identity.user_screen_config":           "per-user layout on this environment (read-api PUT /v1/screen-config)",
	"identity.operator_last_line":           "Operator landing line per user on this environment (PRODT-172, edge-api)",
	"serving.downtime_events_resolved":      "rebuilt on staging from the reflected events (Serving tables)",
	"core.equipment_validation_shift":       "legacy validation table, no key, unused by the new stack",
	"customer_reports.boxes":                "customer export generated by staging jobs; must stay off for a mirror (ADR-0064 §4)",
	"customer_reports.production_data_sync": "customer export (SYNC06), off for a mirror",
	"customer_reports.sap_data_sync":        "customer export (SAP13), off for a mirror",
	"customer_reports.shift":                "customer export (SHIFT06), off for a mirror",
	"ops.data_invariant_result":             "staging's invariant history",
	"ops.sandbox_state":                     "sandbox twin state (staging only)",
	// ADR-0063 plain-PG rollups (replaced the caggs): derived on each side from its OWN silver.equipment_values.
	"silver.agg_equipment_values_1min":   "rollup of staging's own silver.equipment_values (ADR-0063)",
	"silver.agg_equipment_values_1hour":  "rollup of staging's own silver.equipment_values (ADR-0063)",
	"silver.equipment_categorical_1min":  "rollup of staging's own silver.equipment_values (ADR-0063)",
	"silver.equipment_categorical_1hour": "rollup of staging's own silver.equipment_values (ADR-0063)",
	"silver.rollup_invalidation":         "work queue of the local rollups above",
	"silver.equipment_metrics_1min__old": "pre-ADR-0063 copy kept until its scheduled drop",
	"ops.cold_export":                    "this environment's own historian cold-export ledger (ADR-0065)",
	"ops.cold_export_exempt":             "this environment's own cold-export exemptions (ADR-0065)",
}

// staging-only scratch: never classified (ops backups/fixes, temp tables).
func scratch(name string) bool {
	s, n, _ := strings.Cut(name, ".")
	if strings.HasPrefix(s, "pg_temp") || strings.HasPrefix(s, "pg_toast") {
		return true
	}
	return strings.HasPrefix(n, "_") || (s == "ops" && strings.HasPrefix(n, "bf"))
}

// TenantKeys are the columns that make a table tenant-scoped, in the order tenant_extract.py uses.
var TenantKeys = []string{"id_enterprise", "customer_id", "id_equipment", "id_area", "id_site", "id_production_order"}

// TenantFilter is the SQL predicate (alias t) selecting one enterprise's rows through the table's tenant key.
// The subqueries read the side's OWN hierarchy, so it is evaluated identically on production and on staging.
func TenantFilter(key string, ent int) string {
	e := itoa(ent)
	switch key {
	case "id_enterprise":
		return "t.id_enterprise = " + e
	case "customer_id":
		return "t.customer_id = " + e
	case "id_equipment":
		return "t.id_equipment IN (SELECT e.id_equipment FROM core.equipments e WHERE e.id_enterprise = " + e + ")"
	case "id_area":
		return "t.id_area IN (SELECT a.id_area FROM core.areas a WHERE a.id_enterprise = " + e + ")"
	case "id_site":
		return "t.id_site IN (SELECT s.id_site FROM core.sites s WHERE s.id_enterprise = " + e + ")"
	case "id_production_order":
		return "t.id_production_order IN (SELECT p.id_production_order FROM core.production_orders p WHERE p.id_enterprise = " + e + ")"
	}
	return "false"
}

// Unclassified returns the tenant-keyed tables of a catalog that are neither Reflected nor Local.
func Unclassified(cat Catalog) []string {
	known := map[string]bool{}
	for _, t := range Reflected {
		known[t.Name] = true
	}
	for n := range Local {
		known[n] = true
	}
	var out []string
	for name, meta := range cat {
		if known[name] || scratch(name) || meta.TenantKey == "" {
			continue
		}
		out = append(out, name)
	}
	sortStrings(out)
	return out
}
