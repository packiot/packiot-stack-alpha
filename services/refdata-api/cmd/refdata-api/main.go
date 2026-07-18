// refdata-api — the Hasura-replacement read API (task #86, Option C).
//
// Serves the EXACT reference-read contract enumerated from 12h of
// Hasura query-log (docs/audits/hasura-review-2026.md §Update 2026-07-02):
// 10 root fields = 5 SQL functions + 5 views/tables. Flow 1
// (edge-node-red) keeps the minimal Hasura as the stable alpha; the
// refactored stack (flows 2/3) consumes THIS service instead — no
// GraphQL engine, no metadata tracking, one ~400-line binary.
//
// v1 reads the main staging DB (where the reference data and the SQL
// functions live). Flow-routing to the refactored DB arrives when
// ADR-0012 Phase 4 lands the reference tables there — the handler
// table is schema-parameterized to make that a config change, not a
// rewrite.
//
// Endpoints return raw JSON arrays (rows as objects) — the same shape
// consumers get from Hasura's data root, minus the GraphQL envelope.
package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/packiot/packiot-stack-alpha/services/refdata-api/internal/httpmetrics"
	"github.com/packiot/packiot-stack-alpha/services/refdata-api/internal/tracing"
)

type endpoint struct {
	path  string
	sql   string
	class routeClass
	// args builds the CLIENT-supplied arguments only. For routeTenantScoped
	// endpoints makeHandler PREPENDS the server-resolved customer_id as $1,
	// so a client arg returned here binds $2, $3, … . nil = no client args
	// (customer_id-only for scoped routes; zero args for global ones).
	args func(r *http.Request) ([]any, error)
}

// topicsArg parses ?topics=a,b,c into a text[] argument.
func topicsArg(r *http.Request) ([]any, error) {
	raw := r.URL.Query().Get("topics")
	if raw == "" {
		return nil, fmt.Errorf("missing required query param: topics")
	}
	return []any{strings.Split(raw, ",")}, nil
}

func topicArg(r *http.Request) ([]any, error) {
	t := r.URL.Query().Get("topic")
	if t == "" {
		return nil, fmt.Errorf("missing required query param: topic")
	}
	return []any{t}, nil
}

// The contract — one entry per Hasura root field. ADR-0027 Surface-1 re-homes
// these eleven Generation-A routes behind the single injection authority:
// each is tenant-scoped by the server-resolved customer_id ($1) and the
// client can no longer name a tenant (?enterprise= is gone; ?topics= only
// narrows WITHIN the tenant). The scoping is byte-stable — every backing
// function/view ALREADY emits id_enterprise (via its equipments join or as a
// view column), so an outer `WHERE id_enterprise = $1` changes no response
// column, it only drops other tenants' rows. The operator caches /v1/* by URL
// and parses fixed shapes, so shape stability is the load-bearing contract.
var endpoints = []endpoint{
	// Event / downtime timelines — the SETOF functions emit id_enterprise
	// from their internal equipments join; ?topics= binds $2 (a filter within
	// the tenant), $1 is the caller's id.
	{"/v1/events-timeline",
		`SELECT * FROM h_piot_get_events_timeline3_with_event_id($2) WHERE id_enterprise = $1`,
		routeTenantScoped, topicsArg},
	{"/v1/pending-downtime",
		`SELECT * FROM h_piot_get_equipment_pending_downtime_with_event_id($2) WHERE id_enterprise = $1`,
		routeTenantScoped, topicsArg},
	{"/v1/shift-hours",
		`SELECT * FROM piot_get_shift_hours_by_packml_topic_2($2) WHERE id_enterprise = $1`,
		routeTenantScoped, topicArg},
	// ?enterprise= DROPPED (ADR-0027 §4): the enterprise is the key's
	// customer_id, never client-supplied. The real tenant scope is the outer
	// WHERE; the path stays alive (byte-stable shape) because the operator
	// caches /v1/* by URL.
	// Arity note (task #90): PROD's piot_get_shift_hours_by_enterprise_packml_topic_2
	// takes ONE arg (in_topic) — it resolves the enterprise internally from
	// packml_register. Staging's copy is a 2-arg wrapper (in_topic, in_enterprise
	// DEFAULT NULL) whose body is `SELECT * FROM piot_get_shift_hours_by_packml_topic_2(in_topic)`
	// — the enterprise arg is dead. Binding a 2nd arg 500s on prod (arity
	// mismatch) and does nothing on staging, so we bind topic only. Byte-stable
	// on both; tenant fencing is entirely the outer WHERE id_enterprise = $1.
	{"/v1/shift-hours-by-enterprise",
		`SELECT * FROM piot_get_shift_hours_by_enterprise_packml_topic_2($2) WHERE id_enterprise = $1`,
		routeTenantScoped, topicArg},
	{"/v1/day-week-begin",
		`SELECT * FROM piot_get_day_week_begin_by_packml_topic($2) WHERE id_enterprise = $1`,
		routeTenantScoped, topicArg},
	// v_operator_* views expose id_enterprise as a column already returned to
	// the operator; the predicate only removes other tenants' rows.
	{"/v1/operator-po-list",
		`SELECT * FROM v_operator_po_list_setup_4 WHERE id_enterprise = $1`,
		routeTenantScoped, nil},
	{"/v1/operator-po-details",
		`SELECT * FROM v_operator_po_details_3 WHERE id_enterprise = $1`,
		routeTenantScoped, nil},
	{"/v1/operator-entities",
		`SELECT * FROM v_operator_entities_2 WHERE id_enterprise = $1`,
		routeTenantScoped, nil},
	{"/v1/entities-per-user-role",
		`SELECT * FROM v_entities_per_user_role_operator WHERE id_enterprise = $1`,
		routeTenantScoped, nil},
	// language_packs is global i18n — no tenant column (ADR-0027 §2's one
	// deliberate exception). Still behind auth (a valid key is required), but
	// carries no $1: routeGlobalRef.
	{"/v1/language-packs",
		`SELECT * FROM language_packs`,
		routeGlobalRef, nil},
	// downtime-reasons: equipments already carries id_enterprise; add the
	// tenant predicate and move the topic vector to $2. Same projected columns.
	{"/v1/downtime-reasons",
		`SELECT e.id_equipment, e.downtime_reasons, e.scrap_reasons, p.packml_topic
	   FROM equipments e JOIN packml_register p ON p.id_equipment = e.id_equipment AND p.id_unit = e.id_equipment
	  WHERE p.packml_topic = ANY($2) AND p.active AND e.id_enterprise = $1`,
		routeTenantScoped, topicsArg},
}

