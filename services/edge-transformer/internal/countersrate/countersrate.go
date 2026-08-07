// Package countersrate builds the counters-only OEE rated-speed map from the
// DB at boot — the config-as-data replacement (ADR-0045 G4/G5) for the
// hand-built COUNTERS_ONLY_IDEAL_RATES compose env map.
//
// Why this exists: a counter-only edge (e.g. CPACK) has NO physical MachSpeed
// sensor, so the Calc Phase-8 glitch guard `prodSpeed < 3*machSpeed` collapses
// to `prodSpeed < 0` and drops EVERY counter unless counters-only mode supplies
// a rated speed per unit topic (see internal/config Config.CountersOnlyIdealRates).
// The interim seam was a hand-maintained JSON env map — incomplete by
// construction (18 of 42 CPACK machines), so producing machines missing from it
// (L10/DXL, L6/TEXA, SLEEVE2) got silently dropped (G5). Every machine already
// carries its rated speed as equipments.production_speed (parts/min, set by CS
// Admin at onboarding), so the durable fix is to source the map from the DB.
//
// The map KEY must be the SAME unit-topic string the decoder's Calc uses to look
// up the rate at runtime — see calc_production_counters.parseTopicFull. This
// package's deriveUnitTopic mirrors that rule exactly (proven by a test that
// diffs against ParseTopic), so a DB-built key always matches the live lookup.
package countersrate

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// bootQueryTimeout bounds the whole boot-time DB round trip so an unreachable or
// slow DB can never wedge decoder startup — the caller fails open to the env map.
const bootQueryTimeout = 10 * time.Second

// ratesQuery selects, per counter-equipment of every counters-only tenant, the
// canonical (shortest) active packml_topic and its configured rated speed.
//
//   - client_descriptors.descriptor->>'counters_only_oee' = 'true' picks the
//     opted-in tenants (the CS-Admin descriptor toggle). id_enterprise scopes
//     the equipment join, so one tenant can never pull another's rows.
//   - tp_equipment = 1 (machines only) + production_speed > 0 is the exact
//     opt-in the env map encoded by hand, now derived from data.
//   - DISTINCT ON (id_equipment) ORDER BY length(packml_topic) ASC picks the
//     SHORTEST topic per equipment — the equipment-level canonical entry, i.e.
//     the unit topic — discarding per-metric rows (".../Admin/…", ".../Status/…").
//     This is the same deterministic tie-break register_pg.go uses after a prod
//     incident where a non-deterministic LIMIT 1 grabbed a corrupted long topic.
//
// deriveUnitTopic is still applied to the result in Go: it is idempotent on an
// already-canonical topic and strips the leaves if only per-metric rows exist,
// so the key matches parseTopicFull regardless of what packml_register holds.
const ratesQuery = `
	SELECT DISTINCT ON (e.id_equipment)
	       cd.id_enterprise, pr.packml_topic, e.production_speed
	  FROM client_descriptors cd
	  JOIN sites s            ON s.id_enterprise   = cd.id_enterprise
	  JOIN areas a            ON a.id_site         = s.id_site
	  JOIN equipments e       ON e.id_area         = a.id_area
	  JOIN packml_register pr ON pr.id_equipment   = e.id_equipment
	 WHERE cd.descriptor->>'counters_only_oee' = 'true'
	   AND e.tp_equipment = 1
	   AND e.production_speed > 0
	   AND pr.active
	   AND pr.id_equipment IS NOT NULL
	 ORDER BY e.id_equipment,
	          length(pr.packml_topic) ASC,
	          pr.id_packml_register ASC
`

// Result is the boot-time DB rate load: the unit-topic→rated-speed map plus the
// distinct tenant count, for the startup summary log.
type Result struct {
	Rates   map[string]float64 // unit topic → production_speed (parts/min)
	Tenants int                // distinct counters-only enterprises contributing
}

// LoadDBRates opens its OWN short-lived pool (the decoder holds no DB pool
// otherwise), queries the counters-only rates, and closes the pool before
// returning. Any error is returned for the caller to fail open on — this
// function never crashes the process. The whole round trip is timeout-bounded.
func LoadDBRates(ctx context.Context, logger *slog.Logger) (*Result, error) {
	dsn, err := buildDSN()
	if err != nil {
		return nil, err
	}
	qctx, cancel := context.WithTimeout(ctx, bootQueryTimeout)
	defer cancel()

	pool, err := pgxpool.New(qctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("counters-only: open pool: %w", err)
	}
	defer pool.Close()
	if err := pool.Ping(qctx); err != nil {
		return nil, fmt.Errorf("counters-only: db ping: %w", err)
	}
	return FetchRates(qctx, pool)
}

