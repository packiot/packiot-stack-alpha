// Package sparkplug parses raw SparkPlug B-style payloads into typed
// values the writers can consume. Mirrors the logic in
// oeecloud-node-red/flows/01 · Ingestion & Writes.json "Prep" + "UPSERT"
// nodes, but split into testable Go functions.
package sparkplug

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Payload is the raw envelope edge-nodered publishes to the `oee` exchange.
// Shape (from /plc-data HTTP-in):
//
//	{
//	  "timestamp": 1782161858551,
//	  "gateway":   "simulator" | "edge-nodered" | ...,
//	  "metrics": [
//	    { "name": "CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent",
//	      "timestamp": 1782161858551,
//	      "value": 6, "counter": 12345, "curspeed": 120, "id": 30700, ... }
//	  ]
//	}
//
// Per-metric optional fields (counter, curspeed, alias, faults, id,
// user, category_code, etc.) are kept as raw json.RawMessage so we don't
// pay parse cost for fields a given writer doesn't need.
type Payload struct {
	Timestamp int64    `json:"timestamp"`
	Gateway   string   `json:"gateway"`
	Metrics   []Metric `json:"metrics"`
	// SourceType identifies which upstream pipeline produced this envelope.
	// Absent (empty) or "nodered" → oeecloud-node-red / edge-nodered SparkPlug
	// subflow; routes to public.* tables.
	// "go" → produced by edge-transformer's Calc Production Counters Go port
	// (ADR-0010 Phase 3 shadow mode); routes to shadow_go_port.* tables so
	// both paths can be compared row-by-row via shadow_diff.* views WITHOUT
	// contaminating production data.
	SourceType string `json:"source_type,omitempty"`
}

type Metric struct {
	Name      string          `json:"name"`
	Timestamp int64           `json:"timestamp"`
	Value     json.RawMessage `json:"value"`
	Counter   *jsonFloat      `json:"counter,omitempty"`
	CurSpeed  *jsonFloat      `json:"curspeed,omitempty"`
	Alias     json.RawMessage `json:"alias,omitempty"`
	Faults    json.RawMessage `json:"faults,omitempty"`
	ID        *jsonInt        `json:"id,omitempty"`
}

// Parse unmarshals the raw AMQP body. Returns an error caller can return
// upward — the AMQP consumer will nack → DLX → retry, so malformed messages
// land in oee-failed after MaxRetries.
func Parse(body []byte) (*Payload, error) {
	var p Payload
	if err := json.Unmarshal(body, &p); err != nil {
		return nil, fmt.Errorf("unmarshal payload: %w", err)
	}
	return &p, nil
}

// IsJSONStringBody reports whether body's top-level JSON value is a STRING
// (`"..."`) rather than the OBJECT (`{...}`) every valid envelope is. This is
// the exact wire signature of a DOUBLE-ENCODED envelope: a producer that
// marshals an already-serialized JSON payload a second time emits
// `"{\"timestamp\":...}"` — a JSON string of JSON. Parse necessarily fails on
// it with `json: cannot unmarshal string into Go value of type
// sparkplug.Payload`, and because the delivered bytes are fixed, retrying can
// NEVER succeed. Callers use this to drop-and-count the delivery instead of
// nack-retrying it into a poison storm (task #92 — the consumer-side backstop
// to the producer removal in #475/#22 and the wire contract pinned in
// TestParse_EncodingContract, task #14).
//
// Cheap: skips leading JSON insignificant-whitespace (RFC 8259 §2: space, tab,
// LF, CR) and checks the first structural byte. No allocation, no full parse —
// safe on the hot per-delivery path.
func IsJSONStringBody(body []byte) bool {
	for _, b := range body {
		switch b {
		case ' ', '\t', '\n', '\r':
			continue
		case '"':
			return true
		default:
			return false
		}
	}
	return false
}

// jsonFloat accepts either a JSON number (120) or a quoted numeric string
// ("120", "120.4"). Some edge clients — notably Incoplast's PackML2SparkPlug
// node — encode counter/curspeed as strings; standard clients (CPACK) send
// numbers. Both coerce to float64, so this is backward-compatible.
type jsonFloat float64

