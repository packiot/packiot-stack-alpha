// query.go — ADR-0015 P1-P3: the customer-facing composable query API.
//
// P1: GET /v1/catalog + POST /v1/query — metrics × dimensions × grain ×
//
//	window compiled to CAgg SQL. The catalog is the ONLY composition
//	surface (allowlist by construction); table layout stays free to
//	move underneath (the SQL map is the indirection).
//
// P2: GET/PUT /v1/screen-config — per-user/screen layout JSON; widgets
//
//	bind to catalog queries, so customization adds zero query power.
//
// P3: X-Api-Key → customer_id tenancy (QUERY_API_KEYS="key:cid,key2:cid").
//
//	customer_id is NEVER client-supplied. Cost caps: window ≤ 90d,
//	grain×window budget, row limit, statement timeout.
//
// P4 (conditional, per ADR): a GraphQL façade would be GENERATED from
//
//	this catalog — not hand-tracked. Not built until demanded.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ── Catalog (P1) ─────────────────────────────────────────────────────

var metrics = map[string]string{
	"net_production":   "sum(net_production_incr)",
	"gross_production": "sum(gross_production_incr)",
	"scrap":            "sum(scrap_incr)",
	"avg_speed":        "avg(speed)",
}

var dimensions = map[string]string{
	"site":      "id_site",
	"area":      "id_area",
	"equipment": "id_equipment",
	"shift":     "id_shift",
}

// grains map to the CAgg families adopted from prod (staging parity work).
var grains = map[string]struct {
	table     string
	maxWindow time.Duration
}{
	"1min":  {"agg_equipment_values_1min", 7 * 24 * time.Hour},
	"10min": {"agg_equipment_values_10min", 30 * 24 * time.Hour},
	"1hour": {"agg_equipment_values_1hour", 90 * 24 * time.Hour},
}

const queryRowLimit = 10000

type queryReq struct {
	Metrics    []string         `json:"metrics"`
	Dimensions []string         `json:"dimensions"`
	Grain      string           `json:"grain"`
	From       time.Time        `json:"from"`
	To         time.Time        `json:"to"`
	Filters    map[string][]int `json:"filters"` // dimension → allowed ids
}

// compile validates a request against the catalog and produces SQL +
// args. customer_id comes from auth, never the body.
func compile(q queryReq, customerID int) (string, []any, error) {
	g, ok := grains[q.Grain]
	if !ok {
		return "", nil, fmt.Errorf("unknown grain %q", q.Grain)
	}
	if len(q.Metrics) == 0 {
		return "", nil, fmt.Errorf("at least one metric required")
	}
	if q.To.IsZero() || q.From.IsZero() || !q.To.After(q.From) {
		return "", nil, fmt.Errorf("invalid window")
	}
	if q.To.Sub(q.From) > g.maxWindow {
		return "", nil, fmt.Errorf("window exceeds %s budget for grain %s", g.maxWindow, q.Grain)
	}
	sel := []string{"ts_value"}
	grp := []string{"ts_value"}
	for _, d := range q.Dimensions {
		col, ok := dimensions[d]
		if !ok {
			return "", nil, fmt.Errorf("unknown dimension %q", d)
		}
		sel = append(sel, col+" AS "+d)
		grp = append(grp, col)
	}
	for _, m := range q.Metrics {
		expr, ok := metrics[m]
		if !ok {
			return "", nil, fmt.Errorf("unknown metric %q", m)
		}
		sel = append(sel, expr+" AS "+m)
	}
	args := []any{customerID, q.From, q.To}
	where := []string{"id_enterprise = $1", "ts_value >= $2", "ts_value < $3"}
	for d, vals := range q.Filters {
		col, ok := dimensions[d]
		if !ok {
			return "", nil, fmt.Errorf("unknown filter dimension %q", d)
		}
		args = append(args, vals)
		where = append(where, fmt.Sprintf("%s = ANY($%d)", col, len(args)))
	}
	sql := fmt.Sprintf("SELECT %s FROM %s WHERE %s GROUP BY %s ORDER BY ts_value LIMIT %d",
		strings.Join(sel, ", "), g.table, strings.Join(where, " AND "),
		strings.Join(grp, ", "), queryRowLimit)
	return sql, args, nil
}

// ── Tenancy (P3) ─────────────────────────────────────────────────────

