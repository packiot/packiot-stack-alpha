// Sparkplug B alias-table state machine — ADR-0010 Phase 2 core deliverable.
//
// Sparkplug B compresses wire size by ~4× on the DATA path by referencing
// each metric via a uint64 alias instead of its full topic name. The alias
// is established in the BIRTH message and reused in every subsequent DATA
// message until DEATH. The receiver MUST maintain this mapping to make
// sense of DATA payloads — an unresolved alias is a decode failure.
//
// This package provides:
//
//   StateStore — the in-memory alias table keyed by publisher identity
//   Ingest    — accepts any Sparkplug message + updates state accordingly
//   PublisherKey — the (GroupID, EdgeNodeID, DeviceID) tuple identifying
//                  a publisher; DeviceID is empty for node-level messages
//   ResolvedPayload — the caller-friendly view with aliases → names resolved
//
// Design decisions locked in:
//   1. In-memory storage (persistence deferred to Phase 3+ per ADR-0010)
//   2. sync.RWMutex for concurrent-safety (multiple subscriber goroutines)
//   3. DATA-before-BIRTH returns ErrNoBirth — caller decides recovery
//      (log + drop, or request a fresh NBIRTH by re-subscribing)
//   4. Sequence number gaps: log-worthy but not errors — factory MQTT can
//      lose messages under QoS 0 without violating protocol contracts
//   5. Aliases are unique WITHIN a publisher's scope; different publishers
//      may use the same alias number for different names
//
// This is a scaffold. Integration with the MQTT subscriber lives in a
// future PR that wires the Handler (from internal/mqtt/) to call Ingest.

package sparkplug

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

// Sparkplug B message type constants — the third topic component per the
// Sparkplug spec (spBv1.0/<GroupID>/<MessageType>/<EdgeNodeID>[/<DeviceID>]).
// Callers pass these as the messageType arg to Ingest.
const (
	MsgTypeNBirth = "NBIRTH"
	MsgTypeDBirth = "DBIRTH"
	MsgTypeNData  = "NDATA"
	MsgTypeDData  = "DDATA"
	MsgTypeNDeath = "NDEATH"
	MsgTypeDDeath = "DDEATH"
	MsgTypeNCmd   = "NCMD"
	MsgTypeDCmd   = "DCMD"
)

// Errors returned by Ingest. Callers should check with errors.Is/As.
var (
	// ErrNoBirth is returned when NDATA/DDATA arrives before any BIRTH
	// message has established the alias table for this publisher.
	ErrNoBirth = errors.New("sparkplug: no prior BIRTH for publisher")

	// ErrUnknownMessageType is returned for topic MessageType components
	// outside the Sparkplug B spec's 8 valid types.
	ErrUnknownMessageType = errors.New("sparkplug: unknown message type")
)

// ErrUnknownAlias is returned when a DATA metric references an alias not
// present in the current alias table. Preserves the alias value + metric
// name (if any) for debugging.
type ErrUnknownAlias struct {
	PublisherKey PublisherKey
	Alias        uint64
}

func (e ErrUnknownAlias) Error() string {
	return fmt.Sprintf("sparkplug: unknown alias %d in DATA from %s",
		e.Alias, e.PublisherKey)
}

// PublisherKey identifies a Sparkplug B publisher for alias-table scoping.
// DeviceID is empty for node-level messages (NBIRTH/NDATA/NDEATH), non-empty
// for device-level (DBIRTH/DDATA/DDEATH).
//
// Aliases are unique within this scope — two different publishers may
// legally use alias=1 for different metric names.
type PublisherKey struct {
	GroupID    string
	EdgeNodeID string
	DeviceID   string // empty for node-level
}

func (k PublisherKey) String() string {
	if k.DeviceID == "" {
		return fmt.Sprintf("%s/%s", k.GroupID, k.EdgeNodeID)
	}
	return fmt.Sprintf("%s/%s/%s", k.GroupID, k.EdgeNodeID, k.DeviceID)
}

// ResolvedMetric is a caller-friendly metric with alias→name already resolved.
// The Datatype and Value are pulled from the wire-format Metric verbatim.
type ResolvedMetric struct {
	Name      string
	Alias     uint64
	Timestamp uint64
	Datatype  uint32
	Value     any // one of: uint64, int64, float32, float64, bool, string, []byte
}

// ResolvedPayload is the state machine's output for DATA messages — the
// full Payload with each Metric's Name populated from the alias table.
type ResolvedPayload struct {
	PublisherKey PublisherKey
	Timestamp    uint64
	Seq          uint64
	Metrics      []ResolvedMetric
}

