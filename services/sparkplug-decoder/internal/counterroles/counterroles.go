// Package counterroles is the DB-backed counter-role resolver for ADR-0047
// P0 #1 (docs/adr/reference/adr-0047-config-surface-spec.md §1) — the
// packml_register.id_infeedcounter / id_outfeedcounter / id_rejectcounter
// columns already exist in schema but are unread by the calc engine today.
//
// The contract this package adopts (no prior consumer defines one — a grep
// of edge-api + csadmin turns up zero reads of these three columns): on a
// packml_register row belonging to equipment E (almost always a
// tp_equipment=3 LINE), a populated id_infeedcounter/outfeedcounter/
// rejectcounter names the id_equipment of ANOTHER machine whose SparkPlug
// counter stream plays E's infeed(gross)/outfeed(net)/reject(scrap) role —
// the same "split-instrumentation" shape equipments.gross_machine/
// scrap_machine already model at the rollup layer (services/stream-engine/
// internal/rollup/line_lead.go), but at the topic-routing layer instead, and
// resolved BEFORE the calc engine's own Prod*Count substring convention gets
// a chance to (mis)classify or drop the metric entirely. See
// docs/clients/bispharma-oee-mapping-fix.md (counter168/169, no Prod*Count
// naming at all) and docs/clients/cpack-counter-semantics-audit.md
// (split-instrumentation: gross on one machine, net on another) for the two
// real-client shapes this closes.
//
// Caching. Bulk-loaded (one query covers every tenant) rather than a
// per-message DB round trip, then refreshed on a ticker — mirrors
// internal/countersrate's boot-load shape but adds the periodic-refresh leg
// that seam was missing, so a CS Admin edit to packml_register's role
// columns takes effect within one TTL window (default 5 minutes, matching
// oeecloud-worker's shift resolver cache) instead of requiring an edge
// redeploy. See internal/refdataresolver for this service's OTHER caching
// pattern (lazy per-key TTL over HTTP) — bulk-reload suits this seam better
// because the whole role table is small (only rows with a non-NULL role
// column) and one query is cheap, same reasoning as countersrate.
//
// Fail-open by design: a query error at boot or on refresh logs a warning
// and keeps serving the previous snapshot (empty on the very first failure)
// — a DB hiccup here must never crash decode or block a message; the
// resolver is enrichment, never a hard dependency (mirrors countersrate's
// LoadDBRates contract).
package counterroles

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	calc "github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/transforms/calc_production_counters"
)

// DefaultTTL is the periodic-refresh interval when the caller doesn't
// override it — matches oeecloud-worker's shift resolver 5-min cache window
// (the task's own stated reference point for "config change without
// redeploy").
const DefaultTTL = 5 * time.Minute

// bootQueryTimeout bounds a single refresh round trip so an unreachable or
// slow DB can never wedge the ticker goroutine or (on the FIRST load) decoder
// startup.
const bootQueryTimeout = 10 * time.Second

// Binding is one resolved role: the counter arriving on a SOURCE equipment's
// canonical unit topic should be attributed to LineUnitTopic's Role counter.
type Binding struct {
	LineUnitTopic string
	Role          calc.CounterKind
}

// Resolver serves Resolve() from an in-memory snapshot refreshed on a timer.
// Safe for concurrent use. The zero value is not usable — construct with New.
type Resolver struct {
	logger *slog.Logger
	ttl    time.Duration
	dsn    string

	mu sync.RWMutex
	m  map[string]Binding
}

// New builds a Resolver. It never fails at construction time — a missing DSN
// or unreachable DB surfaces as empty Resolve() results (logged), never a
// boot crash, matching countersrate's fail-open contract.
func New(logger *slog.Logger, ttl time.Duration) *Resolver {
	if logger == nil {
		logger = slog.Default()
	}
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	return &Resolver{logger: logger, ttl: ttl, m: map[string]Binding{}}
}

// NewStatic builds a Resolver pre-seeded with a fixed binding map and no DB
// backing — Start() is never required (calling it is safe but a no-op-ish
// refresh attempt that will fail-open and leave the static map alone, since
// buildDSN errors when no POSTGRES_*/COUNTER_ROLES_DSN env is set in a test
// process). Exists for tests and any future caller that wants to inject a
// fixed role map without a live DB (mirrors the BirthBoundDeviceMap static
// seam in config.go).
func NewStatic(m map[string]Binding) *Resolver {
	if m == nil {
		m = map[string]Binding{}
	}
	return &Resolver{logger: slog.Default(), ttl: DefaultTTL, m: m}
}

