// Package birthbind implements ADR-0046 step 1: the DBIRTH/NBIRTH birth-binding
// handler. It is the CONSUMER side of the edge-source topic contract
// (docs/reference/edge-source-topic-contract.md).
//
// The contract's core inversion: identity + counter semantics are DECLARED at
// birth, never DERIVED by string-parsing a metric name at DATA time. On a birth,
// for every counter metric the producer asserts:
//
//   - properties["counter_role"] ∈ {gross, net, scrap}   (§4, the closed enum)
//   - properties["device_key"] = the opaque dk_<32 hex> key  (§3, ADR-0061 D1)
//
// This package resolves device_key → (id_equipment, id_enterprise) via
// core.device_bindings (the declared identity, ADR-0061 — injected as a
// DeviceResolver seam) and caches
//
//	(group_id, edge_node, alias) → (id_equipment, id_enterprise, counter_role)
//
// plus the same binding by the birth-declared metric NAME (the decoder's DATA
// path resolves alias → name in sparkplug.StateStore, and the envelope it
// publishes is name-keyed). The tenant is the binding's id_enterprise
// (ADR-0061 D3), never the group_id or a name segment. Fail-closed: a metric
// with no declared device_key, or a key with no active binding, stays unbound —
// never guessed, never derived from the <device_id> or the name (P2 removed the
// <device_id> fallback).
//
// The package is deliberately dependency-light (only the sibling sparkplug
// decode package + slog) so it is fast to unit-test against the shared golden
// fixtures under docs/reference/fixtures. The Role→Calc CounterKind mapping and
// the flag-gate live in the wiring layer (cmd/edge-transformer), not here.
package birthbind

