package main

// historian.go — T6 (#176): a read-api reach into the hot+cold historian gateway.
//
// The named-dataset / grain query engine is capped at a 90-day window on purpose
// (query.go) and reads the HOT store only. But a front4 time-range selector that
// scrolls back past the hot boundary needs the COLD S3 archive too. The
// historian-gateway (compose.historian-gateway.yml, container `hist-gateway`)
// already unions HOT (postgres_fdw → the live timescaledb) with COLD (S3 Parquet
// via pg_duckdb) behind ev_all / ev_between, with per-partition pruning. This
// endpoint is the read-api door to it.
//
// DESIGN — deliberately ISOLATED + ADDITIVE (nothing here touches the existing
// pool, dataset framework, or query path):
//   - A SEPARATE, OPTIONAL pool (histPool) to hist-gateway. If HIST_GW_PASSWORD is
//     unset or the gateway is unreachable at boot, histPool is nil and the
//     endpoint returns 503 — read-api is otherwise byte-identical to today.
//   - ONE endpoint: POST /v1/historian/production-series. Daily-aggregated
//     gross/net per equipment over an arbitrary window (the shape a long-range
//     chart wants; bounds the row count that a raw 1-min series would explode).
//   - TENANT ISOLATION: the gateway view has NO RLS engine — the caller MUST carry
//     id_enterprise. We inject it from the SERVER-RESOLVED customer_id (auth
//     middleware), never the request body — identical rule to /v1/query.
//   - Queries the ev_all VIEW (NOT the ev_between function — pg_duckdb can't run
//     read_parquet wrapped in a SQL function) and carries ev_between's year/month
//     prune predicate inline, so the cold side reads the relevant partition files
//     only (T3: 1/181), not the whole archive.
//   - The gateway pool uses the SIMPLE query protocol — pg_duckdb doesn't apply
//     the S3 secret on the prepared-statement path (see newHistPool).

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// histMaxWindow bounds a single historian query. Generous (the archive spans
// years) but finite so one call can't ask the gateway to scan everything.
const histMaxWindow = 5 * 365 * 24 * time.Hour // ~5 years

// histRowLimit caps the daily-aggregated result. Days × equipment over 5 years
// stays well under this for any real line; the cap is a runaway guard.
const histRowLimit = 100000

// newHistPool builds the OPTIONAL pool to the historian gateway. Returns nil
// (never an error) when the gateway is not configured or not reachable — the
// caller treats nil as "historian disabled" and read-api starts normally. This
// is the nil-safe seam: no env, no dependency, no behavior change.
func newHistPool(ctx context.Context, logger *slog.Logger) *pgxpool.Pool {
	pass := os.Getenv("HIST_GW_PASSWORD")
	if pass == "" {
		logger.Info("historian: HIST_GW_PASSWORD unset — /v1/historian disabled (503)")
		return nil
	}
	host := getenv("HIST_GW_HOST", "hist-gateway")
	port := getenv("HIST_GW_PORT", "5432")
	user := getenv("HIST_GW_USER", "postgres")
	db := getenv("HIST_GW_DB", "postgres")
	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s", host, port, user, pass, db)
	pc, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		logger.Warn("historian: parse dsn failed — endpoint disabled", slog.String("err", err.Error()))
		return nil
	}
	// SIMPLE protocol (not the pgx default extended/prepared) — REQUIRED for
	// pg_duckdb: on the prepared-statement path the S3 secret is NOT applied to
	// the DuckDB read_parquet, so a cold scan fails "HTTP 403 ... No credentials"
	// (and empty results throw "Could not convert DuckDB type: UNKNOWN"). A
	// simple-protocol query — exactly what psql sends, which works — resolves both.
	// pgx still sanitizes the $N params client-side, so the tenant fence stays safe.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	// A duckdb-backed cold scan is heavy; keep the pool small so read-api can never
	// stampede the gateway.
	pc.MaxConns = 4
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		logger.Warn("historian: pool init failed — endpoint disabled", slog.String("err", err.Error()))
		return nil
	}
	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		logger.Warn("historian: gateway unreachable at boot — endpoint disabled", slog.String("err", err.Error()))
		pool.Close()
		return nil
	}
	logger.Info("historian: gateway pool ready", slog.String("host", host))
	return pool
}

type histSeriesReq struct {
	From      time.Time `json:"from"`
	To        time.Time `json:"to"`
	Equipment []int     `json:"equipment,omitempty"` // optional filter; empty ⇒ all of the tenant's
}