// Resolve looks up a role binding for a SOURCE metric's canonical unit topic
// (calc_production_counters.DeriveUnitTopic — callers must derive with THAT
// function, not a hand-rolled split, or the key silently goes dead). Returns
// ok=false when no packml_register row currently declares this equipment as
// an infeed/outfeed/reject source for any line — the overwhelming common
// case (the columns are NULL for virtually every tenant today), which is the
// backward-compatible no-op the ADR-0047 contract requires.
func (r *Resolver) Resolve(sourceUnitTopic string) (kind calc.CounterKind, lineUnitTopic string, ok bool) {
	if sourceUnitTopic == "" {
		return calc.CounterKindUnknown, "", false
	}
	r.mu.RLock()
	b, present := r.m[sourceUnitTopic]
	r.mu.RUnlock()
	if !present {
		return calc.CounterKindUnknown, "", false
	}
	return b.Role, b.LineUnitTopic, true
}

// Start performs the initial load synchronously (so the first message the
// caller processes already sees a warm cache when the DB is reachable), then
// launches a background ticker that reloads every ttl until ctx is done.
func (r *Resolver) Start(ctx context.Context) {
	r.refresh(ctx)
	go func() {
		ticker := time.NewTicker(r.ttl)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.refresh(ctx)
			}
		}
	}()
}

// Len reports the current binding count — for boot/refresh log lines and
// tests; not used for routing decisions.
func (r *Resolver) Len() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.m)
}

func (r *Resolver) refresh(ctx context.Context) {
	dsn, err := r.buildDSN()
	if err != nil {
		r.logger.Warn("counterroles: refresh skipped — no DSN configured", slog.String("err", err.Error()))
		return
	}
	qctx, cancel := context.WithTimeout(ctx, bootQueryTimeout)
	defer cancel()

	pool, err := pgxpool.New(qctx, dsn)
	if err != nil {
		r.logger.Warn("counterroles: refresh failed — open pool", slog.String("err", err.Error()))
		return
	}
	defer pool.Close()
	if err := pool.Ping(qctx); err != nil {
		r.logger.Warn("counterroles: refresh failed — db ping", slog.String("err", err.Error()))
		return
	}

	rows, err := fetchRoleRows(qctx, pool)
	if err != nil {
		r.logger.Warn("counterroles: refresh failed — query", slog.String("err", err.Error()))
		return
	}
	next := buildBindings(rows)

	r.mu.Lock()
	r.m = next
	r.mu.Unlock()
	r.logger.Info("counterroles: refreshed", slog.Int("bindings", len(next)))
}

// roleRow is one raw result row: a source equipment's canonical topic bound
// to a line's canonical topic under a given role.
type roleRow struct {
	LineTopic   string
	SourceTopic string
	Role        int
}

// rolesQuery resolves, for every packml_register row that declares an
// infeed/outfeed/reject counter, the CANONICAL (shortest active) topic of
// both the owning ("line") equipment and the referenced source equipment —
// the counter-role columns may be set on ANY row belonging to an equipment
// (including a long per-metric row), so both sides are re-resolved to their
// shortest active packml_topic via the same DISTINCT-ON tie-break
// internal/countersrate and register_pg.go already use (deterministic:
// shortest topic, then lowest id_packml_register — after the prod incident
// where a non-deterministic LIMIT 1 grabbed a corrupted long topic).
//
// role: 1=infeed(gross/Consumed) 2=outfeed(net/Processed) 3=reject(scrap/Defective).
const rolesQuery = `
	WITH canonical AS (
		SELECT DISTINCT ON (id_equipment)
		       id_equipment, packml_topic
		  FROM packml_register
		 WHERE active AND id_equipment IS NOT NULL AND packml_topic IS NOT NULL
		 ORDER BY id_equipment, length(packml_topic) ASC, id_packml_register ASC
	),
	roles AS (
		SELECT DISTINCT id_equipment, id_infeedcounter, id_outfeedcounter, id_rejectcounter
		  FROM packml_register
		 WHERE active
		   AND id_equipment IS NOT NULL
		   AND (id_infeedcounter IS NOT NULL OR id_outfeedcounter IS NOT NULL OR id_rejectcounter IS NOT NULL)
	)
	SELECT line.packml_topic AS line_topic, src.packml_topic AS source_topic, 1 AS role
	  FROM roles r
	  JOIN canonical line ON line.id_equipment = r.id_equipment
	  JOIN canonical src  ON src.id_equipment  = r.id_infeedcounter
	UNION ALL
	SELECT line.packml_topic, src.packml_topic, 2
	  FROM roles r
	  JOIN canonical line ON line.id_equipment = r.id_equipment
	  JOIN canonical src  ON src.id_equipment  = r.id_outfeedcounter
	UNION ALL
	SELECT line.packml_topic, src.packml_topic, 3
	  FROM roles r
	  JOIN canonical line ON line.id_equipment = r.id_equipment
	  JOIN canonical src  ON src.id_equipment  = r.id_rejectcounter
`

