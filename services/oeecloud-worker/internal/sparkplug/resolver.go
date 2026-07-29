package sparkplug

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// EquipmentInfo holds everything writers need to identify the row to write.
// Pulled from packml_register × areas join exactly like the Prep node's
// SELECT, so writers don't need to JOIN again per metric.
type EquipmentInfo struct {
	IDEnterprise  int
	IDSite        int
	IDArea        int
	IDEquipment   int
	SignalQuality *int
	DayBegin      *int // areas.day_begin (used by shift trigger downstream)
	// StatusType is equipments.status_type. Only status_type=4 equipment
	// report StateCurrent that the events deriver (ADR-0014 P3a) converts to
	// interval events; BuildEventMint gates on it so it never mints raw
	// per-sample events for equipment the deriver won't clean (0 = absent).
	StatusType int
	// ProductionSpeed is equipments.production_speed — the machine's CONFIGURED
	// rated speed in parts/min (same field the rollup uses as ideal_speed and
	// the counters-only guard uses). nil ⇒ NULL/unset. Used ONLY by the
	// increment sanity clamp (ADR-0037 Silver invariant) as the rated-rate
	// bound for a plausible per-sample production increment; a nil/0 value
	// makes the clamp fail-open for that equipment (no rated speed to bound
	// against). It never feeds an emitted value.
	ProductionSpeed *int
}

// Resolver maps packml_topic → EquipmentInfo. Memoised in-process —
// packml_register changes infrequently (only on CS Admin equipment edits),
// so a TTL refresh of a few minutes keeps cache hit rate close to 100%
// while still picking up new equipments without a worker restart.
//
// Cache key is the topic string (post-canonicalisation). Negative results
// (topic not in packml_register) are cached briefly too — otherwise a
// chatty unknown topic would hammer the DB.
//
// Bounded at maxCacheEntries to defend against a misbehaving publisher
// flooding unique topic names (which would otherwise grow the negative
// cache unboundedly). When over, all entries are dropped — coarse but
// O(n) only on the overflow event. CPACK has ~100 real topics so this
// effectively never fires in normal operation.
type Resolver struct {
	pool   *pgxpool.Pool
	ttl    time.Duration
	negTTL time.Duration
	maxN   int
	mu     sync.RWMutex
	cache  map[string]cacheEntry
}

type cacheEntry struct {
	info    *EquipmentInfo // nil for negative cache
	expires time.Time
}

// maxCacheEntries caps the in-memory resolver cache. ~100× the real CPACK
// topic count is the defensive ceiling — high enough that legit growth
// (new equipment onboarding) never trips it; low enough that a runaway
// publisher can't OOM the worker.
const maxCacheEntries = 10_000

func NewResolver(pool *pgxpool.Pool, ttl, negTTL time.Duration) *Resolver {
	return &Resolver{
		pool:   pool,
		ttl:    ttl,
		negTTL: negTTL,
		maxN:   maxCacheEntries,
		cache:  make(map[string]cacheEntry),
	}
}

// Resolve looks up the EquipmentInfo for a packml_topic. Returns
// (nil, nil) when the topic isn't registered — writers should log + skip
// rather than nack (a missing register row won't appear via retry).
func (r *Resolver) Resolve(ctx context.Context, topic string) (*EquipmentInfo, error) {
	r.mu.RLock()
	if e, ok := r.cache[topic]; ok && time.Now().Before(e.expires) {
		r.mu.RUnlock()
		return e.info, nil
	}
	r.mu.RUnlock()

	// Miss or expired — query packml_register × areas.
	info, err := r.query(ctx, topic)
	if err != nil {
		return nil, fmt.Errorf("resolve %s: %w", topic, err)
	}

	r.mu.Lock()
	// Bounded-cache: drop everything if we're over the cap before adding
	// the new entry. CPACK has ~100 real topics so this branch effectively
	// never fires; the defense is against a publisher flooding unique
	// names (worst case = re-warm the cache from scratch).
	if len(r.cache) >= r.maxN {
		r.cache = make(map[string]cacheEntry, r.maxN)
	}
	if info == nil {
		r.cache[topic] = cacheEntry{info: nil, expires: time.Now().Add(r.negTTL)}
	} else {
		r.cache[topic] = cacheEntry{info: info, expires: time.Now().Add(r.ttl)}
	}
	r.mu.Unlock()

	return info, nil
}

func (r *Resolver) query(ctx context.Context, topic string) (*EquipmentInfo, error) {
	const q = `
		SELECT pr.id_enterprise, pr.id_site, pr.id_area, pr.id_equipment,
		       pr.signal_quality, a.day_begin, COALESCE(e.status_type, 0),
		       e.production_speed
		  FROM packml_register pr
		  JOIN areas a ON a.id_area = pr.id_area
		  LEFT JOIN equipments e ON e.id_equipment = pr.id_equipment
		 WHERE pr.packml_topic = $1
		   AND pr.active = true
		 LIMIT 1
	`
	row := r.pool.QueryRow(ctx, q, topic)
	var info EquipmentInfo
	err := row.Scan(&info.IDEnterprise, &info.IDSite, &info.IDArea,
		&info.IDEquipment, &info.SignalQuality, &info.DayBegin, &info.StatusType,
		&info.ProductionSpeed)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &info, nil
}

// Stats returns cache size — for /health observability later.
func (r *Resolver) Size() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.cache)
}
