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
	"sync"
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

// DefaultRefreshInterval is used when the caller passes interval<=0 to
// NewWatcher — 5 minutes, matching oeecloud-worker's shift resolver cache
// window (ADR-0047 P0 #2's own stated reference point for "a CS Admin edit
// takes effect without an edge redeploy").
const DefaultRefreshInterval = 5 * time.Minute

// Watcher periodically reloads the DB rate map so a CS Admin edit to
// equipments.production_speed takes effect without an edge redeploy. The
// original G4/G5 seam (LoadDBRates called once at boot — see main.go) left a
// live edit stuck until the next deploy, which defeats the "CS Admin config
// actually changes OEE math" goal (ADR-0047 P0 #2). This is a bulk reload on
// a ticker rather than a per-key TTL (like internal/refdataresolver) because
// the whole rate table is small and one query is cheap — same reasoning
// LoadDBRates's own doc comment already gives for doing one query per boot.
//
// Fail-open: a reload error logs a warning and keeps serving the previous
// snapshot (the boot snapshot on the very first failure) — a DB hiccup must
// never blank out a live rate map that decode already depends on.
type Watcher struct {
	logger   *slog.Logger
	envRates map[string]float64
	interval time.Duration

	mu      sync.RWMutex
	rates   map[string]float64
	tenants int
}

// NewWatcher builds a Watcher. envRates is merged on top of every DB reload
// (env entries WIN on a key collision — Merge's existing contract, preserved
// so a manual COUNTERS_ONLY_IDEAL_RATES override keeps working exactly as it
// does today). interval<=0 uses DefaultRefreshInterval.
func NewWatcher(envRates map[string]float64, interval time.Duration, logger *slog.Logger) *Watcher {
	if logger == nil {
		logger = slog.Default()
	}
	if interval <= 0 {
		interval = DefaultRefreshInterval
	}
	return &Watcher{
		logger:   logger,
		envRates: envRates,
		interval: interval,
		rates:    map[string]float64{},
	}
}

// Start performs the initial load synchronously — so the caller's first
// message already sees a warm map when the DB is reachable at boot — then
// launches a background ticker that reloads every interval until ctx is
// done.
func (w *Watcher) Start(ctx context.Context) {
	w.reload(ctx)
	go func() {
		ticker := time.NewTicker(w.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				w.reload(ctx)
			}
		}
	}()
}

// Rates returns the current merged (DB ∪ env, env wins) rate map. Safe to
// call from any goroutine; the returned map must be treated as read-only —
// reload() always builds a fresh map via Merge and swaps the field, it never
// mutates a previously-returned map in place, so a caller holding an old
// reference never observes a torn read.
func (w *Watcher) Rates() map[string]float64 {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.rates
}

// Tenants reports the distinct counters-only tenant count from the most
// recent successful reload — for boot/health logging, not routing decisions.
func (w *Watcher) Tenants() int {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.tenants
}

func (w *Watcher) reload(ctx context.Context) {
	res, err := LoadDBRates(ctx, w.logger)
	if err != nil {
		w.logger.Warn("counters-only OEE rates: periodic DB reload failed — keeping previous snapshot",
			slog.String("err", err.Error()))
		return
	}
	merged := Merge(res.Rates, w.envRates)
	w.mu.Lock()
	w.rates = merged
	w.tenants = res.Tenants
	w.mu.Unlock()
	w.logger.Info("counters-only OEE rates reloaded from DB",
		slog.Int("tenants", res.Tenants),
		slog.Int("db_rate_entries", len(res.Rates)),
		slog.Int("env_rate_entries", len(w.envRates)),
		slog.Int("merged_rate_entries", len(merged)),
	)
}
