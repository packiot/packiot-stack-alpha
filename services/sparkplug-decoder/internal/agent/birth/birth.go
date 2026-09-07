// Package birth is the ADR-0046 (edge-source topic contract) step-2 DEFINITIVE
// BIRTH declaration — the producer side. It turns a canonical count-leaf metric
// name into the contract's role-typed birth metric, resolving the physical PLC
// index → semantic role AT THE EDGE so the emitted stream carries ROLES, never
// indices, in the routing path.
//
// What the contract asks (docs/reference/edge-source-topic-contract.md §2–§5):
// on BIRTH each counter metric MUST declare, per SparkPlug B Metric:
//
//   - name       — human-readable UNS path, DISPLAY ONLY (birth-only).
//   - alias      — the uint64 routing key carried on every later DDATA.
//   - datatype   — the totalizer's wire type.
//   - properties["counter_role"] — REQUIRED, closed enum {gross,net,scrap}.
//   - properties["source_ref"]   — OPTIONAL lineage only (origin index/register);
//     MUST NOT be used for routing.
//   - properties["device_key"]   — REQUIRED when the equipment is not already
//     fixed by the SparkPlug <device_id> (§3). The agent's NBIRTH is NODE-scoped
//     (one payload for the whole edge node, no per-device DBIRTH split), so the
//     equipment is NOT fixed by <device_id> and the device_key rides as a metric
//     property — which is exactly the case §3 permits it for.
//
// The index→role resolution (the whole point of ADR-0046)
// -------------------------------------------------------
// The canonical count-leaf name the generator emits is
// `<topic>/Admin/Prod<Kind>Count/<idx>/Unit` (clientdescriptor.generate:
// lineRoleMetrics + the member metric_templates). We map the *Count kind → the
// contract role — ProdConsumedCount→gross, ProdProcessedCount→net,
// ProdDefectiveCount→scrap (the platform's counter-intuitive leaf naming:
// Consumed=gross TOTAL in, Processed=net GOOD out; see clientdescriptor.LineRole)
// — and lift the physical <idx> into source_ref="idx:<n>" as LINEAGE only. The
// index never appears in the routing path; the role does.
//
// DEVICE_KEY — DECLARED first, derivation as the bridge (ADR-0046 task #18)
// ------------------------------------------------------------------------
// clientdescriptor.Equipment now carries an explicit `device_key`
// (Equipment.DeviceKey / ResolvedDeviceKey), persisted to packml_register.device_key
// and stamped onto each agent tag-map entry (agentcfg.TagMapEntry.DeviceKey). When
// that DECLARED key reaches here (session passes it to
// CounterMetricPropsWithDeviceKey), it is AUTHORITATIVE — identity is DECLARED, not
// string-derived (contract §2 "identity is DECLARED at birth, never derived").
//
// When NO declared key is supplied (a descriptor that predates the field, or the
// register-loader cutover path which does not yet carry it), we fall back to
// DERIVING the device_key from the canonical topic embedded in the metric name:
// strip the 4-segment count-leaf tail (`Admin/Prod<Kind>Count/<idx>/Unit`) and
// dash-join the remaining topic segments —
// `CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit` → device_key
// `CPACK-SC-LINHAS-L5-BREYER`. Because the descriptors DECLARE exactly this dash
// form, declared and derived agree byte-for-byte (and both match the golden
// fixtures docs/reference/fixtures/*-birth-example.json). The derivation is the
// transitional BRIDGE — the ONLY string-parse of a name, and it happens once at
// birth, never on DDATA.
package birth

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// Counter roles — the closed enum from the contract §4. This is the ONLY place
// counter semantics live in the emitted stream.
const (
	RoleGross = "gross" // total infeed / consumed → oee_q denominator
	RoleNet   = "net"   // good output / processed → oee_q numerator
	RoleScrap = "scrap" // defective / rejected
)

// Metric property keys carried at birth (contract §3). Birth-only: DDATA never
// resends them.
const (
	PropCounterRole = "counter_role"
	PropSourceRef   = "source_ref"
	PropDeviceKey   = "device_key"
)

// leafRole maps the canonical count-leaf kind (the `Prod<Kind>Count` segment) to
// the contract role. This is the edge-side resolution of the legacy English
// count-name substring — which the contract §4 retires as non-authoritative —
// into the role that IS authoritative. The mapping mirrors
// clientdescriptor.lineRoleLeaf inverted (consumed=gross, processed=net,
// defective=scrap).
var leafRole = map[string]string{
	"ProdConsumedCount":  RoleGross,
	"ProdProcessedCount": RoleNet,
	"ProdDefectiveCount": RoleScrap,
}

// parsedLeaf is a canonical count-leaf name decomposed into the contract's
// birth fields.
type parsedLeaf struct {
	deviceKey string // canonical topic → dash form (§2 device key)
	role      string // counter_role (§4 closed enum)
	sourceRef string // "idx:<n>" lineage (§3)
}

