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
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/read-api/internal/cache"
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

func registerQueryAPI(mux routeMux, pool *pgxpool.Pool, qcache *cache.Cache) {
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
		body, ok := readBodyCapped(w, r, maxRequestBody)
		if !ok {
			return
		}
		var err error
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
		var windowFrom time.Time     // T2 coverage: the requested window start (dataset path)
		datasetName := probe.Dataset // "" ⇒ legacy composer path (never cached)
		if probe.Dataset != "" {
			var dq datasetReq
			if err := json.Unmarshal(body, &dq); err != nil {
				http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
				return
			}
			// task #70: the caller's id_user_role — server-derived, set only on
			// the verified-JWT path (userRoleFromContext). The X-Api-Key operator
			// path leaves it unset; the per-user-role datasets then fail closed
			// (errRoleDatasetNeedsUser → 403 below). NEVER from the request body.
			roleID, roleOK := userRoleFromContext(r.Context())
			sql, args, err = compileDataset(dq, cid, callerRole{id: roleID, present: roleOK})
			if dq.Window != nil {
				windowFrom = dq.Window.From
			}
		} else {
			var q queryReq
			if err := json.Unmarshal(body, &q); err != nil {
				http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
				return
			}
			sql, args, err = compile(q, cid)
			// T2 honest windows: the composer reads ONE cagg whose lifetime is declared
			// in ops.retention_policy. A window starting before that floor used to return
			// a silently SHORT series; now it is an explicit 422 pointing at the archive.
			if err == nil {
				if g, ok := grains[q.Grain]; ok {
					if keep, ok := covIdx.relationKeep(g.table); ok {
						if floor := time.Now().Add(-keep); q.From.Before(floor) {
							msg := fmt.Sprintf("window starts before %s: %s keeps %s; for older data use /v1/historian/production-series",
								floor.UTC().Format(time.RFC3339), g.table, humanDuration(keep))
							http.Error(w, `{"error":`+fmt.Sprintf("%q", msg)+`}`, http.StatusUnprocessableEntity)
							return
						}
					}
				}
			}
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
		// 40s (was 20s): the heaviest named dataset, downtimes-events
		// (serving.downtime_events_v2), is sub-second WARM (~300-540ms) but ~18-21s
		// COLD — it decompresses ~2 months of silver.equipment_events columnar chunks
		// per request (the fn pads the window by ±1 month before the tstzrange overlap
		// filter). At 20s a cold load tripped context-deadline → load() error → the
		// front4 Downtimes submenu 500'd ("query failed"). 40s clears the cold load so
		// it completes and populates the cache (then served in <1s). The durable fix is
		// to make downtime_events_v2 cheap cold (early id_enterprise filter + a tighter
		// pad + chunk-exclusion-friendly predicates) — tracked as a DB follow-up.
		ctx, cancel := context.WithTimeout(r.Context(), 40*time.Second)
		defer cancel()

		// The DB read → JSON-array bytes. Shared verbatim by the cached and
		// uncached paths so the served bytes are identical either way.
		load := func(ctx context.Context) ([]byte, error) {
			return runQueryJSON(ctx, pool, cid, sql, args)
		}

		var payload []byte
		// Cache-aside (ADR-0035): ONLY the named-dataset path (front4 poll target).
		// The legacy composer path (datasetName == "") is never cached. ttl<=0 or a
		// disabled/nil cache ⇒ GetOrLoad is a transparent pass-through to load. The
		// key is tenant-fenced by the SERVER-RESOLVED cid — never the request body.
		if datasetName != "" {
			ttl := datasetCacheTTL(datasetName)
			key := cache.DatasetKey(cid, string(activeFlow), datasetName, sql, args)
			payload, err = qcache.GetOrLoad(ctx, key, ttl, load)
		} else {
			payload, err = load(ctx)
		}
		if err != nil {
			failed.Add(1)
			http.Error(w, `{"error":"query failed"}`, http.StatusInternalServerError)
			return
		}
		served.Add(1)
		if datasetName != "" {
			if cov, ok := covIdx.dataset(datasetName); ok {
				setCoverageHeaders(w.Header(), cov, windowFrom, time.Now())
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(payload)
	})

	// ── Screen config (P2) — layout JSON per (user, screen).
	// Table owned by db/migrations/t-readapi-screen-config; checked (never created) at boot.

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
				`SELECT config FROM identity.user_screen_config WHERE id_enterprise=$1 AND id_user=$2 AND screen=$3`,
				cid, user, screen).Scan(&cfg)
			if errors.Is(err, pgx.ErrNoRows) {
				// Nothing saved yet for (tenant, user, screen): the contract is 200 {}.
				w.Header().Set("Content-Type", "application/json")
				fmt.Fprint(w, `{}`)
				return
			}
			if err != nil {
				// A real DB failure is NOT "no layout": answering 200 {} here made
				// the SPA render (and then save over) an empty layout on any outage.
				failed.Add(1)
				http.Error(w, `{"error":"query failed"}`, http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(cfg)
		case http.MethodPut:
			body, ok := readBodyCapped(w, r, maxRequestBody)
			if !ok {
				return
			}
			if !json.Valid(body) {
				http.Error(w, `{"error":"config must be valid JSON <= 64KB"}`, http.StatusBadRequest)
				return
			}
			_, err := pool.Exec(r.Context(), `INSERT INTO identity.user_screen_config (id_enterprise, id_user, screen, config)
				VALUES ($1,$2,$3,$4) ON CONFLICT (id_enterprise, id_user, screen)
				DO UPDATE SET config = EXCLUDED.config, updated_at = now()`, cid, user, screen, string(body))
			if err != nil {
				http.Error(w, `{"error":"store failed"}`, http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"ok":true}`)
		default:
			http.Error(w, `{"error":"GET or PUT"}`, http.StatusMethodNotAllowed)
		}
	})

	// ── Dashboard config (F2) — baseline ⊕ override, tenant-fenced.
	// dashboard_config baseline is ensured by 28-refdata-tables.sql (prod-gated);
	// user_screen_config override: db/migrations/t-readapi-screen-config.
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

// maxRequestBody caps every read-api JSON request body (/v1/query, the
// historian series, PUT /v1/screen-config).
const maxRequestBody = 1 << 16 // 64 KB

// readBodyCapped reads the request body under http.MaxBytesReader. Over the cap
// is 413 {"error":"payload too large"}; any other read failure is 400
// {"error":"bad request body"}. It replaced io.LimitReader, which silently
// truncated an oversized body and then failed (or, for a truncation that is
// still valid JSON, succeeded) on the cut-off bytes. ok=false ⇒ the response
// has been written.
func readBodyCapped(w http.ResponseWriter, r *http.Request, limit int64) (body []byte, ok bool) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			http.Error(w, `{"error":"payload too large"}`, http.StatusRequestEntityTooLarge)
			return nil, false
		}
		http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
		return nil, false
	}
	return body, true
}

// ── Dashboard config (ADR-0029 §D2 / Phase F2) ───────────────────────────────
//
// GET /v1/dashboard-config?dashboard_id=<id>[&user=<uid>] resolves the config
// document the front4 composition engine renders (front4 useDashboardConfig,
// components/dashboard/useDashboardConfig.js). Two tables compose it:
//
//	BASELINE  dashboard_config       (id_enterprise, dashboard_id, version) → config   [28-refdata-tables.sql]
//	OVERRIDE  user_screen_config     (id_enterprise, id_user, screen)       → config   [t-readapi-screen-config]
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
    FROM identity.user_screen_config
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

// runQueryJSON executes sql/args and marshals the result set as a JSON array of
// row objects — the exact wire shape the /v1/query handler serves. Extracted so
// the cached and uncached paths share ONE query+encode implementation, and so
// the cache-aside loader can hand back ready-to-cache bytes. A DB/scan/marshal
// error is returned (never cached); the caller maps it to a 500.
func runQueryJSON(ctx context.Context, pool *pgxpool.Pool, cid int, sql string, args []any) ([]byte, error) {
	out, err := runQueryRows(ctx, pool, cid, sql, args)
	if err != nil {
		return nil, err
	}
	return json.Marshal(out)
}

// runQueryRows is runQueryJSON without the final marshal: the tenant-stamped read,
// returned as one map per row keyed by column name (the historian split path merges
// two such result sets before serializing).
func runQueryRows(ctx context.Context, pool *pgxpool.Pool, cid int, sql string, args []any) ([]map[string]any, error) {
	// task #264 — defense-in-depth tenant fence. read-api connects as a NOBYPASSRLS
	// role (readapi_ro), and the analytics DB puts FORCE ROW LEVEL SECURITY on the
	// tenant tables (core.equipments / production_orders / production_targets,
	// gold.equipment_oee_hourly / _shift / production_orders_runtime), keyed on the
	// session GUC `app.tenant_id` (public.current_tenant()). The app-layer
	// `WHERE id_enterprise = $1` fence stays the PRIMARY isolator; stamping the GUC to
	// the SAME server-derived tenant makes Postgres RLS a CO-ENFORCER — so if a future
	// dataset ever ships without the $1 fence, RLS scopes it to this tenant instead of
	// leaking every tenant's rows (under the old `postgres`/BYPASSRLS connection RLS
	// never bit, so an unfenced dataset would have leaked all tenants).
	//
	// set_config(..., is_local => true) is TRANSACTION-LOCAL, so it is safe under the
	// pgbouncer transaction pooling this pool runs behind (the setting is discarded when
	// the server connection is returned to the pool) — a plain SET would leak the tenant
	// onto the next borrower. We therefore run the stamp + the read inside ONE explicit
	// transaction. cid is a SERVER-DERIVED int (from the resolved credential, never the
	// request body), so the literal interpolation carries no injection risk and sidesteps
	// the simple-protocol parameter path this pool uses.
	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, fmt.Sprintf("SELECT set_config('app.tenant_id', '%d', true)", cid)); err != nil {
		return nil, err
	}
	rows, err := tx.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	cols := rows.FieldDescriptions()
	out := make([]map[string]any, 0, 256)
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			rows.Close()
			return nil, err
		}
		m := make(map[string]any, len(cols))
		for i, c := range cols {
			m[string(c.Name)] = vals[i]
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

func keysOf[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// screenConfigCheckSQL reports whether identity.user_screen_config exists and
// whether the login can read and upsert it. read-api issues NO DDL: the table is
// owned by db/migrations/t-readapi-screen-config (and t276 grants readapi_ro
// SELECT, INSERT, UPDATE on it). to_regclass and has_table_privilege need no
// privilege on the table, so this works for any login.
const screenConfigCheckSQL = `
SELECT t IS NOT NULL,
       COALESCE(has_table_privilege(t::oid, 'SELECT')
            AND has_table_privilege(t::oid, 'INSERT')
            AND has_table_privilege(t::oid, 'UPDATE'), false)
  FROM (SELECT to_regclass('identity.user_screen_config') AS t) x`

// rowQuerier is the slice of *pgxpool.Pool the boot check uses (fakeable in tests).
type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// checkScreenConfigTable is the boot-time readiness probe for /v1/screen-config
// and the /v1/dashboard-config override. It replaced ensureSchema, which ran
// CREATE SCHEMA / CREATE TABLE / ALTER TABLE at every boot: a read API running
// as the least-privilege readapi_ro has no CREATE or ownership, so that DDL was
// always "permission denied" (swallowed) on staging and the dev seed. Schema
// changes belong in db/migrations, not in a service's startup path.
//
// Non-fatal by design (same as before): the rest of the read plane does not
// depend on this table. It logs an ERROR naming the migration when the table is
// missing or the login cannot read/upsert it, so the gap is visible at boot
// instead of as a 500 on the first PUT.
func checkScreenConfigTable(ctx context.Context, q rowQuerier, logger *slog.Logger) (exists, writable bool) {
	if err := q.QueryRow(ctx, screenConfigCheckSQL).Scan(&exists, &writable); err != nil {
		logger.Warn("screen-config readiness check failed", slog.String("err", err.Error()))
		return false, false
	}
	switch {
	case !exists:
		logger.Error("identity.user_screen_config is missing: /v1/screen-config and the dashboard-config override will 500",
			slog.String("fix", "apply db/migrations/t-readapi-screen-config/01-up.sql"))
	case !writable:
		logger.Error("login lacks SELECT/INSERT/UPDATE on identity.user_screen_config: /v1/screen-config will 500",
			slog.String("fix", "apply db/migrations/t-readapi-screen-config/01-up.sql (grants readapi_ro)"))
	default:
		logger.Info("screen-config table ready")
	}
	return exists, writable
}