// publisherState holds per-publisher alias table + monotonic seq tracking.
// Fields are read/written only while holding the StateStore's mutex —
// no per-state locking needed.
type publisherState struct {
	// aliases maps alias number → metric metadata (name + datatype).
	// Populated on BIRTH; consulted on DATA; cleared on DEATH.
	aliases map[uint64]aliasEntry

	// lastSeq is the most recent seq value seen for this publisher.
	// Sparkplug uses monotonically increasing seq (mod 256) per publisher.
	// A gap indicates a lost message — logged but not an error.
	lastSeq uint64

	// lastBirthAt is when the alias table was last (re)established.
	// Diagnostic aid for /health snapshots.
	lastBirthAt time.Time

	// lastMessageAt is the timestamp of the most recent Ingest.
	lastMessageAt time.Time
}

type aliasEntry struct {
	Name     string
	Datatype uint32
}

// StateStore is the concurrent-safe alias-table state machine.
// Zero value is not ready — use NewStateStore.
type StateStore struct {
	mu         sync.RWMutex
	publishers map[PublisherKey]*publisherState

	// seqGapObserved is called (if non-nil) when a sequence number gap is
	// detected on a DATA message. Wired to Prometheus in production.
	seqGapObserved func(key PublisherKey, expected, got uint64)
}

// NewStateStore constructs an empty StateStore. Ingest may be called
// concurrently from N goroutines.
func NewStateStore() *StateStore {
	return &StateStore{
		publishers: make(map[PublisherKey]*publisherState),
	}
}

// OnSeqGap registers a callback fired when NDATA/DDATA arrives with a seq
// number that doesn't match lastSeq+1 (mod 256). Called from Ingest while
// holding the write lock — the callback should return quickly.
func (s *StateStore) OnSeqGap(fn func(key PublisherKey, expected, got uint64)) {
	s.seqGapObserved = fn
}

// Ingest processes a Sparkplug B message. Returns:
//
//   - (*ResolvedPayload, nil) for DATA messages — aliases resolved to names
//   - (nil, nil) for BIRTH/DEATH/CMD — state updated, no downstream output
//   - (nil, error) on failure — protocol violation, unknown alias, etc.
//
// key identifies the publisher; messageType is the Sparkplug message type
// (use one of the MsgType* constants); payload is the decoded protobuf.
func (s *StateStore) Ingest(key PublisherKey, messageType string, p *Payload) (*ResolvedPayload, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	switch messageType {
	case MsgTypeNBirth, MsgTypeDBirth:
		s.applyBirth(key, p)
		return nil, nil

	case MsgTypeNData, MsgTypeDData:
		return s.applyData(key, p)

	case MsgTypeNDeath, MsgTypeDDeath:
		s.applyDeath(key)
		return nil, nil

	case MsgTypeNCmd, MsgTypeDCmd:
		// Commands travel the opposite direction (host→edge). We don't
		// establish or consume alias state from them in a subscriber-only
		// context — a future publisher-mode edge-transformer might.
		return nil, nil

	default:
		return nil, fmt.Errorf("%w: %q", ErrUnknownMessageType, messageType)
	}
}

// applyBirth rebuilds the alias table for this publisher from the BIRTH
// payload's metric definitions. Metrics without an alias are skipped —
// they can't be referenced from subsequent DATA messages.
//
// Sparkplug spec allows NBIRTH to reset seq to 0. We do the same.
func (s *StateStore) applyBirth(key PublisherKey, p *Payload) {
	state, ok := s.publishers[key]
	if !ok {
		state = &publisherState{}
		s.publishers[key] = state
	}
	state.aliases = make(map[uint64]aliasEntry, len(p.GetMetrics()))
	for _, m := range p.GetMetrics() {
		if m.Alias == nil {
			// Metrics without aliases can't be resolved on DATA. Allowed
			// by spec (spec says "SHOULD include alias"), but useless for
			// our state machine.
			continue
		}
		state.aliases[m.GetAlias()] = aliasEntry{
			Name:     m.GetName(),
			Datatype: m.GetDatatype(),
		}
	}
	state.lastSeq = p.GetSeq()
	state.lastBirthAt = time.Now()
	state.lastMessageAt = state.lastBirthAt
}