// parseCounterLeaf decomposes a canonical count-leaf metric NAME into its device
// key + role + source_ref, or returns ok=false for any metric that is not a
// role-typed counter (state, speed, bdSeq, a bare non-indexed line count). The
// recognized shape is `<topic…>/<group>/Prod<Kind>Count/<idx>/Unit`, len>=5 so a
// device topic remains after the 4-segment leaf tail is stripped. Fail-closed: a
// `*Count` kind that is not one of the three known roles yields ok=false (no
// role guessed) — the same discipline the contract demands on the consumer side.
func parseCounterLeaf(name string) (parsedLeaf, bool) {
	segs := strings.Split(name, "/")
	if len(segs) < 5 {
		return parsedLeaf{}, false
	}
	if segs[len(segs)-1] != "Unit" {
		return parsedLeaf{}, false
	}
	role, ok := leafRole[segs[len(segs)-3]]
	if !ok {
		return parsedLeaf{}, false
	}
	idxSeg := segs[len(segs)-2]
	if idx, err := strconv.Atoi(idxSeg); err != nil || idx < 0 {
		return parsedLeaf{}, false
	}
	// device topic = everything before the 4-segment count-leaf tail
	// (<group>/Prod<Kind>Count/<idx>/Unit). Dash-join → the device_key form the
	// golden fixtures use.
	topic := segs[:len(segs)-4]
	return parsedLeaf{
		deviceKey: strings.Join(topic, "-"),
		role:      role,
		sourceRef: "idx:" + idxSeg,
	}, true
}

// CounterMetricProps builds the ADR-0046 definitive-birth PropertySet for a
// canonical count-leaf metric name — counter_role (required), source_ref
// (lineage), and device_key (node-scoped identity, §3). ok=false for a
// non-counter metric (state, speed, bdSeq): those carry no role and get NO
// properties, so the birth stays byte-clean for everything the contract does not
// govern (counters only, §3). The agent calls this per NBIRTH metric only when
// the EMIT_DEFINITIVE_BIRTH flag is set.
func CounterMetricProps(name string) (*sparkplug.PropertySet, bool) {
	return CounterMetricPropsWithDeviceKey(name, "")
}

// CounterMetricPropsWithDeviceKey is CounterMetricProps with an explicitly DECLARED
// device_key preferred over the topic derivation (ADR-0046 task #18: identity
// DECLARED, not string-derived). A non-empty declaredKey is authoritative; an empty
// one falls back to the dash-joined-topic derivation — the transitional bridge, so a
// descriptor that predates the device_key field (or the register-loader path that
// does not yet carry it) still emits the correct, fixture-matching key. ok=false for
// a non-counter metric (state/speed/bdSeq), exactly like CounterMetricProps.
func CounterMetricPropsWithDeviceKey(name, declaredKey string) (*sparkplug.PropertySet, bool) {
	leaf, ok := parseCounterLeaf(name)
	if !ok {
		return nil, false
	}
	deviceKey := leaf.deviceKey
	if k := strings.TrimSpace(declaredKey); k != "" {
		deviceKey = k
	}
	return &sparkplug.PropertySet{
		Keys: []string{PropCounterRole, PropSourceRef, PropDeviceKey},
		Values: []*sparkplug.PropertyValue{
			strProp(leaf.role),
			strProp(leaf.sourceRef),
			strProp(deviceKey),
		},
	}, true
}

// strProp wraps a string as a SparkPlug PropertyValue (type=String).
func strProp(v string) *sparkplug.PropertyValue {
	t := uint32(sparkplug.DataType_String.Number())
	return &sparkplug.PropertyValue{
		Type:  &t,
		Value: &sparkplug.PropertyValue_StringValue{StringValue: v},
	}
}

// ── The logical birth declaration (schemas/edge-birth-declaration.schema.json) ──
//
// These structs are the JSON projection of an emitted NBIRTH, grouped by device
// key. They exist so a producer can PROVE its birth conforms to the shared
// golden the contract §6 tests every producer against — the schema, not a
// fallback parser, is the compatibility guarantee.

// Declaration is a conformant edge-source birth (contract §6 / the schema root).
type Declaration struct {
	GroupID    string   `json:"group_id"`
	EdgeNodeID string   `json:"edge_node_id"`
	Devices    []Device `json:"devices"`
}

// Device is one equipment's role-typed metric set, keyed by its stable device
// key (= SparkPlug <device_id>).
type Device struct {
	DeviceKey string        `json:"device_key"`
	Metrics   []BirthMetric `json:"metrics"`
}

// BirthMetric is one role-typed counter declaration. Field set is EXACTLY the
// schema's `metric` (additionalProperties:false), so a golden fixture strict-
// unmarshals into it and back with no drift.
type BirthMetric struct {
	Name        string `json:"name,omitempty"`
	Alias       uint64 `json:"alias"`
	Datatype    string `json:"datatype,omitempty"`
	CounterRole string `json:"counter_role"`
	SourceRef   string `json:"source_ref,omitempty"`
}

