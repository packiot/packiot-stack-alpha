package command

import "sync"

// dedupStore is a bounded, goroutine-safe set of idempotency keys with FIFO
// eviction. It answers "have I already executed this command?" so a broker
// re-delivery (at-least-once semantics) does NOT re-issue the DCMD — a
// replayed PLC write is a physical action taken twice.
//
// FIFO (not strict LRU) is deliberate and sufficient: the risk we defend
// against is a re-delivery of a RECENT command (retry TTL is 30s), which a
// recency-ordered bound covers. A bounded set also caps memory on a
// long-running edge box. For stronger durability across restarts, the design
// notes an outbox-backed store as the upgrade; the in-memory set is the
// correct MVP for a single-instance factory transformer.
type dedupStore struct {
	mu    sync.Mutex
	cap   int
	seen  map[string]struct{}
	order []string // insertion order, for eviction of the oldest key
}

func newDedupStore(capacity int) *dedupStore {
	if capacity <= 0 {
		capacity = 4096
	}
	return &dedupStore{
		cap:   capacity,
		seen:  make(map[string]struct{}, capacity),
		order: make([]string, 0, capacity),
	}
}

// markIfNew atomically records key. It returns true if the key was NEW (the
// caller should proceed to issue the DCMD) and false if it was already present
// (a duplicate — skip the write). An empty key is treated as always-new here;
// the executor rejects empty keys upstream so they never reach this store.
func (d *dedupStore) markIfNew(key string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, ok := d.seen[key]; ok {
		return false
	}
	d.seen[key] = struct{}{}
	d.order = append(d.order, key)
	if len(d.order) > d.cap {
		oldest := d.order[0]
		d.order = d.order[1:]
		delete(d.seen, oldest)
	}
	return true
}

// has reports whether key was already recorded (test/observability helper).
func (d *dedupStore) has(key string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	_, ok := d.seen[key]
	return ok
}