// fetchRoleRows runs rolesQuery against an existing pool. Split out from
// refresh so a test can drive it directly (mirrors countersrate.FetchRates).
func fetchRoleRows(ctx context.Context, pool *pgxpool.Pool) ([]roleRow, error) {
	rows, err := pool.Query(ctx, rolesQuery)
	if err != nil {
		return nil, fmt.Errorf("counterroles: query roles: %w", err)
	}
	defer rows.Close()

	var out []roleRow
	for rows.Next() {
		var rr roleRow
		if err := rows.Scan(&rr.LineTopic, &rr.SourceTopic, &rr.Role); err != nil {
			return nil, fmt.Errorf("counterroles: scan role row: %w", err)
		}
		out = append(out, rr)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("counterroles: iterate role rows: %w", err)
	}
	return out, nil
}

// buildBindings is the pure fold from raw rows to the Resolve() lookup map —
// separated out so it is unit-testable without a live DB (mirrors
// countersrate's split between the SQL layer and deriveUnitTopic/Merge).
// Both topics are re-canonicalized through calc.DeriveUnitTopic so the map
// key matches EXACTLY what a live SparkPlug metric's own unit-topic
// derivation produces at Resolve() call time, regardless of what shape the
// SQL's "canonical" topic happens to already be in (idempotent either way).
// A row whose topic fails to derive (e.g. malformed/too-short packml_topic
// data) is skipped rather than producing a bad key.
func buildBindings(rows []roleRow) map[string]Binding {
	out := make(map[string]Binding, len(rows))
	for _, rr := range rows {
		kind := kindFromRole(rr.Role)
		if kind == calc.CounterKindUnknown {
			continue
		}
		lineUnit, lineOK := calc.DeriveUnitTopic(rr.LineTopic)
		srcUnit, srcOK := calc.DeriveUnitTopic(rr.SourceTopic)
		if !lineOK || !srcOK || lineUnit == "" || srcUnit == "" {
			continue
		}
		out[srcUnit] = Binding{LineUnitTopic: lineUnit, Role: kind}
	}
	return out
}

func kindFromRole(role int) calc.CounterKind {
	switch role {
	case 1:
		return calc.CounterKindConsumed // infeed = gross
	case 2:
		return calc.CounterKindProcessed // outfeed = net
	case 3:
		return calc.CounterKindDefective // reject = scrap
	default:
		return calc.CounterKindUnknown
	}
}

// buildDSN assembles the postgres DSN. COUNTER_ROLES_DSN wins if set (a full
// URL); otherwise it is built from the same POSTGRES_* env the sibling
// decode services (and internal/countersrate) use — POSTGRES_HOST falls
// back to POSTGRES_HOST_UPSTREAM (the .env key carrying the r7g host in
// prod). Deliberately duplicated from countersrate.buildDSN rather than
// shared: both resolvers are meant to stay independently constructible
// (no cross-package coupling), matching this service's existing precedent
// of refdataresolver/countersrate each owning their own connection setup.
func (r *Resolver) buildDSN() (string, error) {
	if v := os.Getenv("COUNTER_ROLES_DSN"); v != "" {
		return v, nil
	}
	user := os.Getenv("POSTGRES_USER")
	pass := os.Getenv("POSTGRES_PASSWORD")
	host := getenv("POSTGRES_HOST", os.Getenv("POSTGRES_HOST_UPSTREAM"))
	if user == "" || pass == "" || host == "" {
		return "", fmt.Errorf("counterroles DB load needs COUNTER_ROLES_DSN or POSTGRES_USER+POSTGRES_PASSWORD+POSTGRES_HOST")
	}
	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(user, pass),
		Host:   fmt.Sprintf("%s:%s", host, getenv("POSTGRES_PORT", "5432")),
		Path:   "/" + getenv("POSTGRES_DB", "packiot"),
	}
	q := u.Query()
	q.Set("sslmode", getenv("POSTGRES_SSLMODE", "disable"))
	q.Set("application_name", "sparkplug-decoder-counter-roles")
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func getenv(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