var (
	served atomic.Uint64
	failed atomic.Uint64
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With(slog.String("service", "refdata-api"))
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}
	// --dump-contract: emit the datasets/routes → prod pg-object positional
	// contract as JSON and exit. Read-only introspection, no DB touch; consumed
	// by scripts/refdata-contract-drift-check.sh to diff against live prod
	// (task #71). Kept out of the serving path entirely.
	if len(os.Args) > 1 && os.Args[1] == "--dump-contract" {
		if err := dumpContract(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "dump-contract:", err)
			os.Exit(1)
		}
		os.Exit(0)
	}

	// Distributed tracing → Tempo. Opt-in: no-op unless OTEL_EXPORTER_OTLP_
	// ENDPOINT is set (see internal/tracing). A failure here never blocks boot.
	shutdownTracing, terr := tracing.Init(context.Background(), "refdata-api")
	if terr != nil {
		logger.Warn("tracing init failed; continuing untraced", slog.String("err", terr.Error()))
	}
	defer func() { _ = shutdownTracing(context.Background()) }()

	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s",
		getenv("DB_HOST", "pgbouncer"), getenv("DB_PORT", "5432"),
		getenv("DB_USER", "postgres"), os.Getenv("DB_PASSWORD"),
		getenv("DB_NAME", "packiot"))
	pc, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		logger.Error("parse dsn", slog.String("err", err.Error()))
		os.Exit(1)
	}
	pc.MaxConns = 5
	// pgbouncer transaction pooling breaks pgx prepared statements —
	// same fix as every other service in this stack.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	// otelpgx emits a span per query, so each /v1 read shows its DB time as a
	// child span of the request. No-op unless tracing is enabled.
	pc.ConnConfig.Tracer = otelpgx.NewTracer()
	pool, err := pgxpool.NewWithConfig(context.Background(), pc)
	if err != nil {
		logger.Error("pool", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer pool.Close()

	mux := http.NewServeMux()
	for _, ep := range endpoints {
		mux.HandleFunc(ep.path, makeHandler(pool, ep, logger))
	}
	ensureSchema(pool)          // startup migrations (P2 screen-config table)
	registerQueryAPI(mux, pool) // ADR-0015 P1-P3

	// Gap-closure 2026-07-07: the only service without /metrics.
	// promhttp default registry — request counts come from reqCount
	// (incremented in makeHandler's wrapper below); Go runtime metrics
	// ride along free.
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := pool.Ping(ctx); err != nil {
			http.Error(w, `{"healthy":false}`, http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintf(w, `{"healthy":true,"served":%d,"failed":%d}`, served.Load(), failed.Load())
	})

	port := getenv("HEALTH_PORT", "9104")
	logger.Info("refdata-api listening", slog.String("port", port), slog.Int("endpoints", len(endpoints)))
	// ADR-0027 Surface-1: the single tenant-injection authority, applied as
	// middleware in front of the WHOLE mux so no route can skip it. It
	// resolves a credential → customer_id (fail-closed: no/invalid credential →
	// 401, no DB touch) and injects the id via context. /healthz + /metrics are
	// exempt (ops probes, no tenant data).
	//
	// Two credential types resolve to the SAME tenant:
	//   - X-Api-Key → customer_id via the static QUERY_API_KEYS map (operator).
	//   - Authorization: Bearer <firebase-jwt> → uid → id_enterprise via the
	//     users table (task #68, the front4 static-SPA path). Public-key token
	//     verification: no secret needed. The project id is config
	//     (FIREBASE_PROJECT_ID, default fbpackiot); the JWKS/x509 URL is a
	//     public constant. The uid→tenant lookup is cached (5-min TTL).
	keys := parseAPIKeys(os.Getenv("QUERY_API_KEYS"))
	projectID := getenv("FIREBASE_PROJECT_ID", defaultFirebaseProject)
	bearer := newFirebaseBearerAuth(newFirebaseVerifier(projectID, nil), pool, 5*time.Minute)
	logger.Info("tenant auth configured",
		slog.Int("keys", len(keys)), slog.String("firebase_project", projectID))
	// ADR-0031 Workstream B: mount the external-contract anti-corruption shims.
	// They resolve the tenant through the SAME key map (single injection
	// authority) but self-authenticate, so they sit in the auth-exempt set below.
	// Must register BEFORE the middleware wraps the mux.
	registerExternalShims(mux, pool, keys, logger)
	authed := authMiddleware(keys, authExemptSet(), bearer.resolve, mux)
	// RED metrics on every /v1 route → the same promhttp default registry
	// /metrics already serves. httpmetrics wraps the auth middleware so 401s
	// are counted too; otelhttp is the outermost server span (the trace root,
	// continuing any inbound traceparent).
	handler := otelhttp.NewHandler(httpmetrics.New(prometheus.DefaultRegisterer)(authed), "refdata-api")
	if err := http.ListenAndServe(":"+port, handler); err != nil {
		logger.Error("http", slog.String("err", err.Error()))
		os.Exit(1)
	}
}

// makeHandler runs the endpoint's SQL and streams rows as a JSON array
// of objects — pgx field descriptions give the column names, so one
// generic encoder covers every endpoint.
func makeHandler(pool *pgxpool.Pool, ep endpoint, logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var args []any
		// ADR-0027 Surface-1: tenant-scoped routes bind the server-resolved
		// customer_id as $1 — client args (if any) follow as $2+. The
		// customer_id comes from the auth middleware via context, never the
		// request. This defensive check is unreachable behind the middleware,
		// but it guarantees a scoped query can never run without $1.
		if ep.class == routeTenantScoped {
			cid, ok := customerIDFromContext(r.Context())
			if !ok {
				failed.Add(1)
				http.Error(w, `{"error":"missing or unknown X-Api-Key"}`, http.StatusUnauthorized)
				return
			}
			args = append(args, cid)
		}
		if ep.args != nil {
			clientArgs, err := ep.args(r)
			if err != nil {
				failed.Add(1)
				http.Error(w, `{"error":`+strconv.Quote(err.Error())+`}`, http.StatusBadRequest)
				return
			}
			args = append(args, clientArgs...)
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		rows, err := pool.Query(ctx, ep.sql, args...)
		if err != nil {
			failed.Add(1)
			logger.Warn("query failed", slog.String("path", ep.path), slog.String("err", err.Error()))
			http.Error(w, `{"error":"query failed"}`, http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		cols := rows.FieldDescriptions()
		out := make([]map[string]any, 0, 64)
		for rows.Next() {
			vals, err := rows.Values()
			if err != nil {
				failed.Add(1)
				http.Error(w, `{"error":"row scan failed"}`, http.StatusInternalServerError)
				return
			}
			m := make(map[string]any, len(cols))
			for i, c := range cols {
				m[string(c.Name)] = vals[i]
			}
			out = append(out, m)
		}
		if rows.Err() != nil {
			failed.Add(1)
			http.Error(w, `{"error":"rows error"}`, http.StatusInternalServerError)
			return
		}
		served.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
	}
}

func runHealthcheck() int {
	c := http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get("http://127.0.0.1:" + getenv("HEALTH_PORT", "9104") + "/healthz")
	if err != nil || resp.StatusCode != http.StatusOK {
		return 1
	}
	resp.Body.Close()
	return 0
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