import (
	"log/slog"
	"regexp"
	"sync"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// PropCounterRole + PropDeviceKey are the metric-property keys the contract
// (§3) defines. Kept as constants so producer + consumer never drift on the
// spelling.
const (
	PropCounterRole = "counter_role"
	PropDeviceKey   = "device_key"
	PropRole        = "role" // ADR-0061 D2: the declared meaning of ANY metric
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

// roleShape is the D9 role syntax (dot-separated lowercase words). The catalogue
// itself is enforced at onboarding (tenantprofile.ValidRole) and by consumers.
var roleShape = regexp.MustCompile(`^[a-z_]+(\.[a-z_]+)+$`)

// Binding is the birth-declared routing target for one metric: which equipment
// (and so which tenant) the counter belongs to and its semantic role. This is
// what a DATA metric resolves to — no name parsing, no index, no positional logic.
type Binding struct {
	IDEquipment  int
	IDEnterprise int    // 0 = the resolver did not say (MapResolver); never guessed
	Role         Role   // counter role (gross|net|scrap); "" for a non-counter
	Declared     string // ADR-0061 D9 role (counter.gross, state.current, …)
}

// Device is what a device_key resolves to: the active core.device_bindings row.
type Device struct {
	IDEquipment  int
	IDEnterprise int
}

// DeviceResolver resolves a producer-asserted device_key to the stack's ids via
// core.device_bindings (ADR-0061; read through read-api). It is a SEAM: unit
// tests inject an in-memory MapResolver; the refdata HTTP resolver is wired when
// BIRTH_BOUND_ROUTING is on (keeping edge-transformer's pgx-free default).
//
// Producers assert KEYS, never ids — the resolver is the single translation.
type DeviceResolver interface {
	Resolve(deviceKey string) (Device, bool)
}

// MapResolver is an in-memory DeviceResolver backed by an operator-supplied /
// test-supplied device_key → id_equipment map. It knows no tenant
// (IDEnterprise 0). A nil/empty map resolves nothing (every counter fails
// closed), the safe default when the ON flag is set before a resolver is configured.
type MapResolver map[string]int

// Resolve implements DeviceResolver.
func (m MapResolver) Resolve(deviceKey string) (Device, bool) {
	id, ok := m[deviceKey]
	return Device{IDEquipment: id}, ok
}

// node scopes bindings to one SparkPlug edge node. group_id is part of it: two
// tenants may reuse an edge_node name, and aliases are unique only WITHIN an
// edge node (contract §3).
type node struct {
	group    string
	edgeNode string
}

// nodeBindings is everything one edge node's births declared.
type nodeBindings struct {
	byAlias map[uint64]Binding
	byName  map[string]Binding
}

// Table is the concurrent-safe birth cache: per (group_id, edge_node), alias →
// Binding and name → Binding. Rebuilt at each NBIRTH (a node rebirth re-issues
// aliases, so the node's previous bindings are dropped); extended by DBIRTH.
// The zero value is not ready — use NewTable.
type Table struct {
	mu       sync.RWMutex
	nodes    map[node]*nodeBindings
	resolver DeviceResolver
}

// NewTable builds an empty Table over the given resolver. A nil resolver is
// tolerated (nothing binds) so a misconfigured ON deploy fails closed rather
// than panicking.
func NewTable(resolver DeviceResolver) *Table {
	return &Table{
		nodes:    make(map[node]*nodeBindings),
		resolver: resolver,
	}
}

// BirthResult counts one birth's outcomes for observability. Unrelated metrics
// (no counter_role: state/speed/parameters) are not counted at all.
type BirthResult struct {
	Bound      int // counter bound to an active binding
	NoKey      int // counter declares no device_key (undeclared producer, pre-P1 config)
	Unresolved int // device_key has no active binding (or the resolver failed)
	BadRole    int // unknown counter_role value
	NoAlias    int // counter without an alias (can never be referenced on DATA)
}

// Skipped is every counter that stayed unbound.
func (r BirthResult) Skipped() int { return r.NoKey + r.Unresolved + r.BadRole + r.NoAlias }

// ApplyBirth binds every counter metric declared in one birth payload.
// group/edgeNode/deviceID come from the SparkPlug topic; nbirth=true drops the
// node's previous bindings first (a node rebirth re-issues every alias).
//
// For each metric it reads properties["counter_role"]: a metric WITHOUT one is
// not contract-governed (state/speed/parameters) and is skipped silently. A
// counter is bound only when it carries an alias AND a declared device_key that
// resolves to an active binding; otherwise it stays unbound and is counted —
// its DATA then carries no ids (fail-closed).
func (t *Table) ApplyBirth(group, edgeNode, deviceID string, nbirth bool, p *sparkplug.Payload, logger *slog.Logger) BirthResult {
	var res BirthResult
	n := node{group: group, edgeNode: edgeNode}

	t.mu.Lock()
	defer t.mu.Unlock()
	nb := t.nodes[n]
	if nb == nil || nbirth {
		nb = &nodeBindings{byAlias: map[uint64]Binding{}, byName: map[string]Binding{}}
		t.nodes[n] = nb
	}

	for _, m := range p.GetMetrics() {
		declared, _ := sparkplug.StringProperty(m, PropRole)
		roleStr, isCounter := sparkplug.StringProperty(m, PropCounterRole)
		if !isCounter && declared == "" {
			continue // not contract-governed: no role declared
		}
		var role Role
		if isCounter {
			var ok bool
			if role, ok = ParseRole(roleStr); !ok {
				res.BadRole++
				logf(logger).Warn("birthbind: metric declares unknown counter_role — not bound",
					slog.String("group_id", group), slog.String("edge_node", edgeNode),
					slog.String("metric", m.GetName()), slog.String("counter_role", roleStr))
				continue
			}
			if declared == "" {
				declared = "counter." + string(role)
			}
		}
		if !roleShape.MatchString(declared) {
			res.BadRole++
			logf(logger).Warn("birthbind: metric declares a malformed role — not bound",
				slog.String("group_id", group), slog.String("edge_node", edgeNode),
				slog.String("metric", m.GetName()), slog.String("role", declared))
			continue
		}
		if m.Alias == nil {
			res.NoAlias++
			logf(logger).Warn("birthbind: counter metric has no alias — not bound",
				slog.String("group_id", group), slog.String("edge_node", edgeNode),
				slog.String("metric", m.GetName()))
			continue
		}
		deviceKey, _ := sparkplug.StringProperty(m, PropDeviceKey)
		if deviceKey == "" {
			// ADR-0061 D1: identity is declared, never taken from <device_id> or the name.
			res.NoKey++
			continue
		}
		dev, ok := t.resolve(deviceKey)
		if !ok || dev.IDEquipment <= 0 {
			res.Unresolved++
			logf(logger).Warn("birthbind: device_key has no active binding — not bound",
				slog.String("group_id", group), slog.String("edge_node", edgeNode),
				slog.String("device_key", deviceKey), slog.String("metric", m.GetName()))
			continue
		}
		b := Binding{IDEquipment: dev.IDEquipment, IDEnterprise: dev.IDEnterprise, Role: role, Declared: declared}
		nb.byAlias[m.GetAlias()] = b
		if name := m.GetName(); name != "" {
			nb.byName[name] = b
		}
		res.Bound++
	}
	logf(logger).Info("birthbind: applied birth",
		slog.String("group_id", group), slog.String("edge_node", edgeNode),
		slog.String("device_id", deviceID), slog.Bool("nbirth", nbirth),
		slog.Int("bound", res.Bound), slog.Int("no_key", res.NoKey),
		slog.Int("unresolved", res.Unresolved), slog.Int("skipped", res.Skipped()))
	return res
}

// Lookup returns the birth binding for a DATA alias, scoped to its edge node.
// ok=false means the alias has no live binding — never guess.
func (t *Table) Lookup(group, edgeNode string, alias uint64) (Binding, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	nb := t.nodes[node{group: group, edgeNode: edgeNode}]
	if nb == nil {
		return Binding{}, false
	}
	b, ok := nb.byAlias[alias]
	return b, ok
}

// LookupName returns the binding of the metric the node's birth declared under
// this name. Same scope and fail-closed contract as Lookup; used where the DATA
// path is already name-keyed (the decoder's StateStore resolves alias → name).
func (t *Table) LookupName(group, edgeNode, name string) (Binding, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	nb := t.nodes[node{group: group, edgeNode: edgeNode}]
	if nb == nil {
		return Binding{}, false
	}
	b, ok := nb.byName[name]
	return b, ok
}

// Len returns the number of live alias bindings across all nodes. Diagnostic only.
func (t *Table) Len() int {
	t.mu.RLock()
	defer t.mu.RUnlock()
	n := 0
	for _, nb := range t.nodes {
		n += len(nb.byAlias)
	}
	return n
}

// resolve is the nil-safe resolver call (nil resolver ⇒ nothing binds).
func (t *Table) resolve(deviceKey string) (Device, bool) {
	if t.resolver == nil || deviceKey == "" {
		return Device{}, false
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
