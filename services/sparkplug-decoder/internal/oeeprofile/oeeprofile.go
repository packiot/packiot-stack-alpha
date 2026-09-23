// Package oeeprofile serves the per-client OEE computation profile to the
// decoder as config-as-data — the WS3 / ADR-0058 durable home for the fact that
// different clients compute OEE differently. It is the sibling of internal/
// countersrate: same shape (a boot-load + periodic Watcher over a small
// client_descriptors-derived map, fail-open on any DB error), but it carries the
// OEE-profile knobs the decoder consumes rather than the rated-speed map.
//
// Phase 1 surfaces exactly ONE knob — spike_margin (the WS1 counter-anomaly
// gross guard's per-client margin). Today that margin was a single global env
// value (CALC_COUNTER_SPIKE_MARGIN); a client that runs a canning line at
// ~100/min and a pharma blister line at ~600/min needs different plausibility
// bounds, and CS Admin must be able to edit them without a code change. This
// package reads the margin a CS engineer authored in the customize SPA
// (client_descriptors.descriptor->'oee_profile'->>'spike_margin', a JSONB row
// keyed by id_enterprise) and hands the decoder a unit-topic→margin map. The
// caller overlays it on the env default: profile value wins per topic, env is
// the fallback, absent ⇒ the WS1 env behavior byte-for-byte (parity).
//
// The map KEY is the SAME unit-topic string the decoder's Calc looks up at
// runtime (calc_production_counters.ParseTopic). deriveUnitTopic mirrors that
// rule exactly — reused from the countersrate derivation contract — so a
// DB-built key always matches the live per-message lookup.
package oeeprofile

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
// slow DB can never wedge decoder startup — the caller fails open to the env
// default margin. Same budget countersrate uses.
const bootQueryTimeout = 10 * time.Second

// DefaultRefreshInterval matches countersrate's — 5 minutes, the "a CS Admin
// edit takes effect without an edge redeploy" cadence.
const DefaultRefreshInterval = 5 * time.Minute

// marginsQuery selects, per counter-equipment of every tenant whose descriptor
// carries a positive oee_profile.spike_margin, the canonical (shortest) active
// packml_topic and that tenant's configured margin.
//
//   - descriptor->'oee_profile'->>'spike_margin' IS NOT NULL AND > 0 picks the
//     opted-in tenants; a tenant without the profile (the default) contributes
//     no rows, so the map stays empty and the env default governs (parity).
//   - id_enterprise scopes the equipment join, so one tenant can never pull
//     another's rows (the same cross-tenant guard countersrate.ratesQuery uses).
//   - tp_equipment IN (1,3): the guard runs on machines AND lines, because the
//     eq47/L5 counter-anomaly it fixes lands on the line's own counter stream
//     as well as its members (unlike the rated-speed map, which is machines-only).
//   - DISTINCT ON (id_equipment) ORDER BY length(packml_topic) ASC picks the
//     SHORTEST topic per equipment (the unit topic), the deterministic tie-break
//     register_pg.go standardized on after a prod incident with a non-deterministic
//     LIMIT 1. deriveUnitTopic is still applied in Go so the key matches Calc
//     regardless of what packml_register holds.
const marginsQuery = `
	SELECT DISTINCT ON (e.id_equipment)
	       cd.id_enterprise,
	       pr.packml_topic,
	       (cd.descriptor->'oee_profile'->>'spike_margin')::float8 AS spike_margin
	  FROM client_descriptors cd
	  JOIN sites s            ON s.id_enterprise = cd.id_enterprise
	  JOIN areas a            ON a.id_site       = s.id_site
	  JOIN equipments e       ON e.id_area       = a.id_area
	  JOIN packml_register pr ON pr.id_equipment = e.id_equipment
	 WHERE cd.descriptor->'oee_profile'->>'spike_margin' IS NOT NULL
	   AND (cd.descriptor->'oee_profile'->>'spike_margin')::float8 > 0
	   AND pr.active
	   AND pr.id_equipment IS NOT NULL
	 ORDER BY e.id_equipment,
	          length(pr.packml_topic) ASC,
	          pr.id_packml_register ASC
`

// Result is the boot-time DB load: the unit-topic→spike-margin map plus the
// distinct tenant count, for the startup summary log.
type Result struct {
	Margins map[string]float64 // unit topic → oee_profile.spike_margin
	Tenants int                // distinct enterprises that authored a margin
}

// LoadDBMargins opens its OWN short-lived pool (the decoder holds no DB pool),
// queries the profile margins, and closes the pool before returning. Any error
// is returned for the caller to fail open on — this function never crashes the
// process. The whole round trip is timeout-bounded.
func LoadDBMargins(ctx context.Context, logger *slog.Logger) (*Result, error) {
	dsn, err := buildDSN()
	if err != nil {
		return nil, err
	}
	qctx, cancel := context.WithTimeout(ctx, bootQueryTimeout)
	defer cancel()

	pool, err := pgxpool.New(qctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("oee-profile: open pool: %w", err)
	}
	defer pool.Close()
	if err := pool.Ping(qctx); err != nil {
		return nil, fmt.Errorf("oee-profile: db ping: %w", err)
	}
	return FetchMargins(qctx, pool)
}