// DeclarationFromNBIRTH projects an emitted NBIRTH payload into the logical
// declaration: it reads each metric's counter_role/source_ref/device_key back
// out of the SparkPlug properties, groups by device_key (first-seen order for a
// deterministic result), and drops every non-counter metric (no counter_role
// property → not contract-governed). This is what a producer test runs on the
// REAL payload the agent emits, so a conformance assertion tests the wire form,
// not a hand-built stand-in.
func DeclarationFromNBIRTH(groupID, edgeNodeID string, pl *sparkplug.Payload) Declaration {
	decl := Declaration{GroupID: groupID, EdgeNodeID: edgeNodeID}
	byDevice := map[string]int{} // device_key → index into decl.Devices
	for _, m := range pl.GetMetrics() {
		role, sref, dkey, ok := readProps(m)
		if !ok {
			continue
		}
		i, seen := byDevice[dkey]
		if !seen {
			i = len(decl.Devices)
			byDevice[dkey] = i
			decl.Devices = append(decl.Devices, Device{DeviceKey: dkey})
		}
		decl.Devices[i].Metrics = append(decl.Devices[i].Metrics, BirthMetric{
			Name:        m.GetName(),
			Alias:       m.GetAlias(),
			Datatype:    datatypeName(m.GetDatatype()),
			CounterRole: role,
			SourceRef:   sref,
		})
	}
	return decl
}

// readProps pulls (counter_role, source_ref, device_key) out of a metric's
// PropertySet. ok=false when there is no counter_role property (a non-counter
// metric, or a birth emitted with the definitive flag OFF).
func readProps(m *sparkplug.Metric) (role, sref, dkey string, ok bool) {
	ps := m.GetProperties()
	if ps == nil {
		return "", "", "", false
	}
	keys, vals := ps.GetKeys(), ps.GetValues()
	for i, k := range keys {
		if i >= len(vals) {
			break
		}
		v := vals[i].GetStringValue()
		switch k {
		case PropCounterRole:
			role = v
		case PropSourceRef:
			sref = v
		case PropDeviceKey:
			dkey = v
		}
	}
	if role == "" {
		return "", "", "", false
	}
	return role, sref, dkey, true
}

// datatypeName maps a SparkPlug numeric datatype code to the schema's datatype
// token (the closed enum in schemas/edge-birth-declaration.schema.json). An
// unmapped code yields "" (the field is optional).
func datatypeName(code uint32) string {
	switch sparkplug.DataType(code) {
	case sparkplug.DataType_Int32:
		return "Int32"
	case sparkplug.DataType_Int64:
		return "Int64"
	case sparkplug.DataType_UInt32:
		return "UInt32"
	case sparkplug.DataType_UInt64:
		return "UInt64"
	case sparkplug.DataType_Float:
		return "Float"
	case sparkplug.DataType_Double:
		return "Double"
	default:
		return ""
	}
}

// validDatatypes mirrors the schema's metric.datatype enum.
var validDatatypes = map[string]bool{
	"Int32": true, "Int64": true, "UInt32": true, "UInt64": true,
	"Float": true, "Double": true,
}

// validRoles mirrors the schema's metric.counter_role enum (§4 closed enum).
var validRoles = map[string]bool{RoleGross: true, RoleNet: true, RoleScrap: true}

// Validate enforces the birth-declaration schema's structural rules in Go
// (required fields, the counter_role + datatype closed enums, alias>=1,
// non-empty device metric sets). It is the code mirror of
// schemas/edge-birth-declaration.schema.json; the package test asserts the two
// stay in sync by loading the schema file's enums and by round-tripping the
// canonical golden fixtures through it.
func (d Declaration) Validate() error {
	if strings.TrimSpace(d.GroupID) == "" {
		return fmt.Errorf("group_id is required")
	}
	if strings.TrimSpace(d.EdgeNodeID) == "" {
		return fmt.Errorf("edge_node_id is required")
	}
	if len(d.Devices) == 0 {
		return fmt.Errorf("devices is required (nothing declared)")
	}
	for i, dev := range d.Devices {
		if strings.TrimSpace(dev.DeviceKey) == "" {
			return fmt.Errorf("devices[%d]: device_key is required", i)
		}
		if len(dev.Metrics) == 0 {
			return fmt.Errorf("devices[%d] (%s): metrics is required", i, dev.DeviceKey)
		}
		for j, m := range dev.Metrics {
			if m.Alias < 1 {
				return fmt.Errorf("devices[%d] (%s): metrics[%d].alias must be >= 1", i, dev.DeviceKey, j)
			}
			if !validRoles[m.CounterRole] {
				return fmt.Errorf("devices[%d] (%s): metrics[%d].counter_role=%q must be gross|net|scrap",
					i, dev.DeviceKey, j, m.CounterRole)
			}
			if m.Datatype != "" && !validDatatypes[m.Datatype] {
				return fmt.Errorf("devices[%d] (%s): metrics[%d].datatype=%q is not a valid SparkPlug datatype",
					i, dev.DeviceKey, j, m.Datatype)
			}
		}
	}
	return nil
}
