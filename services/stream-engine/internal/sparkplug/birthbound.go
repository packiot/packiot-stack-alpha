package sparkplug

// ADR-0061 P2c — the per-tenant switch from PackML resolution to birth-bound ids.
//
// For a SWITCHED enterprise (BIRTHBOUND_SWITCHED_ENTERPRISES), the decoder's
// stamp is the identity: a stamped counter resolves BY id_equipment
// (ResolveByID — no packml_topic involved) and an UNSTAMPED counter is
// QUARANTINED (skipped + counted, never guessed — D1). Every other metric
// keeps resolving through packml_register. Non-counter metrics (state, speed,
// parameters) are not bound by the decoder yet (their roles are not declared at
// birth), so they stay on the PackML resolver even for a switched tenant.
//
// Writers resolve through ResolveMetric, which honours the per-metric decision
// the handler's pre-pass (ApplyBirthBound) recorded. Rollback = remove the
// enterprise from the switch list (D7, until P5).

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

// BirthBoundOutcome counts one ApplyBirthBound pass (for metrics).
type BirthBoundOutcome struct {
	Bound       int // switched tenant, stamped, resolved by id
	Quarantined int // switched tenant, counter without a usable stamp
}

// isCounter reports whether the leaf is one of the counters the decoder binds.
func isCounter(k MetricKind) bool {
	return k == KindProdConsumedCount || k == KindProdProcessedCount || k == KindProdDefectiveCount
}

// ApplyBirthBound records, per counter metric of p, whether a SWITCHED tenant's
// metric resolves by its stamped id or is quarantined. switched is the set of
// enterprise ids; an empty set is a no-op (every metric keeps the PackML path).
func (r *Resolver) ApplyBirthBound(ctx context.Context, p *Payload, switched map[int]bool) (BirthBoundOutcome, error) {
	var out BirthBoundOutcome
	if len(switched) == 0 || p == nil {
		return out, nil
	}
	ent, hasEnt := p.StampedEnterprise()
	for i := range p.Metrics {
		m := &p.Metrics[i]
		if !isCounter(m.Classify()) {
			continue
		}
		if id, ok := m.StampedEquipment(); ok && hasEnt {
			if !switched[ent] {
				continue
			}
			info, err := r.ResolveByID(ctx, id)
			if err != nil {
				return out, err // DB error → the delivery is retried, like a PackML lookup error
			}
			if info == nil || info.IDEnterprise != ent {
				m.quarantined = true // stamped id unknown / of another tenant: fail closed
				out.Quarantined++
				continue
			}
			m.bound = info
			out.Bound++
			continue
		}
		// Unstamped counter: quarantine it only if it belongs to a switched tenant.
		info, err := r.Resolve(ctx, m.TopicForRegister())
		if err != nil {
			return out, err
		}
		if info != nil && switched[info.IDEnterprise] {
			m.quarantined = true
			out.Quarantined++
		}
	}
	return out, nil
}

// ResolveMetric is what writers call: the birth-bound decision when the
// pre-pass made one, else the PackML lookup. (nil, nil) = skip, exactly like an
// unregistered topic.
func (r *Resolver) ResolveMetric(ctx context.Context, m *Metric) (*EquipmentInfo, error) {
	switch {
	case m.quarantined:
		return nil, nil
	case m.bound != nil:
		return m.bound, nil
	}
	return r.Resolve(ctx, m.TopicForRegister())
}

// ResolveByID resolves an equipment by id (ADR-0061: identity = id_equipment,
// never a topic). Same EquipmentInfo as Resolve; inactive/unknown → (nil, nil).
// signal_quality still lives on the routing row (moves to equipments in P5, D5)
// and is read BY id_equipment here.
func (r *Resolver) ResolveByID(ctx context.Context, id int) (*EquipmentInfo, error) {
	key := "id:" + strconv.Itoa(id)
	r.mu.RLock()
	if e, ok := r.cache[key]; ok && time.Now().Before(e.expires) {
		r.mu.RUnlock()
		return e.info, nil
	}
	r.mu.RUnlock()
	if r.pool == nil {
		return nil, errors.New("resolve by id: no pool")
	}
	const q = `
		SELECT e.id_enterprise, e.id_site, e.id_area, e.id_equipment,
		       (SELECT pr.signal_quality FROM packml_register pr
		         WHERE pr.id_equipment = e.id_equipment AND pr.active LIMIT 1),
		       a.day_begin, COALESCE(e.status_type, 0), e.production_speed
		  FROM equipments e
		  JOIN areas a ON a.id_area = e.id_area
		 WHERE e.id_equipment = $1
		   AND e.active
	`
	var info EquipmentInfo
	err := r.pool.QueryRow(ctx, q, id).Scan(&info.IDEnterprise, &info.IDSite, &info.IDArea,
		&info.IDEquipment, &info.SignalQuality, &info.DayBegin, &info.StatusType, &info.ProductionSpeed)
	var res *EquipmentInfo
	switch {
	case errors.Is(err, pgx.ErrNoRows):
	case err != nil:
		return nil, fmt.Errorf("resolve id_equipment %d: %w", id, err)
	default:
		res = &info
	}
	r.mu.Lock()
	if len(r.cache) >= r.maxN {
		r.cache = make(map[string]cacheEntry, r.maxN)
	}
	ttl := r.ttl
	if res == nil {
		ttl = r.negTTL
	}
	r.cache[key] = cacheEntry{info: res, expires: time.Now().Add(ttl)}
	r.mu.Unlock()
	return res, nil
}

// SeedByIDForTest is SeedForTest for ResolveByID. Test-only.
func (r *Resolver) SeedByIDForTest(id int, info *EquipmentInfo) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cache["id:"+strconv.Itoa(id)] = cacheEntry{info: info, expires: time.Now().Add(24 * time.Hour)}
}