// FetchRates runs the rates query against an existing pool and folds the rows
// into a unit-topic→rate map. Split out from LoadDBRates so tests can drive it
// with a pool directly.
func FetchRates(ctx context.Context, pool *pgxpool.Pool) (*Result, error) {
	rows, err := pool.Query(ctx, ratesQuery)
	if err != nil {
		return nil, fmt.Errorf("counters-only: query rates: %w", err)
	}
	defer rows.Close()

	rates := map[string]float64{}
	tenants := map[int]struct{}{}
	for rows.Next() {
		var (
			enterpriseID int
			topic        string
			speed        float64
		)
		if err := rows.Scan(&enterpriseID, &topic, &speed); err != nil {
			return nil, fmt.Errorf("counters-only: scan rate row: %w", err)
		}
		unit := deriveUnitTopic(topic)
		if unit == "" || speed <= 0 {
			continue
		}
		rates[unit] = speed
		tenants[enterpriseID] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("counters-only: iterate rate rows: %w", err)
	}
	return &Result{Rates: rates, Tenants: len(tenants)}, nil
}

// Merge folds env rates on top of DB rates — ENV WINS on a key collision, so a
// hand override in COUNTERS_ONLY_IDEAL_RATES still takes precedence over the
// DB-derived speed. Returns a fresh map (never mutates the inputs).
func Merge(dbRates, envRates map[string]float64) map[string]float64 {
	out := make(map[string]float64, len(dbRates)+len(envRates))
	for k, v := range dbRates {
		out[k] = v
	}
	for k, v := range envRates {
		out[k] = v
	}
	return out
}

// deriveUnitTopic maps a Sparkplug counter/equipment topic to the unit-topic key
// the decoder's Calc uses at runtime. It MUST match
// calc_production_counters.parseTopicFull's unit-topic rule (proven by test):
//
//   - normal equipment → Enterprise/Site/Area/Line/Unit (first 5 segments)
//   - a LINE own-stream (segment index 4 is a PackML process keyword
//     Admin/Status/Command) has NO Unit segment → first 4 segments
//
// It also accepts an already-canonical topic (no per-metric leaves): the 5-part
// case returns itself, so the function is idempotent — safe to run on either the
// equipment-level packml_topic or a full per-metric topic. A stray "***" trigger
// suffix (defensive) is stripped first.
func deriveUnitTopic(topic string) string {
	if i := strings.Index(topic, "***"); i >= 0 {
		topic = topic[:i]
	}
	topic = strings.Trim(topic, "/")
	if topic == "" {
		return ""
	}
	parts := strings.Split(topic, "/")
	if len(parts) < 5 {
		// Already canonical (a 4-seg line topic, or a short equipment topic) —
		// nothing to strip.
		return strings.Join(parts, "/")
	}
	switch strings.ToLower(parts[4]) {
	case "admin", "status", "command":
		return strings.Join(parts[:4], "/") // line own-stream — no Unit segment
	default:
		return strings.Join(parts[:5], "/") // Enterprise/Site/Area/Line/Unit
	}
}

// buildDSN assembles the postgres DSN. COUNTERS_ONLY_DSN wins if set (a full
// URL); otherwise it is built from the POSTGRES_* env the sibling decode
// services (oeecloud-worker) already use — POSTGRES_HOST falls back to
// POSTGRES_HOST_UPSTREAM (the .env key that carries the r7g host in prod).
func buildDSN() (string, error) {
	if v := os.Getenv("COUNTERS_ONLY_DSN"); v != "" {
		return v, nil
	}
	user := os.Getenv("POSTGRES_USER")
	pass := os.Getenv("POSTGRES_PASSWORD")
	host := getenv("POSTGRES_HOST", os.Getenv("POSTGRES_HOST_UPSTREAM"))
	if user == "" || pass == "" || host == "" {
		return "", fmt.Errorf("counters-only DB load needs COUNTERS_ONLY_DSN or POSTGRES_USER+POSTGRES_PASSWORD+POSTGRES_HOST")
	}
	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(user, pass),
		Host:   fmt.Sprintf("%s:%s", host, getenv("POSTGRES_PORT", "5432")),
		Path:   "/" + getenv("POSTGRES_DB", "packiot"),
	}
	q := u.Query()
	q.Set("sslmode", getenv("POSTGRES_SSLMODE", "disable"))
	q.Set("application_name", "edge-transformer-counters-only")
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func getenv(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
