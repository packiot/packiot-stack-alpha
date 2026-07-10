package adapter

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrUnresolved is the sentinel the handlers translate into an HTTP 422. A
// packml_topic maps to it when it is not registered, not active, cross-tenant,
// or ambiguous — every case where the adapter cannot confidently name the
// staging equipment. Fail closed: a wrong downtime/PO write is worse than a
// rejected one, so anything ambiguous stops here rather than reaching the DB.
var ErrUnresolved = errors.New("packml topic did not resolve to a staging equipment")

// Resolved is the staging identity a packml_topic maps to. These are the
// sequence-assigned enterprise-4 ids edge-api expects — the tee node cannot
// know them (it only holds Incoplast's own production ids + the topic), so the
// adapter resolves them via packml_register exactly like oeecloud-worker does
// for the data path.
type Resolved struct {
	IDEquipment int
	CDMachine   string
	IDArea      int
	IDSite      int
}

// topicResolver is the seam the handlers depend on. The real implementation is
// *PGResolver (Postgres-backed); unit tests inject a fake so they can exercise
// resolve/unresolved/cross-tenant without a live DB.
type topicResolver interface {
	ResolveTopic(ctx context.Context, packmlTopic string) (Resolved, error)
	// Ping reports whether the resolver's backing store is reachable — surfaced
	// on /healthz so the adapter is only "healthy" when it can actually resolve.
	Ping(ctx context.Context) error
}

// PGResolver resolves packml_topic → staging ids against F1 `packiot`. Results
// are memoised in-process: packml_register changes only on CS Admin equipment
// edits, so a short TTL keeps the hit rate near 100% while still picking up new
// equipments without a restart. Negative results are cached briefly too, so a
// chatty unknown topic can't hammer the DB.
type PGResolver struct {
	pool         *pgxpool.Pool
	enterpriseID int // the cross-tenant guard: only topics under this enterprise resolve
	ttl          time.Duration
	negTTL       time.Duration
	maxN         int

	// queryFn is the DB lookup, injectable so unit tests can exercise the
	// caching + unresolved/cross-tenant paths without a live Postgres. It
	// receives the enterprise id so tests can assert the cross-tenant guard is
	// actually forwarded to the query. Defaults to queryEquipment (real SQL).
	queryFn func(ctx context.Context, topic string, enterpriseID int) (Resolved, bool, error)

	mu    sync.RWMutex
	cache map[string]resolveEntry
}

type resolveEntry struct {
	res     Resolved
	ok      bool // false → negative cache (topic did not resolve)
	expires time.Time
}

// maxResolverEntries caps the in-memory cache. Incoplast has ~100 real topics;
// this ceiling is high enough that legit growth never trips it, low enough that
// a runaway caller flooding unique topic names can't OOM the adapter.
const maxResolverEntries = 10_000

// NewPGResolver builds the Postgres-backed resolver. enterpriseID is the tenant
// the adapter is scoped to (Incoplast) — topics whose hierarchy does not sit
// under it are rejected as ErrUnresolved (cross-tenant guard).
func NewPGResolver(pool *pgxpool.Pool, enterpriseID int, ttl, negTTL time.Duration) *PGResolver {
	r := &PGResolver{
		pool:         pool,
		enterpriseID: enterpriseID,
		ttl:          ttl,
		negTTL:       negTTL,
		maxN:         maxResolverEntries,
		cache:        make(map[string]resolveEntry),
	}
	r.queryFn = func(ctx context.Context, topic string, enterpriseID int) (Resolved, bool, error) {
		return queryEquipment(ctx, pool, topic, enterpriseID)
	}
	return r
}

// Ping reports whether the backing pool is reachable. A nil pool (query-fn
// injected in tests) is treated as healthy so the health path stays testable.
func (r *PGResolver) Ping(ctx context.Context) error {
	if r.pool == nil {
		return nil
	}
	return r.pool.Ping(ctx)
}

