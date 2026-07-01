// In-memory reference implementation of the State interface.
// Production wiring can swap this for a Redis-backed implementation
// following the same interface — see docs/phase-3-calc-production-counters-
// port-plan.md § 4 for the trade-off analysis.

package calc_production_counters

import (
	"sync"
)

// memState is the reference in-memory State. Not safe for cross-process
// sharing — Redis (or another shared store) is required if multiple
// edge-transformer instances process the same tenant.
type memState struct {
	mu        sync.RWMutex
	modes     map[string]UnitMode // unit topic → mode
	configs   map[string]Config   // unit topic → config
	counters  map[string]int64    // "unit|kind" → cumulative
}

// NewMemState returns an empty in-memory State — the default backing for
// tests and single-instance dev deployments.
func NewMemState() State {
	return &memState{
		modes:    make(map[string]UnitMode),
		configs:  make(map[string]Config),
		counters: make(map[string]int64),
	}
}

func (s *memState) Modes(unitTopic string) (UnitMode, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	m, ok := s.modes[unitTopic]
	return m, ok
}

// SetMode is an in-memory-only convenience for tests + fixture setup.
// Not part of the State interface — production callers update mode
// through the equipment_events stream, not by direct write.
func (s *memState) SetMode(unitTopic string, m UnitMode) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.modes[unitTopic] = m
}

func (s *memState) PackMLConfig(unitTopic string) (Config, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	c, ok := s.configs[unitTopic]
	if !ok {
		return Config{}, ErrNotConfigured
	}
	return c, nil
}

// SetConfig is an in-memory-only convenience for tests + fixture setup.
func (s *memState) SetConfig(unitTopic string, c Config) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.configs[unitTopic] = c
}

func (s *memState) CounterCumulative(unitTopic string, kind CounterKind) (int64, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.counters[counterKey(unitTopic, kind)], nil
}

func (s *memState) SetCounterCumulative(unitTopic string, kind CounterKind, v int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.counters[counterKey(unitTopic, kind)] = v
	return nil
}

func counterKey(unitTopic string, kind CounterKind) string {
	return unitTopic + "|" + kind.String()
}
