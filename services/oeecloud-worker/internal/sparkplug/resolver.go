package sparkplug

import (
	"context"
	"fmt"
	"sync"
	"time"

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
}

// Resolver maps packml_topic → EquipmentInfo. Memoised in-process —
// packml_register changes infrequently (only on CS Admin equipment edits),
// so a TTL refresh of a few minutes keeps cache hit rate close to 100%
// while still picking up new equipments without a worker restart.
//
// Cache key is the topic string (post-canonicalisation). Negative results
// (topic not in packml_register) are cached briefly too — otherwise a
// chatty unknown topic would hammer the DB.
type Resolver struct {
	pool      *pgxpool.Pool
	ttl       time.Duration
	negTTL    time.Duration
	mu        sync.RWMutex
	cache     map[string]cacheEntry
}

type cacheEntry struct {
	info     *EquipmentInfo // nil for negative cache
	expires  time.Time
}

func NewResolver(pool *pgxpool.Pool, ttl, negTTL time.Duration) *Resolver {
	return &Resolver{
		pool:   pool,
		ttl:    ttl,
		negTTL: negTTL,
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
		       pr.signal_quality, a.day_begin
		  FROM packml_register pr
		  JOIN areas a ON a.id_area = pr.id_area
		 WHERE pr.packml_topic = $1
		   AND pr.active = true
		 LIMIT 1
	`
	row := r.pool.QueryRow(ctx, q, topic)
	var info EquipmentInfo
	err := row.Scan(&info.IDEnterprise, &info.IDSite, &info.IDArea,
		&info.IDEquipment, &info.SignalQuality, &info.DayBegin)
	if err != nil {
		// pgx.ErrNoRows wraps to a specific error; we treat any scan miss
		// as "not registered" rather than splitting the error path.
		if err.Error() == "no rows in result set" {
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
