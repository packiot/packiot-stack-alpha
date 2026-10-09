// Durable-baseline support (2026-10-09 deploy-loss fix).
//
// WHY: Calc turns cumulative PLC counters into increments by differencing each
// reading against the per-topic baseline held in State. The production State is
// an in-process memState, so a decoder restart (every staging deploy rebuilds
// it) wipes every baseline. The first reading after the restart then has NO
// baseline → the ADR-0045 P1 first-observation seed stores it and emits
// nothing, so the production between the last pre-restart reading and that
// first post-restart reading is never counted. Proven on staging 2026-10-08
// 21:58: the decoder restarted at 21:58:15, calc_state_mutations_total
// {mutation_kind="counter.seed_baseline",tenant="BISPHARMASTAGING"} jumped
// 0→88 (one per counter stream) and every Bispharma machine lost exactly one
// reading's delta; all 13 bursts since 09-25 line up with a decoder start.
//
// TrackedState lets the caller CHECKPOINT the numeric state (the counter
// baselines plus the timestamps/derived values computed alongside them) in the
// same SQLite transaction that enqueues the envelopes built from it. The
// persisted baseline therefore always equals "the counter value whose delta has
// been emitted", so restoring it after a restart makes the next reading's
// increment = counter − last emitted counter: nothing lost, nothing counted
// twice — exactly as if the process had never restarted.

package calc_production_counters

import (
	"sort"
	"sync"
)

// StateEntryKind names which numeric State map an entry belongs to.
type StateEntryKind string

const (
	StateEntryInt    StateEntryKind = "int"
	StateEntryFloat  StateEntryKind = "float"
	StateEntryTimeMs StateEntryKind = "time_ms"
)

// StateEntry is one numeric State value captured for a checkpoint. Int carries
// int and time_ms values; Float carries float values.
type StateEntry struct {
	Kind  StateEntryKind
	Key   string
	Int   int64
	Float float64
}

type dirtyKey struct {
	kind StateEntryKind
	key  string
}

// TrackedState wraps a State and records which NUMERIC keys (Int, Float,
// TimeMs) changed since the last TakeDirty. Bool/Strings/UnitMode are not
// tracked: they are configuration re-seeded from NBIRTH and the equipment
// register at boot, not running totals, so restoring a stale copy could only
// do harm.
//
// INVARIANT — single drainer: the dirty set is process-wide, so TakeDirty
// assumes ONE goroutine runs Calc + checkpoint per message (the MQTT
// subscriber's single drainQueue goroutine). With parallel drainers one
// message's commit could carry another message's baselines before that
// message's envelopes are enqueued (baseline ahead of emission ⇒ lost delta on
// restart). Parallelizing needs per-publisher dirty sets (and per-publisher
// Calc state) first.
type TrackedState struct {
	State
	mu    sync.Mutex
	dirty map[dirtyKey]struct{}
}

// NewTrackedState wraps inner (normally NewMemState()).
func NewTrackedState(inner State) *TrackedState {
	return &TrackedState{State: inner, dirty: make(map[dirtyKey]struct{})}
}

func (t *TrackedState) mark(kind StateEntryKind, key string) {
	t.mu.Lock()
	t.dirty[dirtyKey{kind, key}] = struct{}{}
	t.mu.Unlock()
}

// SetInt records the key as dirty after writing through.
func (t *TrackedState) SetInt(key string, v int64) error {
	if err := t.State.SetInt(key, v); err != nil {
		return err
	}
	t.mark(StateEntryInt, key)
	return nil
}

// SetFloat records the key as dirty after writing through.
func (t *TrackedState) SetFloat(key string, v float64) error {
	if err := t.State.SetFloat(key, v); err != nil {
		return err
	}
	t.mark(StateEntryFloat, key)
	return nil
}

// SetTimeMs records the key as dirty after writing through.
func (t *TrackedState) SetTimeMs(key string, v int64) error {
	if err := t.State.SetTimeMs(key, v); err != nil {
		return err
	}
	t.mark(StateEntryTimeMs, key)
	return nil
}

// TakeDirty returns the CURRENT value of every key changed since the previous
// TakeDirty and clears the dirty set. Sorted for deterministic writes. If the
// caller fails to persist the entries it must hand them back via Requeue.
func (t *TrackedState) TakeDirty() []StateEntry {
	t.mu.Lock()
	keys := make([]dirtyKey, 0, len(t.dirty))
	for k := range t.dirty {
		keys = append(keys, k)
	}
	t.dirty = make(map[dirtyKey]struct{})
	t.mu.Unlock()
	if len(keys) == 0 {
		return nil
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].kind != keys[j].kind {
			return keys[i].kind < keys[j].kind
		}
		return keys[i].key < keys[j].key
	})
	out := make([]StateEntry, 0, len(keys))
	for _, k := range keys {
		e := StateEntry{Kind: k.kind, Key: k.key}
		var found bool
		switch k.kind {
		case StateEntryInt:
			e.Int, found = t.State.Int(k.key)
		case StateEntryFloat:
			e.Float, found = t.State.Float(k.key)
		case StateEntryTimeMs:
			e.Int, found = t.State.TimeMs(k.key)
		}
		if found {
			out = append(out, e)
		}
	}
	return out
}

// Requeue marks entries dirty again (their checkpoint write failed), so the
// next successful checkpoint persists the then-current values.
func (t *TrackedState) Requeue(entries []StateEntry) {
	t.mu.Lock()
	for _, e := range entries {
		t.dirty[dirtyKey{e.Kind, e.Key}] = struct{}{}
	}
	t.mu.Unlock()
}

// Restore loads previously checkpointed entries into the wrapped State WITHOUT
// marking them dirty (they are already persisted). Unknown kinds are skipped.
// Returns how many entries were applied.
func (t *TrackedState) Restore(entries []StateEntry) (int, error) {
	n := 0
	for _, e := range entries {
		var err error
		switch e.Kind {
		case StateEntryInt:
			err = t.State.SetInt(e.Key, e.Int)
		case StateEntryFloat:
			err = t.State.SetFloat(e.Key, e.Float)
		case StateEntryTimeMs:
			err = t.State.SetTimeMs(e.Key, e.Int)
		default:
			continue
		}
		if err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}
