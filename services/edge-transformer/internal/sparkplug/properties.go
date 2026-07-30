// properties.go — accessors + re-exports for SparkPlug B Metric PropertySet.
//
// ADR-0046 ("edge-source topic contract") moves counter semantics OUT of the
// metric NAME and INTO metric properties: a birth-declared counter carries
// properties["counter_role"] (gross|net|scrap) and optionally
// properties["device_key"]. The birth-binding handler (internal/birthbind)
// reads those to bind (edge_node, alias) → (id_equipment, counter_role) so the
// DATA path routes by alias with ZERO metric-name string parsing.
//
// The generated protobuf keeps PropertySet as two parallel slices (Keys +
// Values); StringProperty is the small lookup that hides that shape. The type
// re-exports let callers OUTSIDE this package (birthbind, tests, future
// producers) construct + read properties without importing the internal
// protobuf subpath — mirroring the Metric_* value re-exports in decoder.go.
package sparkplug

import (
	pb "github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug/internal"
)

// PropertySet + PropertyValue re-exports so callers can build birth metrics
// carrying counter_role / device_key without the internal subpath. The oneof
// string wrapper mirrors the Metric_StringValue re-export in decoder.go.
type (
	PropertySet               = pb.Payload_PropertySet
	PropertyValue             = pb.Payload_PropertyValue
	PropertyValue_StringValue = pb.Payload_PropertyValue_StringValue
)

// StringProperty returns the string value of the metric property named key,
// and whether it was present + non-null. SparkPlug B stores properties as two
// parallel slices (Keys[i] ↔ Values[i]); a well-formed PropertySet keeps them
// the same length, but we guard the index defensively (a malformed producer
// must not panic the decode path). A null-valued property reads as absent —
// the caller treats "" / !ok identically (fail-closed: no role ⇒ not routed).
func StringProperty(m *Metric, key string) (string, bool) {
	ps := m.GetProperties()
	if ps == nil {
		return "", false
	}
	keys := ps.GetKeys()
	vals := ps.GetValues()
	for i, k := range keys {
		if k != key {
			continue
		}
		if i >= len(vals) {
			return "", false
		}
		v := vals[i]
		if v == nil || v.GetIsNull() {
			return "", false
		}
		return v.GetStringValue(), true
	}
	return "", false
}
