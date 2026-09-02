// Package birthbind implements ADR-0046 step 1: the DBIRTH/NBIRTH birth-binding
// handler. It is the CONSUMER side of the edge-source topic contract
// (docs/reference/edge-source-topic-contract.md).
//
// The contract's core inversion: identity + counter semantics are DECLARED at
// birth, never DERIVED by string-parsing a metric name at DATA time. On a birth,
// for every counter metric the producer asserts:
//
//   - properties["counter_role"] ∈ {gross, net, scrap}   (§4, the closed enum)
//   - a device_key = properties["device_key"] || <device_id>  (§3)
//
// This package resolves device_key → id_equipment via packml_register (the
// identity SSoT, ADR-0009 — injected as a DeviceResolver seam) and caches
//
//	(edge_node, alias) → (id_equipment, counter_role)
//
// so the DATA path routes purely by the SparkPlug alias carried on every DDATA.
// A DDATA alias with no live binding is an error → the caller requests a rebirth
// (ADR-0042) and drops the sample. Fail-closed: an unbound alias is never guessed.
//
// The package is deliberately dependency-light (only the sibling sparkplug
// decode package + slog) so it is fast to unit-test against the shared golden
// fixtures under docs/reference/fixtures. The Role→Calc CounterKind mapping and
// the flag-gate live in the wiring layer (cmd/edge-transformer), not here.
package birthbind

