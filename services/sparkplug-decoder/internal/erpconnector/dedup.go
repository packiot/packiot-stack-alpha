package erpconnector

import "sync"

// SeenSet answers "have I already synced a row with this dedup key?" so a
// write is not re-sent. It is the declarative-dedup mechanism that replaces
// Incoplast's ad-hoc `differences`/rbe Node-RED nodes: the descriptor names
// a `dedup_key`, and the connector consults this set keyed by that column's
// value before every write.
//
// It is an interface on purpose. The shipped implementation (memSeenSet) is
// in-memory and bounded — correct for de-duping same-process re-sends, which
// is the common case (a retry, a re-triggered cadence, a broker
// re-delivery). Its documented limitation: keys do NOT survive a restart, so
// after a crash a row could be re-sent once. The production upgrade for
// cross-restart dedup is a persisted SeenSet backed by a SQLite table —
// exactly the store-and-forward pattern in internal/outbox — which drops in
// behind this interface with no change to connector logic.
type SeenSet interface {
	// MarkIfNew records key and returns true if it was NEW (proceed with the
	// write). It returns false if key was already present (a duplicate — skip
	// the write). Implementations must be safe for concurrent use.
	MarkIfNew(key string) bool
}

// memSeenSet is a bounded, goroutine-safe key set with FIFO eviction —
// the same shape as command.dedupStore (ADR-0009 reuse rule: do not
// re-invent a pattern that already exists in the service). Bounding caps
// memory on a long-running edge box; FIFO is sufficient because the risk is
// a re-send of a RECENT row (a retry or re-triggered cadence), which a
// recency-ordered bound covers.
type memSeenSet struct {
	mu    sync.Mutex
	cap   int
	seen  map[string]struct{}
	order []string // insertion order, for eviction of the oldest key
}

// NewMemSeenSet returns an in-memory SeenSet bounded to capacity keys
// (defaulting to 8192 when capacity <= 0).
func NewMemSeenSet(capacity int) SeenSet {
	if capacity <= 0 {
		capacity = 8192
	}
	return &memSeenSet{
		cap:   capacity,
		seen:  make(map[string]struct{}, capacity),
		order: make([]string, 0, capacity),
	}
}

func (d *memSeenSet) MarkIfNew(key string) bool {
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
