// refdata-api — the Hasura-replacement read API (task #86, Option C).
//
// Serves the EXACT reference-read contract enumerated from 12h of
// Hasura query-log (docs/hasura-review-2026.md §Update 2026-07-02):
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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type endpoint struct {
	path string
	sql  string
	args func(r *http.Request) ([]any, error) // nil = no args
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

func topicEnterpriseArg(r *http.Request) ([]any, error) {
	t := r.URL.Query().Get("topic")
	e := r.URL.Query().Get("enterprise")
	if t == "" || e == "" {
		return nil, fmt.Errorf("missing required query params: topic, enterprise")
	}
	id, err := strconv.Atoi(e)
	if err != nil {
		return nil, fmt.Errorf("enterprise must be an integer")
	}
	return []any{t, id}, nil
}

// The contract — one entry per Hasura root field. SQL functions are
// called as-is (they live in the main DB until their ADR-0014 ports);
// view reads go through the LIVE view generation (_2/_3/_setup_4 —
// the version-suffixed ones are the consumed generation, per the
// query-log enumeration).
var endpoints = []endpoint{
	{"/v1/events-timeline", `SELECT * FROM h_piot_get_events_timeline3_with_event_id($1)`, topicsArg},
	{"/v1/pending-downtime", `SELECT * FROM h_piot_get_equipment_pending_downtime_with_event_id($1)`, topicsArg},
	{"/v1/shift-hours", `SELECT * FROM piot_get_shift_hours_by_packml_topic_2($1)`, topicArg},
	{"/v1/shift-hours-by-enterprise", `SELECT * FROM piot_get_shift_hours_by_enterprise_packml_topic_2($1, $2)`, topicEnterpriseArg},
	{"/v1/day-week-begin", `SELECT * FROM piot_get_day_week_begin_by_packml_topic($1)`, topicArg},
	{"/v1/operator-po-list", `SELECT * FROM v_operator_po_list_setup_4`, nil},
	{"/v1/operator-po-details", `SELECT * FROM v_operator_po_details_3`, nil},
	{"/v1/operator-entities", `SELECT * FROM v_operator_entities_2`, nil},
	{"/v1/entities-per-user-role", `SELECT * FROM v_entities_per_user_role_operator`, nil},
	{"/v1/language-packs", `SELECT * FROM language_packs`, nil},
	{"/v1/downtime-reasons", `SELECT e.id_equipment, e.downtime_reasons, e.scrap_reasons, p.packml_topic
	   FROM equipments e JOIN packml_register p ON p.id_equipment = e.id_equipment AND p.id_unit = e.id_equipment
	  WHERE p.packml_topic = ANY($1) AND p.active`, topicsArg},
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
	if err := http.ListenAndServe(":"+port, mux); err != nil {
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
		if ep.args != nil {
			var err error
			if args, err = ep.args(r); err != nil {
				failed.Add(1)
				http.Error(w, `{"error":`+strconv.Quote(err.Error())+`}`, http.StatusBadRequest)
				return
			}
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