// FetchMargins runs the margins query against an existing pool and folds the
// rows into a unit-topic→margin map. Split out from LoadDBMargins so tests can
// drive it with a pool directly.
func FetchMargins(ctx context.Context, pool *pgxpool.Pool) (*Result, error) {
	rows, err := pool.Query(ctx, marginsQuery)
	if err != nil {
		return nil, fmt.Errorf("oee-profile: query margins: %w", err)
	}
	defer rows.Close()

	margins := map[string]float64{}
	tenants := map[int]struct{}{}
	for rows.Next() {
		var (
			enterpriseID int
			topic        string
			margin       float64
		)
		if err := rows.Scan(&enterpriseID, &topic, &margin); err != nil {
			return nil, fmt.Errorf("oee-profile: scan margin row: %w", err)
		}
		unit := deriveUnitTopic(topic)
		if unit == "" || margin <= 0 {
			continue
		}
		margins[unit] = margin
		tenants[enterpriseID] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("oee-profile: iterate margin rows: %w", err)
	}
	return &Result{Margins: margins, Tenants: len(tenants)}, nil
}

// deriveUnitTopic maps a Sparkplug counter/equipment topic to the unit-topic key
// the decoder's Calc uses at runtime — identical rule to
// countersrate.deriveUnitTopic (and calc_production_counters.parseTopicFull):
//
//   - normal equipment → Enterprise/Site/Area/Line/Unit (first 5 segments)
//   - a LINE own-stream (segment index 4 is a PackML keyword Admin/Status/Command)
//     has NO Unit segment → first 4 segments
//
// Idempotent on an already-canonical topic; a stray "***" trigger suffix is
// stripped first.
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
		return strings.Join(parts, "/")
	}
	switch strings.ToLower(parts[4]) {
	case "admin", "status", "command":
		return strings.Join(parts[:4], "/")
	default:
		return strings.Join(parts[:5], "/")
	}
}

// buildDSN assembles the postgres DSN. OEE_PROFILE_DSN wins if set (a full URL);
// otherwise it is built from the POSTGRES_* env the sibling decode services
// already use — POSTGRES_HOST falls back to POSTGRES_HOST_UPSTREAM.
func buildDSN() (string, error) {
	if v := os.Getenv("OEE_PROFILE_DSN"); v != "" {
		return v, nil
	}
	if v := os.Getenv("COUNTERS_ONLY_DSN"); v != "" {
		return v, nil // reuse the sibling loader's DSN when present
	}
	user := os.Getenv("POSTGRES_USER")
	pass := os.Getenv("POSTGRES_PASSWORD")
	host := getenv("POSTGRES_HOST", os.Getenv("POSTGRES_HOST_UPSTREAM"))
	if user == "" || pass == "" || host == "" {
		return "", fmt.Errorf("oee-profile DB load needs OEE_PROFILE_DSN or POSTGRES_USER+POSTGRES_PASSWORD+POSTGRES_HOST")
	}
	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(user, pass),
		Host:   fmt.Sprintf("%s:%s", host, getenv("POSTGRES_PORT", "5432")),
		Path:   "/" + getenv("POSTGRES_DB", "packiot"),
	}
	q := u.Query()
	q.Set("sslmode", getenv("POSTGRES_SSLMODE", "disable"))
	q.Set("application_name", "edge-transformer-oee-profile")
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func getenv(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// Watcher periodically reloads the DB margin map so a CS Admin edit to a client's
// OEE profile takes effect without an edge redeploy — the same config-as-data
// cadence countersrate.Watcher gives the rated-speed map.
//
// Fail-open: a reload error logs a warning and keeps serving the previous
// snapshot (an empty map on the very first failure), so a DB hiccup never
// changes the clamp behavior the decoder already depends on — it just leaves the
// env default in force.
type Watcher struct {
	logger   *slog.Logger
	interval time.Duration

	mu      sync.RWMutex
	margins map[string]float64
	tenants int
}

// NewWatcher builds a Watcher. interval<=0 uses DefaultRefreshInterval.
func NewWatcher(interval time.Duration, logger *slog.Logger) *Watcher {
	if logger == nil {
		logger = slog.Default()
	}
	if interval <= 0 {
		interval = DefaultRefreshInterval
	}
	return &Watcher{
		logger:   logger,
		interval: interval,
		margins:  map[string]float64{},
	}
}

// Start performs the initial load synchronously — so the caller's first message
// already sees a warm map when the DB is reachable at boot — then launches a
// background ticker that reloads every interval until ctx is done.
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

// Margins returns the current unit-topic→margin map. Safe to call from any
// goroutine; the returned map must be treated as read-only — reload() always
// builds a fresh map and swaps the field, never mutating a returned map in
// place, so a caller holding an old reference never observes a torn read.
func (w *Watcher) Margins() map[string]float64 {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.margins
}

// Tenants reports the distinct profile-authoring tenant count from the most
// recent successful reload — for boot/health logging, not routing decisions.
func (w *Watcher) Tenants() int {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.tenants
}

func (w *Watcher) reload(ctx context.Context) {
	res, err := LoadDBMargins(ctx, w.logger)
	if err != nil {
		w.logger.Warn("oee-profile margins: periodic DB reload failed — keeping previous snapshot",
			slog.String("err", err.Error()))
		return
	}
	w.mu.Lock()
	w.margins = res.Margins
	w.tenants = res.Tenants
	w.mu.Unlock()
	w.logger.Info("oee-profile margins reloaded from DB",
		slog.Int("tenants", res.Tenants),
		slog.Int("margin_entries", len(res.Margins)),
	)
}