// ResolveTopic returns the staging identity for a packml_topic, or ErrUnresolved
// when it is unknown / inactive / cross-tenant / ambiguous.
func (r *PGResolver) ResolveTopic(ctx context.Context, packmlTopic string) (Resolved, error) {
	topic := strings.TrimSpace(packmlTopic)
	if topic == "" {
		return Resolved{}, fmt.Errorf("%w: empty packml_topic", ErrUnresolved)
	}

	r.mu.RLock()
	if e, hit := r.cache[topic]; hit && time.Now().Before(e.expires) {
		r.mu.RUnlock()
		if !e.ok {
			return Resolved{}, fmt.Errorf("%w: %q", ErrUnresolved, topic)
		}
		return e.res, nil
	}
	r.mu.RUnlock()

	res, ok, err := r.queryFn(ctx, topic, r.enterpriseID)
	if err != nil {
		// A transport/DB error is NOT ErrUnresolved — surface it so the handler
		// answers 503 (retryable) rather than 422 (permanent) and we don't
		// poison the negative cache with a transient failure.
		return Resolved{}, fmt.Errorf("resolve %q: %w", topic, err)
	}

	r.store(topic, res, ok)
	if !ok {
		return Resolved{}, fmt.Errorf("%w: %q", ErrUnresolved, topic)
	}
	return res, nil
}

// queryEquipment runs the parameterised join. The cross-tenant guard is inline
// in the WHERE clause (s.id_enterprise = $2): a topic that belongs to another
// tenant simply returns no rows, so it can never resolve to the wrong
// enterprise's equipment. `p.active` gates on the CS-Admin activation flag
// oeecloud also honours. LIMIT 2 lets us detect ambiguity (a topic mapped to >1
// active row) and fail closed rather than silently pick one.
//
// Column provenance (verified against edge-api/schema.sql):
//   - equipments has cd_equipment (NOT cd_machine) — that is the equipment code
//     edge-api stores as equipment_events.cd_machine, so it is the CDMachine.
//   - packml_register.id_equipment → equipments.id_equipment → id_area → id_site.
func queryEquipment(ctx context.Context, pool *pgxpool.Pool, topic string, enterpriseID int) (Resolved, bool, error) {
	const q = `
		SELECT e.id_equipment, e.cd_equipment, e.id_area, a.id_site
		  FROM packml_register p
		  JOIN equipments e ON e.id_equipment = p.id_equipment
		  JOIN areas a      ON a.id_area      = e.id_area
		  JOIN sites s      ON s.id_site      = a.id_site
		 WHERE p.packml_topic = $1
		   AND p.active
		   AND s.id_enterprise = $2
		 LIMIT 2
	`
	rows, err := pool.Query(ctx, q, topic, enterpriseID)
	if err != nil {
		return Resolved{}, false, err
	}
	defer rows.Close()

	var (
		res   Resolved
		cd    *string
		count int
	)
	for rows.Next() {
		count++
		if count > 1 {
			// Ambiguous: >1 active packml_register row for this topic under the
			// tenant. Fail closed — we cannot know which equipment was meant.
			return Resolved{}, false, nil
		}
		if err := rows.Scan(&res.IDEquipment, &cd, &res.IDArea, &res.IDSite); err != nil {
			return Resolved{}, false, err
		}
	}
	if err := rows.Err(); err != nil {
		return Resolved{}, false, err
	}
	if count == 0 {
		return Resolved{}, false, nil // unknown / inactive / cross-tenant
	}
	if cd != nil {
		res.CDMachine = *cd
	}
	return res, true, nil
}

func (r *PGResolver) store(topic string, res Resolved, ok bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	// Bounded cache: on overflow drop everything (coarse but O(n) only on the
	// rare overflow event; ~100 real topics means this effectively never fires).
	if len(r.cache) >= r.maxN {
		r.cache = make(map[string]resolveEntry, r.maxN)
	}
	ttl := r.ttl
	if !ok {
		ttl = r.negTTL
	}
	r.cache[topic] = resolveEntry{res: res, ok: ok, expires: time.Now().Add(ttl)}
}

// compile-time assertion: *PGResolver satisfies the handler seam.
var _ topicResolver = (*PGResolver)(nil)