// parseAPIKeys reads QUERY_API_KEYS ("key:customerID,key2:cid2").
func parseAPIKeys(raw string) map[string]int {
	out := map[string]int{}
	for _, pair := range strings.Split(raw, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(pair), ":")
		if !ok || k == "" {
			continue
		}
		var cid int
		if _, err := fmt.Sscanf(v, "%d", &cid); err == nil {
			out[k] = cid
		}
	}
	return out
}

func registerQueryAPI(mux *http.ServeMux, pool *pgxpool.Pool) {
	// ADR-0027 Surface-1: tenant auth is now whole-mux middleware (auth.go),
	// not a per-handler closure. Handlers read the resolved customer_id from
	// request context (customerIDFromContext) — the middleware guarantees a
	// valid key already resolved before any of these run.

	mux.HandleFunc("/v1/catalog", func(w http.ResponseWriter, r *http.Request) {
		gr := map[string]string{}
		for g, spec := range grains {
			gr[g] = spec.maxWindow.String()
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"metrics": keysOf(metrics), "dimensions": keysOf(dimensions),
			"grains": gr, "row_limit": queryRowLimit,
			"datasets": datasetCatalog(),
		})
	})

	mux.HandleFunc("/v1/query", func(w http.ResponseWriter, r *http.Request) {
		cid, ok := customerIDFromContext(r.Context())
		if !ok {
			http.Error(w, `{"error":"missing or unknown X-Api-Key"}`, http.StatusUnauthorized)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		if err != nil {
			http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
			return
		}
		// Two request shapes share the endpoint: {"dataset", ...} routes
		// to the named-dataset registry (datasets.go, front4 census);
		// otherwise the metric×dimension composer (legacy shape).
		var probe struct {
			Dataset string `json:"dataset"`
		}
		if err := json.Unmarshal(body, &probe); err != nil {
			http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
			return
		}
		var sql string
		var args []any
		if probe.Dataset != "" {
			var dq datasetReq
			if err := json.Unmarshal(body, &dq); err != nil {
				http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
				return
			}
			// task #70: the caller's id_user_role — server-derived, set only on
			// the verified-JWT path (userRoleFromContext). The X-Api-Key operator
			// path leaves it unset; the two role datasets then fail closed
			// (errRoleDatasetNeedsUser → 403 below). NEVER from the request body.
			roleID, roleOK := userRoleFromContext(r.Context())
			sql, args, err = compileDataset(dq, cid, callerRole{id: roleID, present: roleOK})
		} else {
			var q queryReq
			if err := json.Unmarshal(body, &q); err != nil {
				http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
				return
			}
			sql, args, err = compile(q, cid)
		}
		if err != nil {
			// task #70: a role dataset invoked without user context is
			// authenticated + well-formed but not permitted on this path →
			// 403, distinct from the 400 for a malformed/invalid request.
			code := http.StatusBadRequest
			if errors.Is(err, errRoleDatasetNeedsUser) {
				code = http.StatusForbidden
			}
			http.Error(w, `{"error":`+fmt.Sprintf("%q", err.Error())+`}`, code)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		rows, err := pool.Query(ctx, sql, args...)
		if err != nil {
			failed.Add(1)
			http.Error(w, `{"error":"query failed"}`, http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		cols := rows.FieldDescriptions()
		out := make([]map[string]any, 0, 256)
		for rows.Next() {
			vals, err := rows.Values()
			if err != nil {
				http.Error(w, `{"error":"scan failed"}`, http.StatusInternalServerError)
				return
			}
			m := make(map[string]any, len(cols))
			for i, c := range cols {
				m[string(c.Name)] = vals[i]
			}
			out = append(out, m)
		}
		served.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
	})

	// ── Screen config (P2) — layout JSON per (user, screen).
	// Table ensured by ensureSchema at startup (main.go).

	mux.HandleFunc("/v1/screen-config", func(w http.ResponseWriter, r *http.Request) {
		// ADR-0027 Surface-1: a saved layout is tenant-private. Scope both the
		// read and the upsert to the resolved customer_id ($1) so a colliding
		// id_user across tenants can neither read nor overwrite another
		// tenant's config (the pre-Surface-1 hole).
		cid, ok := customerIDFromContext(r.Context())
		if !ok {
			http.Error(w, `{"error":"missing or unknown X-Api-Key"}`, http.StatusUnauthorized)
			return
		}
		user, screen := r.URL.Query().Get("user"), r.URL.Query().Get("screen")
		if user == "" || screen == "" {
			http.Error(w, `{"error":"user and screen query params required"}`, http.StatusBadRequest)
			return
		}
		switch r.Method {
		case http.MethodGet:
			var cfg []byte
			err := pool.QueryRow(r.Context(),
				`SELECT config FROM user_screen_config WHERE id_enterprise=$1 AND id_user=$2 AND screen=$3`,
				cid, user, screen).Scan(&cfg)
			if err != nil {
				w.Header().Set("Content-Type", "application/json")
				fmt.Fprint(w, `{}`)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(cfg)
		case http.MethodPut:
			body, err := io.ReadAll(io.LimitReader(r.Body, 1<<16))
			if err != nil || !json.Valid(body) {
				http.Error(w, `{"error":"config must be valid JSON <= 64KB"}`, http.StatusBadRequest)
				return
			}
			_, err = pool.Exec(r.Context(), `INSERT INTO user_screen_config (id_enterprise, id_user, screen, config)
				VALUES ($1,$2,$3,$4) ON CONFLICT (id_enterprise, id_user, screen)
				DO UPDATE SET config = EXCLUDED.config, updated_at = now()`, cid, user, screen, string(body))
			if err != nil {
				http.Error(w, `{"error":"store failed"}`, http.StatusInternalServerError)
				return
			}
			fmt.Fprint(w, `{"ok":true}`)
		default:
			http.Error(w, `{"error":"GET or PUT"}`, http.StatusMethodNotAllowed)
		}
	})

	// ── Dashboard config (F2) — baseline ⊕ override, tenant-fenced.
	// dashboard_config baseline is ensured by 28-refdata-tables.sql (prod-gated);
	// user_screen_config override is ensured by ensureSchema (startup).
	mux.HandleFunc("/v1/dashboard-config", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, `{"error":"GET only"}`, http.StatusMethodNotAllowed)
			return
		}
		// ADR-0027 Surface-1: the tenant is the resolved customer_id ($1), never
		// client-named. The middleware guarantees it; this is the defensive fence.
		cid, ok := customerIDFromContext(r.Context())
		if !ok {
			http.Error(w, `{"error":"missing or unknown credentials"}`, http.StatusUnauthorized)
			return
		}
		dashboardID := r.URL.Query().Get("dashboard_id")
		if dashboardID == "" {
			http.Error(w, `{"error":"dashboard_id query param required"}`, http.StatusBadRequest)
			return
		}
		user := r.URL.Query().Get("user") // optional; "" ⇒ baseline only (no override row matches)

		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		var cfg []byte
		var version int
		err := pool.QueryRow(ctx, dashboardConfigResolveSQL, cid, dashboardID, user).Scan(&cfg, &version)
		found := true
		if errors.Is(err, pgx.ErrNoRows) {
			// No baseline row for this tenant+dashboard — the fence held, there is
			// simply nothing to serve. This is the cross-tenant "disjoint/none"
			// outcome for a dashboard owned by another tenant.
			found = false
		} else if err != nil {
			failed.Add(1)
			http.Error(w, `{"error":"query failed"}`, http.StatusInternalServerError)
			return
		}
		served.Add(1)
		writeDashboardConfig(w, resolveDashboardConfigResp(cfg, version, found))
	})
}

// ── Dashboard config (ADR-0029 §D2 / Phase F2) ───────────────────────────────
//
// GET /v1/dashboard-config?dashboard_id=<id>[&user=<uid>] resolves the config
// document the front4 composition engine renders (front4 useDashboardConfig,
// components/dashboard/useDashboardConfig.js). Two tables compose it:
//
//	BASELINE  dashboard_config       (id_enterprise, dashboard_id, version) → config   [28-refdata-tables.sql]
//	OVERRIDE  user_screen_config     (id_enterprise, id_user, screen)       → config   [ensureSchema]
//
// with `screen` == dashboard_id for the override. The served document is the
// jsonb top-level SHALLOW MERGE `baseline || override` — override keys win — so a
// per-user layout tweak inherits every baseline key it does not restate. Both
// reads are fenced to the injected tenant ($1); the tenant is NEVER client-named
// (ADR-0027). `user` is optional (absent ⇒ baseline only) and is NOT a tenant
// axis — it selects a row WITHIN the already-fenced tenant, same contract as
// /v1/screen-config.
//
// The merge is done in SQL (Postgres owns jsonb `||`), guarded so a non-object
// baseline is returned untouched (the handler then marks it invalid) rather than
// erroring the `||`.
const dashboardConfigResolveSQL = `
WITH baseline AS (
    SELECT config, version
    FROM dashboard_config
    WHERE id_enterprise = $1 AND dashboard_id = $2
    ORDER BY version DESC
    LIMIT 1
),
override AS (
    SELECT config
    FROM user_screen_config
    WHERE id_enterprise = $1 AND id_user = $3 AND screen = $2
)
SELECT
    CASE
        WHEN o.config IS NULL THEN b.config
        WHEN jsonb_typeof(b.config) = 'object' AND jsonb_typeof(o.config) = 'object'
            THEN b.config || o.config
        ELSE b.config
    END AS config,
    b.version AS version
FROM baseline b
LEFT JOIN override o ON true`

// dashboardConfigResp is the wire contract the front4 useDashboardConfig
// consumes. status is a SUPERSET of the F1 engine's own {ok|invalid}:
//
//	ok         a config resolved for this tenant+dashboard (config + version set).
//	           The engine STILL runs validateDashboardConfig on it and may itself
//	           downgrade to invalid — refdata owns RESOLUTION, the engine owns
//	           deep SCHEMA validation (single source of truth stays in schema.ts).
//	not_found  no baseline row for (tenant, dashboard_id) — engine renders an
//	           empty/diagnostic state.
//	invalid    a row exists but its stored config is not a JSON object (a cheap
//	           structural guard refdata CAN do without duplicating the TS schema);
//	           issues[] mirrors the engine's ValidationIssue {path, message}.
type dashboardConfigResp struct {
	Status  string          `json:"status"`
	Config  json.RawMessage `json:"config,omitempty"`
	Version *int            `json:"version,omitempty"`
	Issues  []configIssue   `json:"issues,omitempty"`
}

// configIssue mirrors front4 ValidationIssue (schema.ts) so the diagnostic tile
// renders a refdata-side issue identically to an engine-side one.
type configIssue struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

// resolveDashboardConfigResp maps a resolved DB result to the wire envelope. Pure
// (no I/O) so the not_found / invalid / ok policy is unit-tested DB-free:
//   - found=false ⇒ not_found (the fence held; nothing owned by this tenant).
//   - found + non-object config ⇒ invalid (cheap structural guard; deep schema
//     validation stays engine-side).
//   - found + object config ⇒ ok (config + version).
func resolveDashboardConfigResp(cfg []byte, version int, found bool) dashboardConfigResp {
	if !found {
		return dashboardConfigResp{Status: "not_found"}
	}
	var probe map[string]json.RawMessage
	if json.Unmarshal(cfg, &probe) != nil {
		return dashboardConfigResp{
			Status: "invalid",
			Issues: []configIssue{{Path: "(root)", Message: "stored config is not a JSON object"}},
		}
	}
	return dashboardConfigResp{Status: "ok", Config: json.RawMessage(cfg), Version: &version}
}

func writeDashboardConfig(w http.ResponseWriter, resp dashboardConfigResp) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func keysOf[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// ensureSchema is the startup migration hook — called once from main
// before routes register, not as a route-registration side effect.
//
// ADR-0027 Surface-1: user_screen_config is tenant-private. A fresh table is
// keyed on (id_enterprise, id_user, screen). The ALTER/DROP/CREATE lines are
// the idempotent forward-migration for a table created before Surface-1 (the
// old PK was (id_user, screen)): add the owning enterprise, drop the old PK,
// and re-key on a unique index that includes id_enterprise — the ON CONFLICT
// target the upsert now uses. Backfilled rows get id_enterprise = 0 (an
// unreachable tenant), so they are invisible to any real key. Multi-statement
// Exec is fine on the simple protocol this pool uses.
func ensureSchema(pool *pgxpool.Pool) {
	_, _ = pool.Exec(context.Background(), `
		CREATE TABLE IF NOT EXISTS user_screen_config (
			id_enterprise int NOT NULL DEFAULT 0,
			id_user text NOT NULL, screen text NOT NULL, config jsonb NOT NULL,
			updated_at timestamptz NOT NULL DEFAULT now());
		ALTER TABLE user_screen_config ADD COLUMN IF NOT EXISTS id_enterprise int NOT NULL DEFAULT 0;
		ALTER TABLE user_screen_config DROP CONSTRAINT IF EXISTS user_screen_config_pkey;
		CREATE UNIQUE INDEX IF NOT EXISTS user_screen_config_tenant_key
			ON user_screen_config (id_enterprise, id_user, screen);`)
}