// histProductionSeriesSQL — daily gross/net per equipment over [from,to) for one
// tenant, hot+cold via the ev_all VIEW.
//
// WHY ev_all (view) and NOT ev_between (function): pg_duckdb runs the cold-side
// read_parquet in DuckDB and the hot-side FDW in Postgres as ONE mixed plan when
// the parquet scan is inline in a query/view — but wrapping it in a SQL function
// breaks that (force-off → "read_parquet only works with DuckDB execution";
// force-on → DuckDB doesn't know the PG function). So we inline the view and
// carry ev_between's year/month prune predicate ourselves.
//
// $1=id_enterprise (TENANT FENCE, server-resolved) $2=from $3=to $4=equipment[]
// (NULL ⇒ all) $5=fromYear $6=fromMonth $7=toYear $8=toMonth. The ts_value bound
// is exact; the year/month bound is what prunes the cold parquet to the relevant
// partition files (T3 — a bounded query reads 1/181 files, not all). Row cap appended.
const histProductionSeriesSQL = `
  SELECT date_trunc('day', ts_value)::date       AS day,
         id_equipment,
         sum(gross_production_incr)               AS gross_production,
         sum(net_production_incr)                 AS net_production
    FROM ev_all
   WHERE id_enterprise = $1
     AND ts_value >= $2 AND ts_value < $3
     AND ($4::int[] IS NULL OR id_equipment = ANY($4))
     AND ( year >  $5 OR (year = $5 AND month >= $6) )
     AND ( year <  $7 OR (year = $7 AND month <= $8) )
   GROUP BY 1, 2
   ORDER BY 1, 2
   LIMIT %d`

// registerHistorianAPI mounts POST /v1/historian/production-series. Always
// mounted (so the route is discoverable); returns 503 when histPool is nil.
func registerHistorianAPI(mux *http.ServeMux, histPool *pgxpool.Pool, logger *slog.Logger) {
	mux.HandleFunc("/v1/historian/production-series", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"POST only"}`, http.StatusMethodNotAllowed)
			return
		}
		cid, ok := customerIDFromContext(r.Context())
		if !ok {
			http.Error(w, `{"error":"missing or unknown X-Api-Key"}`, http.StatusUnauthorized)
			return
		}
		// Validate the request BEFORE checking backend availability, so a malformed
		// window is always a clean 400 regardless of whether the gateway is up.
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		if err != nil {
			http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
			return
		}
		var q histSeriesReq
		if err := json.Unmarshal(body, &q); err != nil {
			http.Error(w, `{"error":"bad request body"}`, http.StatusBadRequest)
			return
		}
		if q.From.IsZero() || q.To.IsZero() || !q.To.After(q.From) {
			http.Error(w, `{"error":"invalid window: require from < to (RFC3339)"}`, http.StatusBadRequest)
			return
		}
		if q.To.Sub(q.From) > histMaxWindow {
			http.Error(w, fmt.Sprintf(`{"error":"window exceeds %s historian budget"}`, histMaxWindow), http.StatusBadRequest)
			return
		}
		if histPool == nil {
			http.Error(w, `{"error":"historian gateway not configured"}`, http.StatusServiceUnavailable)
			return
		}
		// Optional equipment filter → NULL when empty so the SQL predicate is a
		// no-op (all of the tenant's equipment). NEVER the tenant fence — that is
		// always the server-resolved cid ($3).
		var equip any
		if len(q.Equipment) > 0 {
			equip = q.Equipment
		} else {
			equip = nil
		}
		// Year/month prune bounds (UTC — the partition columns are UTC-derived).
		// Computed in Go so they bind as plain int constants the planner prunes on.
		fu, tu := q.From.UTC(), q.To.UTC()
		fy, fm := fu.Year(), int(fu.Month())
		ty, tm := tu.Year(), int(tu.Month())
		// A cold duckdb scan can be slow even pruned; give it room but bound it.
		ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
		defer cancel()
		sql := fmt.Sprintf(histProductionSeriesSQL, histRowLimit)
		payload, err := runQueryJSON(ctx, histPool, sql, []any{cid, q.From, q.To, equip, fy, fm, ty, tm})
		if err != nil {
			logger.Warn("historian query failed", slog.Int("cid", cid), slog.String("err", err.Error()))
			http.Error(w, `{"error":"historian query failed"}`, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(payload)
	})
}
