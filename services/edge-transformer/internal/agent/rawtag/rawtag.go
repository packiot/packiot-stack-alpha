// Package rawtag is the Tier-1 → Tier-2 wire contract (ADR-0042 §2.3): the
// plain-JSON raw-tag envelope a connectivity Node-RED publishes over the
// INTERNAL loopback MQTT topic, and its decoded per-tag form.
//
// The contract's teeth (ADR-0042 §2.3 CI-lintable invariants):
//   - Tier 1 emits tag SUFFIX names only (e.g. "/Status/MachSpeed") — the
//     agent prepends the packml_topic prefix from client.yaml.
//   - Tier 1 never constructs an alias, a sequence number, or a protobuf
//     byte. The internal hop is SparkPlug-IGNORANT plain JSON (§2.4: no WAN,
//     no session, no second tenant on a loopback — standardize only at the
//     crossing that needs it).
//
// The agent's alias-ASSIGN allocator, RBE dirty-tracking, and SparkPlug
// session state machine all consume []RawTag — never the raw JSON.
package rawtag

import (
	"encoding/json"
	"fmt"
)

// RawTag is one decoded tag reading from the Tier-1 envelope. Metric is the
// SUFFIX only (the packml_topic prefix is config, prepended downstream in
// session.Publisher — the s7/mapping.go PackMLTopic+Metric discipline).
type RawTag struct {
	// EndpointOrPath is the connectivity-plane endpoint/device this reading
	// came from (envelope "endpoint"). Diagnostic + future per-device DBIRTH
	// scoping (ADR-0042 open-Q4); not part of the SparkPlug name today.
	EndpointOrPath string

	// Metric is the tag SUFFIX (e.g. "/Status/MachSpeed"). The full SparkPlug
	// metric name is packml_topic + Metric, resolved in session.Publisher.
	Metric string

	// Value is the decoded JSON scalar: float64, bool, or string. The
	// authoritative SparkPlug datatype is resolved from the agent's
	// raw_tag_map (config), not inferred from this Go type.
	Value any

	// Type is the optional wire type hint ("long" when the envelope tag
	// carries `"long": true`). Advisory only — config is authoritative.
	Type string

	// TsMillis is the reading timestamp in unix-millis. Falls back to the
	// envelope scan_ts when a tag omits its own.
	TsMillis int64

	// Quality is the tag quality flag (envelope "q"). Absent ⇒ good (true):
	// a connectivity plane that omits quality is asserting a good read.
	Quality bool
}

// envelope is the on-wire JSON shape (ADR-0042 §2.3): an endpoint + scan
// timestamp + a list of suffix-named tag readings.
type envelope struct {
	Endpoint string        `json:"endpoint"`
	ScanTS   int64         `json:"scan_ts"`
	Tags     []envelopeTag `json:"tags"`
}

type envelopeTag struct {
	Metric string          `json:"metric"`
	Value  json.RawMessage `json:"value"`
	Q      *bool           `json:"q,omitempty"`    // absent ⇒ good
	Long   bool            `json:"long,omitempty"` // type hint
	TS     int64           `json:"ts,omitempty"`   // per-tag override of scan_ts
}

// Decode parses one raw-tag envelope body into per-tag readings. An empty
// tags list decodes to an empty slice (not an error — a heartbeat scan with
// no changes is legal). A malformed body or a tag with an unparseable value
// is an error the caller drops-with-metric.
func Decode(body []byte) ([]RawTag, error) {
	var env envelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("rawtag: decode envelope (%d bytes): %w", len(body), err)
	}
	out := make([]RawTag, 0, len(env.Tags))
	for i, t := range env.Tags {
		if t.Metric == "" {
			return nil, fmt.Errorf("rawtag: tags[%d]: empty metric suffix", i)
		}
		val, err := decodeValue(t.Value)
		if err != nil {
			return nil, fmt.Errorf("rawtag: tags[%d] (%s): %w", i, t.Metric, err)
		}
		ts := t.TS
		if ts == 0 {
			ts = env.ScanTS
		}
		quality := true
		if t.Q != nil {
			quality = *t.Q
		}
		typ := ""
		if t.Long {
			typ = "long"
		}
		out = append(out, RawTag{
			EndpointOrPath: env.Endpoint,
			Metric:         t.Metric,
			Value:          val,
			Type:           typ,
			TsMillis:       ts,
			Quality:        quality,
		})
	}
	return out, nil
}

// decodeValue turns a raw JSON scalar into float64 | bool | string. Numbers
// always land as float64 (JSON's only numeric type) — the SparkPlug datatype
// coercion (Int64 vs Double vs Float) happens in session.Publisher against
// the config type, so we never guess int-vs-float from the wire here.
func decodeValue(raw json.RawMessage) (any, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, fmt.Errorf("value %q: %w", string(raw), err)
	}
	switch v.(type) {
	case float64, bool, string:
		return v, nil
	default:
		return nil, fmt.Errorf("value %q: not a scalar (number/bool/string)", string(raw))
	}
}
