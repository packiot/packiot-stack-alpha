// Package calc_production_counters state layer. The JS function reads/writes
// ~25 distinct global.* key patterns per state-machine doc §3. Rather than
// exposing 25 typed methods on the interface, we expose typed accessors by
// value shape (Int, Float, TimeMs, Bool, Strings) — the *keys* are string-
// derived by the caller. This matches the JS free-form global.get(key)
// semantics faithfully and keeps the interface small.
//
// The one typed exception is UnitMode: the JS reads global.get("modes"),
// which is an array of {topic, is_set} records. The port models that as
// a semantic lookup because it's the ONLY caller of that shape.

package calc_production_counters

import (
	"sync"
)

// State is the read/write projection of Node-RED's global.*/flow.* stores
// the JS calc function depends on. Missing keys return zero value + found=false
// (matching JS's undefined→NaN→0 coercion when read via parseInt).
type State interface {
	// Int / SetInt — cumulative counters (ProdConsumedCount, etc.), custom
	// counter accumulator (Parameter*30772*), and multi-purpose numeric
	// state (___IN_INCR, ___IN_SCRAP).
	Int(key string) (v int64, found bool)
	SetInt(key string, v int64) error

	// Float / SetFloat — CurMachSpeed and threshold_val derivations.
	Float(key string) (v float64, found bool)
	SetFloat(key string, v float64) error

	// TimeMs / SetTimeMs — timestamps stored as Unix milliseconds (JS
	// Date().getTime() convention). Missing key → 0.
	TimeMs(key string) (v int64, found bool)
	SetTimeMs(key string, v int64) error

	// Bool / SetBool — parameter flags (Parameter*30763* auto-status
	// disable, Parameter*30770* custom counter enable).
	Bool(key string) (v bool, found bool)
	SetBool(key string, v bool) error

	// Strings / SetStrings — the ___STATUS_TOPICS registry array +
	// Parameter30700 CSV of machine indices in a line.
	Strings(key string) (v []string, found bool)
	SetStrings(key string, v []string) error

	// UnitMode looks up the PackML unit mode for a unit topic. Backed by
	// the "modes" global registry (array of {topic, is_set} records in JS).
	// Returns (Unknown, false) if not found.
	UnitMode(unitTopic string) (UnitMode, bool)

	// SetUnitMode registers or updates a unit's mode. Test/fixture helper —
	// production sets modes from equipment_events stream elsewhere.
	SetUnitMode(unitTopic string, m UnitMode) error
}

// memState is the reference in-memory State. Not safe for cross-process
// sharing — Redis (or another shared store) is required if multiple
// edge-transformer instances process the same tenant.
type memState struct {
	mu      sync.RWMutex
	ints    map[string]int64
	floats  map[string]float64
	timeMs  map[string]int64
	bools   map[string]bool
	strings map[string][]string
	modes   map[string]UnitMode
}

// NewMemState returns an empty in-memory State — the default backing for
// tests and single-instance dev deployments.
func NewMemState() State {
	return &memState{
		ints:    make(map[string]int64),
		floats:  make(map[string]float64),
		timeMs:  make(map[string]int64),
		bools:   make(map[string]bool),
		strings: make(map[string][]string),
		modes:   make(map[string]UnitMode),
	}
}

func (s *memState) Int(key string) (int64, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.ints[key]
	return v, ok
}

func (s *memState) SetInt(key string, v int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ints[key] = v
	return nil
}

func (s *memState) Float(key string) (float64, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.floats[key]
	return v, ok
}

func (s *memState) SetFloat(key string, v float64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.floats[key] = v
	return nil
}

func (s *memState) TimeMs(key string) (int64, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.timeMs[key]
	return v, ok
}

func (s *memState) SetTimeMs(key string, v int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.timeMs[key] = v
	return nil
}

func (s *memState) Bool(key string) (bool, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.bools[key]
	return v, ok
}

func (s *memState) SetBool(key string, v bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.bools[key] = v
	return nil
}

func (s *memState) Strings(key string) ([]string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.strings[key]
	return v, ok
}

func (s *memState) SetStrings(key string, v []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Defensive copy so caller mutations don't affect stored value.
	cp := make([]string, len(v))
	copy(cp, v)
	s.strings[key] = cp
	return nil
}

func (s *memState) UnitMode(unitTopic string) (UnitMode, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	m, ok := s.modes[unitTopic]
	if !ok {
		return UnitModeUnknown, false
	}
	return m, true
}

func (s *memState) SetUnitMode(unitTopic string, m UnitMode) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.modes[unitTopic] = m
	return nil
}
