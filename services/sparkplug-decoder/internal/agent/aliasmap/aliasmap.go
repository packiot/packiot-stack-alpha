// Package aliasmap is the publisher-side alias ALLOCATOR (ADR-0042 §2.2
// net-new #2). This is the producer mirror of the cloud consumer's
// internal/sparkplug StateStore: where the StateStore RESOLVES alias→name
// from a received BIRTH, this ALLOCATES name→alias to freeze into the
// BIRTH we mint.
//
// The seam matters: today's producers (s7-reader, plc-sim) hardcode a table
// they own; a productized transmission agent must ALLOCATE the map from
// whatever raw tags the connectivity plane emits, and freeze it into
// NBIRTH/DBIRTH. Aliases are stable (same name ⇒ same alias for the process
// lifetime) and monotonic (assigned 1,2,3… in first-seen order). A name that
// has never been allocated returns isNew=true — the agent's signal to force a
// rebirth (ADR-0042 §2.2: "isNew anywhere ⇒ force rebirth"), because the cloud
// StateStore has no alias→name entry for a tag that appeared after the last
// BIRTH.
package aliasmap

import "sync"

// Table is the concurrent-safe name→alias allocator. Zero value is not
// ready — use New.
type Table struct {
	mu     sync.Mutex
	byName map[string]uint64
	next   uint64
}

// New constructs an empty allocator. Alias may be called concurrently.
func New() *Table {
	return &Table{byName: make(map[string]uint64)}
}

// Alias returns the alias for name, allocating a fresh one on first sight.
// isNew is true only on the allocation call — every later call for the same
// name returns the same alias with isNew=false. Aliases start at 1 (0 is
// reserved / falsy) and increase monotonically in first-seen order, so a
// BIRTH built from a stable snapshot is deterministic.
func (t *Table) Alias(name string) (alias uint64, isNew bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if a, ok := t.byName[name]; ok {
		return a, false
	}
	t.next++
	t.byName[name] = t.next
	return t.next, true
}

// Has reports whether name already has an allocated alias WITHOUT allocating
// one. The agent uses this to detect a brand-new tag in an NDATA batch (a tag
// the last BIRTH never froze) so it can rebirth-before-data rather than emit
// an alias the cloud can't resolve.
func (t *Table) Has(name string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	_, ok := t.byName[name]
	return ok
}

// Len returns the number of allocated aliases. Diagnostic only.
func (t *Table) Len() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.byName)
}