func (f *jsonFloat) UnmarshalJSON(b []byte) error {
	t := strings.TrimSpace(string(b))
	if t == "" || t == "null" {
		return nil
	}
	s := strings.Trim(t, `"`) // strip quotes if it arrived as a string
	if s == "" {
		return nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return fmt.Errorf("jsonFloat %q: %w", t, err)
	}
	*f = jsonFloat(v)
	return nil
}

// jsonInt accepts either a JSON number (4) or a quoted numeric string ("4").
// Incoplast's PackML2SparkPlug node encodes the metric `id` as a string;
// standard clients (CPACK) send a number. Both coerce to int — backward
// compatible. Sibling of jsonFloat (same Incoplast string-encoding quirk);
// without it the whole payload fails to unmarshal and every metric in it is
// lost. Tolerates a trailing ".0" (some clients stringify floats).
type jsonInt int

func (n *jsonInt) UnmarshalJSON(b []byte) error {
	t := strings.TrimSpace(string(b))
	if t == "" || t == "null" {
		return nil
	}
	s := strings.Trim(t, `"`) // strip quotes if it arrived as a string
	if s == "" {
		return nil
	}
	v, err := strconv.ParseFloat(s, 64) // ParseFloat tolerates "4" and "4.0"
	if err != nil {
		return fmt.Errorf("jsonInt %q: %w", t, err)
	}
	*n = jsonInt(int(v))
	return nil
}

// MetricKind tells writers which table/columns the metric belongs to.
// Derived from the Sparkplug topic segments — see Classify().
type MetricKind int

const (
	KindUnknown MetricKind = iota

	// equipment_values writers
	KindProdProcessedCount // net_production_incr / net_production_val
	KindProdConsumedCount  // gross_production_incr / gross_production_val
	KindProdDefectiveCount // scrap_incr / scrap_val

	// equipment_events writer (separate handler — task #28)
	KindStateCurrent
	KindUnitModeCurrent

	// uns_equipment_current_metrics writer (separate handler — task #28)
	KindCurMachSpeed

	// PO control parameter (separate handler — task #28)
	KindParameter // metric.ID in 30700-30899 range — line config / PO control
)

func (k MetricKind) String() string {
	switch k {
	case KindProdProcessedCount:
		return "ProdProcessedCount"
	case KindProdConsumedCount:
		return "ProdConsumedCount"
	case KindProdDefectiveCount:
		return "ProdDefectiveCount"
	case KindStateCurrent:
		return "StateCurrent"
	case KindUnitModeCurrent:
		return "UnitModeCurrent"
	case KindCurMachSpeed:
		return "CurMachSpeed"
	case KindParameter:
		return "Parameter"
	default:
		return "Unknown"
	}
}

// Classify identifies the metric kind from its name. Mirrors the topic_type
// derivation in the Prep node:
//
//	Enterprise/Site/Area/Sect/{Admin|Status|Command}/{TYPE}        — LINE metric (topic_unit=0)
//	Enterprise/Site/Area/Sect/Unit/{Admin|Status|Command}/{TYPE}   — UNIT metric
//
// Examples (5+ segments):
//
//	CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent                 → KindStateCurrent
//	CPACK/SC/SLEEVE/SLEEVE1/Status/CurMachSpeed                 → KindCurMachSpeed
//	CPACK/SC/SLEEVE/SLEEVE1/Status/UnitModeCurrent              → KindUnitModeCurrent
//	CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdProcessedCount/N/Unit → KindProdProcessedCount
//	CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdConsumedCount/N/Unit  → KindProdConsumedCount
//	CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdDefectiveCount/N/Unit → KindProdDefectiveCount
//
// Returns KindUnknown for topics that don't match a known pattern (worker
// logs + acks them — won't nack to retry, because retry won't change the
// classification).
func (m *Metric) Classify() MetricKind {
	parts := strings.Split(m.Name, "/")
	// Find the *last* segment that looks like a known type. The proc layer
	// (Admin/Status/Command) sits at varying positions depending on whether
	// it's a Line (proc at idx 4) or Unit (proc at idx 5) topic.
	for i := len(parts) - 1; i >= 0; i-- {
		switch parts[i] {
		case "StateCurrent":
			return KindStateCurrent
		case "UnitModeCurrent":
			return KindUnitModeCurrent
		case "CurMachSpeed":
			return KindCurMachSpeed
		case "ProdProcessedCount":
			return KindProdProcessedCount
		case "ProdConsumedCount":
			return KindProdConsumedCount
		case "ProdDefectiveCount":
			return KindProdDefectiveCount
		case "Parameter":
			// Confirm by checking the metric.id range (30700-30899). If id
			// is absent, treat as Unknown — Parameter without an id isn't
			// actionable.
			if m.ID != nil && *m.ID >= 30700 && *m.ID <= 30899 {
				return KindParameter
			}
		}
	}
	return KindUnknown
}

