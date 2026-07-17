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
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

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
			sql, args, err = compileDataset(dq, cid)
		} else {
			var q queryReq
			if err := json.Unmarshal(body, &q); err != nil {
				http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
				return
			}
			sql, args, err = compile(q, cid)
		}
		if err != nil {
			http.Error(w, `{"error":`+fmt.Sprintf("%q", err.Error())+`}`, http.StatusBadRequest)
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