// applyData resolves each metric's alias → name from the current table
// and returns a ResolvedPayload. Returns ErrNoBirth if no BIRTH has
// established the table yet; returns ErrUnknownAlias if a metric references
// an alias not in the table (indicates BIRTH/DATA drift — possible on
// reconnect races or lost NBIRTH).
func (s *StateStore) applyData(key PublisherKey, p *Payload) (*ResolvedPayload, error) {
	state, ok := s.publishers[key]
	if !ok || state.aliases == nil {
		return nil, ErrNoBirth
	}

	// Seq gap detection (best-effort — Sparkplug seq wraps at 256).
	got := p.GetSeq()
	expected := (state.lastSeq + 1) & 0xff
	if got != expected && s.seqGapObserved != nil {
		s.seqGapObserved(key, expected, got)
	}
	state.lastSeq = got
	state.lastMessageAt = time.Now()

	resolved := make([]ResolvedMetric, 0, len(p.GetMetrics()))
	for _, m := range p.GetMetrics() {
		if m.Alias == nil {
			// DATA metrics without aliases are also valid per spec —
			// treat as name-carrying + skip lookup. Rare in practice.
			resolved = append(resolved, ResolvedMetric{
				Name:      m.GetName(),
				Timestamp: m.GetTimestamp(),
				Datatype:  m.GetDatatype(),
				Value:     extractValue(m),
			})
			continue
		}
		alias := m.GetAlias()
		entry, ok := state.aliases[alias]
		if !ok {
			return nil, ErrUnknownAlias{PublisherKey: key, Alias: alias}
		}
		// Datatype: DATA metrics may omit the datatype since it's fixed
		// per alias at BIRTH time. Fall back to the BIRTH-established value.
		dt := m.GetDatatype()
		if m.Datatype == nil {
			dt = entry.Datatype
		}
		resolved = append(resolved, ResolvedMetric{
			Name:      entry.Name,
			Alias:     alias,
			Timestamp: m.GetTimestamp(),
			Datatype:  dt,
			Value:     extractValue(m),
		})
	}
	return &ResolvedPayload{
		PublisherKey: key,
		Timestamp:    p.GetTimestamp(),
		Seq:          got,
		Metrics:      resolved,
	}, nil
}

// applyDeath invalidates the alias table for this publisher. Subsequent
// DATA from this key will return ErrNoBirth until a fresh BIRTH lands.
func (s *StateStore) applyDeath(key PublisherKey) {
	delete(s.publishers, key)
}

// extractValue pulls the concrete typed value out of the wire-format
// Metric's oneof Value field. Returns nil for null / unset.
func extractValue(m *Metric) any {
	switch v := m.GetValue().(type) {
	case *Metric_IntValue:
		return v.IntValue
	case *Metric_LongValue:
		return v.LongValue
	case *Metric_FloatValue:
		return v.FloatValue
	case *Metric_DoubleValue:
		return v.DoubleValue
	case *Metric_BooleanValue:
		return v.BooleanValue
	case *Metric_StringValue:
		return v.StringValue
	default:
		// Bytes, Template, Dataset — not yet unwrapped. Return raw for now.
		return v
	}
}

// PublisherSnapshot is the diagnostic view of one publisher's state,
// suitable for /health JSON.
type PublisherSnapshot struct {
	Key           string `json:"key"`
	AliasCount    int    `json:"alias_count"`
	LastSeq       uint64 `json:"last_seq"`
	LastBirthAt   string `json:"last_birth_at,omitempty"`
	LastMessageAt string `json:"last_message_at,omitempty"`
}

// Snapshot returns the current per-publisher state for /health. Copies the
// data under the read lock so callers can safely marshal to JSON without
// racing further Ingests.
func (s *StateStore) Snapshot() []PublisherSnapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]PublisherSnapshot, 0, len(s.publishers))
	for k, st := range s.publishers {
		snap := PublisherSnapshot{
			Key:        k.String(),
			AliasCount: len(st.aliases),
			LastSeq:    st.lastSeq,
		}
		if !st.lastBirthAt.IsZero() {
			snap.LastBirthAt = st.lastBirthAt.Format(time.RFC3339)
		}
		if !st.lastMessageAt.IsZero() {
			snap.LastMessageAt = st.lastMessageAt.Format(time.RFC3339)
		}
		out = append(out, snap)
	}
	return out
}

// Reset removes a publisher's entry from the table. Primarily useful for
// tests + manual admin action. Not part of the Sparkplug protocol.
func (s *StateStore) Reset(key PublisherKey) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.publishers, key)
}

// Len returns the number of tracked publishers. Diagnostic only.
func (s *StateStore) Len() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.publishers)
}