// CanonicalTopic returns the topic key used to look up packml_register.
// The Prep node truncates to the first 5 segments. For shorter topics it
// returns whatever is present (4-segment line topics resolve via the
// 4-segment register row directly).
//
//	CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdProcessedCount/123/Unit
//	  → CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1
//
//	CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent
//	  → CPACK/SC/SLEEVE/SLEEVE1/Status  (5 segments)
//
// Note: the second example exposes a wart — the canonical-5 truncation
// includes the proc segment for short topics. The Node-RED Prep node
// rewrites this case so the looked-up topic becomes just the line/unit
// without /Status. Worker mirrors that via TopicForRegister below.
func (m *Metric) CanonicalTopic() string {
	parts := strings.Split(m.Name, "/")
	if len(parts) > 5 {
		parts = parts[:5]
	}
	return strings.Join(parts, "/")
}

// TopicForRegister returns the topic to look up in packml_register, applying
// the Prep node's special-cases:
//
//   - If segment 4 is one of {Admin, Status, Command} (i.e. a LINE-level
//     metric like CPACK/SC/SLEEVE/SLEEVE1/Status/StateCurrent or
//     CPACK/SC/LINHAS/L5/Admin/ProdProcessedCount/N/Unit), the packml_register
//     row is the 4-segment line topic — drop everything from segment 4 on.
//   - Else use CanonicalTopic (first 5 segments) — this handles UNIT
//     topics like CPACK/SC/CELULA1/HOTMADAG/HOTMADAG/Admin/...
//
// Matches the Prep node's `if topicStr[4] in {Admin,Status,Command} →
// topic_name = topicStr[0..3].join("/")`. Strips with EqualFold for
// case-insensitive matching (Sparkplug topics vary in case across PLCs).
func (m *Metric) TopicForRegister() string {
	parts := strings.Split(m.Name, "/")
	if len(parts) >= 5 {
		switch strings.ToLower(parts[4]) {
		case "admin", "status", "command":
			// Line-level metric — drop the proc segment and everything after.
			// packml_register row is the 4-segment line topic.
			return strings.Join(parts[:4], "/")
		}
	}
	if len(parts) > 5 {
		parts = parts[:5]
	}
	return strings.Join(parts, "/")
}

// IsLineTopic returns true when the metric belongs to a Line (tp_equipment=3)
// rather than a Unit (tp_equipment=1). Used by writers to set the
// equipment_values.tp_equipment column.
//
// Mirrors Prep's logic: topic_unit == 0 means line, otherwise unit.
// Detected here from segment positions:
//
//	parts[4] in {Admin,Status,Command}  → line (proc at idx 4)
//	otherwise                            → unit (proc at idx 5)
func (m *Metric) IsLineTopic() bool {
	parts := strings.Split(m.Name, "/")
	if len(parts) < 5 {
		// Too short to classify — treat as line. Caller can override.
		return true
	}
	switch strings.ToLower(parts[4]) {
	case "admin", "status", "command":
		return true
	}
	return false
}