import (
	"log/slog"
	"sync"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// PropCounterRole + PropDeviceKey are the metric-property keys the contract
// (§3) defines. Kept as constants so producer + consumer never drift on the
// spelling.
const (
	PropCounterRole = "counter_role"
	PropDeviceKey   = "device_key"
)

// Role is the closed counter-role enum (contract §4). It is the ONLY place
// counter meaning lives — the English counter-name substring is retired scaffold.
type Role string

const (
	RoleGross Role = "gross" // total infeed/consumed — oee_q denominator
	RoleNet   Role = "net"   // good output/processed — oee_q numerator
	RoleScrap Role = "scrap" // defective/rejected — informational
)

// ParseRole validates a raw property string against the closed enum. An
// unknown value returns ok=false so the caller can fail-closed (skip + log)
// rather than route a metric with unknown semantics.
func ParseRole(s string) (Role, bool) {
	switch Role(s) {
	case RoleGross:
		return RoleGross, true
	case RoleNet:
		return RoleNet, true
	case RoleScrap:
		return RoleScrap, true
	default:
		return "", false
	}
}

// Binding is the birth-declared routing target for one alias: which equipment
// the counter belongs to and its semantic role. This is what a DDATA alias
// resolves to — no name, no index, no positional logic.
type Binding struct {
	IDEquipment int
	Role        Role
}

// DeviceResolver resolves a producer-asserted device_key to the stack's
// id_equipment via packml_register (the identity SSoT, ADR-0009). It is a SEAM:
// unit tests inject an in-memory MapResolver; a DB-backed implementation is
// wired only when a tenant opts in (keeping edge-transformer's pgx-free default).
//
// Producers assert KEYS, never ids — the resolver is the single translation.
type DeviceResolver interface {
	Resolve(deviceKey string) (idEquipment int, ok bool)
}

// MapResolver is an in-memory DeviceResolver backed by an operator-supplied /
// test-supplied device_key → id_equipment map. A nil/empty map resolves
// nothing (every counter fails-closed), which is the safe default when the ON
// flag is set before a resolver is configured.
type MapResolver map[string]int

// Resolve implements DeviceResolver.
func (m MapResolver) Resolve(deviceKey string) (int, bool) {
	id, ok := m[deviceKey]
	return id, ok
}

// key scopes an alias to its edge node. Aliases are unique WITHIN an edge node
// (contract §3), so (edge_node, alias) is the stable routing key — independent
// of which device the DDATA arrives under.
type key struct {
	edgeNode string
	alias    uint64
}

// Table is the concurrent-safe birth cache: (edge_node, alias) → Binding.
// Rebuilt per device at each birth; consulted on every DDATA. The zero value
// is not ready — use NewTable.
type Table struct {
	mu       sync.RWMutex
	bindings map[key]Binding
	resolver DeviceResolver
}

// NewTable builds an empty Table over the given resolver. A nil resolver is
// tolerated (nothing binds) so a misconfigured ON deploy fails closed rather
// than panicking.
func NewTable(resolver DeviceResolver) *Table {
	return &Table{
		bindings: make(map[key]Binding),
		resolver: resolver,
	}
}

// ApplyBirth binds every counter metric declared in one device's birth payload.
// edgeNode is the SparkPlug <edge_node_id> (from the topic); deviceID is the
// SparkPlug <device_id> (empty for a node-scoped NBIRTH) used as the fallback
// device_key when a metric omits properties["device_key"].
//
// For each metric it reads properties["counter_role"]: a metric WITHOUT one is
// a non-counter (state/speed — out of contract v1.0 scope) and is skipped. A
// metric WITH a role has its device_key resolved to id_equipment; on success
// the (edge_node, alias) → (id_equipment, role) binding is cached. A metric
// that carries a role but cannot be resolved (unknown role, no alias, or
// unresolvable device_key) is skipped + logged — leaving it unbound so its
// later DDATA fails-closed into a rebirth.
//
// Returns (bound, skipped) counts for observability. Existing bindings for the
// same (edge_node, alias) are overwritten — a fresh birth is authoritative.
func (t *Table) ApplyBirth(edgeNode, deviceID string, p *sparkplug.Payload, logger *slog.Logger) (bound, skipped int) {
	t.mu.Lock()
	defer t.mu.Unlock()

	for _, m := range p.GetMetrics() {
		roleStr, ok := sparkplug.StringProperty(m, PropCounterRole)
		if !ok {
			// No counter_role → non-counter metric (state/speed). Not ours to
			// bind in v1.0 (counters only); silently skip.
			continue
		}
		role, ok := ParseRole(roleStr)
		if !ok {
			skipped++
			logf(logger).Warn("birthbind: metric declares unknown counter_role — not bound",
				slog.String("edge_node", edgeNode),
				slog.String("metric", m.GetName()),
				slog.String("counter_role", roleStr))
			continue
		}
		if m.Alias == nil {
			// A counter with no alias can never be referenced on DDATA.
			skipped++
			logf(logger).Warn("birthbind: counter metric has no alias — not bound",
				slog.String("edge_node", edgeNode),
				slog.String("metric", m.GetName()),
				slog.String("counter_role", roleStr))
			continue
		}
		deviceKey := deviceID
		if dk, ok := sparkplug.StringProperty(m, PropDeviceKey); ok && dk != "" {
			deviceKey = dk
		}
		idEquip, ok := t.resolve(deviceKey)
		if !ok {
			skipped++
			logf(logger).Warn("birthbind: device_key did not resolve to id_equipment — not bound (DDATA will rebirth)",
				slog.String("edge_node", edgeNode),
				slog.String("device_key", deviceKey),
				slog.String("metric", m.GetName()),
				slog.String("counter_role", roleStr))
			continue
		}
		t.bindings[key{edgeNode: edgeNode, alias: m.GetAlias()}] = Binding{
			IDEquipment: idEquip,
			Role:        role,
		}
		bound++
	}
	logf(logger).Info("birthbind: applied birth",
		slog.String("edge_node", edgeNode),
		slog.String("device_id", deviceID),
		slog.Int("bound", bound),
		slog.Int("skipped", skipped))
	return bound, skipped
}

// Lookup returns the birth binding for a DDATA alias, scoped to its edge node.
// ok=false means the alias has no live binding — the caller MUST fail-closed
// (request rebirth + drop the sample), never guess.
func (t *Table) Lookup(edgeNode string, alias uint64) (Binding, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	b, ok := t.bindings[key{edgeNode: edgeNode, alias: alias}]
	return b, ok
}

// Len returns the number of live bindings. Diagnostic only.
func (t *Table) Len() int {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return len(t.bindings)
}

// resolve is the nil-safe resolver call (nil resolver ⇒ nothing binds).
func (t *Table) resolve(deviceKey string) (int, bool) {
	if t.resolver == nil || deviceKey == "" {
		return 0, false
	}
	return t.resolver.Resolve(deviceKey)
}

// logf returns a usable logger even when the caller passes nil, so the package
// never panics on a missing logger (matches the surrounding code's tolerance).
func logf(l *slog.Logger) *slog.Logger {
	if l == nil {
		return slog.Default()
	}
	return l
}
