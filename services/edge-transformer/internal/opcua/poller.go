// Package opcua reads an OPC-UA server and turns configured nodes into
// PackML/SparkPlug metrics — the OPC-UA sibling of the S7 and Modbus readers.
// It is an additive SparkPlug PRODUCER (publishes NBIRTH/NDATA over MQTT exactly
// like plc-sim and a real SparkPlug PLC), so the edge-transformer
// decode→transform→publish pipeline consumes it unchanged. CPACK runs S7 +
// Modbus TCP + OPC-UA across its lines; this is the OPC-UA half of the gap.
//
// Unlike S7/Modbus, OPC-UA is a self-describing, typed protocol: a value is
// addressed by a NodeID (e.g. "ns=2;s=Machine.Speed" — namespace index + string
// identifier) and the server returns an already-typed Variant, not raw bytes.
// So there is no byte-decode step here; instead decodeFloat coerces the typed
// value the server sent into the float64 currency the SparkPlug emission uses.
//
// MVP model: POLLING, not subscriptions. Each tick we issue one batched Read of
// every node's Value attribute — the simplest thing that mirrors the S7/Modbus
// tick loop. Subscriptions (MonitoredItems, server-pushed change
// notifications) are the efficient production model and are noted as follow-up.
package opcua

import (
	"fmt"
	"strconv"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// Type is how the poller coerces a node's server-typed Variant into a number.
//   - TypeInt / TypeFloat / TypeBool are the numeric datatypes an OPC-UA node
//     typically exposes.
//   - TypeString handles servers that expose a numeric value as a string node
//     ("123.4") — we strconv.ParseFloat it. Non-numeric strings error.
type Type int

const (
	TypeInt    Type = iota // integer node → float64
	TypeFloat              // floating node → float64
	TypeBool               // boolean node → 0/1
	TypeString             // stringified number → parsed float64
)

// Tag binds one OPC-UA NodeID to one PackML/SparkPlug metric — the OPC-UA
// analogue of s7.Tag / modbus.Tag.
//
//   - Metric is the FULL SparkPlug metric name (the PackML topic path). Its
//     first segment is the tenant/group_id — the same convention plc-sim and
//     the packml_register routing use.
//   - Alias is the SparkPlug alias for compact NDATA (name↔alias bound in the
//     retained NBIRTH).
//   - NodeID is the OPC-UA address string ("ns=2;s=Machine.Speed", "ns=3;i=42").
//   - Type coerces the server's Variant to a number.
//   - Long emits as a SparkPlug Long (integer state metrics) rather than Double.
//   - Scale multiplies the raw value (0 means 1 — no scaling).
type Tag struct {
	Metric string
	Alias  uint64
	NodeID string
	Type   Type
	Long   bool
	Scale  float64
}

// ReadFunc reads the Value attribute of every nodeID in one batch, returning
// one value per nodeID in the SAME order (nil for a node the server could not
// read — e.g. bad status). The OPC-UA client satisfies it; tests inject a fake
// so the poller needs no live server — the same seam trick as internal/s7.
type ReadFunc func(nodeIDs []string) ([]any, error)

// Poller turns a set of OPC-UA tags into SparkPlug NBIRTH/NDATA payloads. One
// Poller drives one edge node (one OPC-UA session); it holds the SparkPlug
// sequence counter across ticks.
type Poller struct {
	Tags []Tag
	seq  uint64
}

// NewPoller validates the tags and returns a poller.
func NewPoller(tags []Tag) (*Poller, error) {
	if len(tags) == 0 {
		return nil, fmt.Errorf("opcua poller: no tags configured")
	}
	seen := map[uint64]bool{}
	for i, t := range tags {
		if t.Metric == "" {
			return nil, fmt.Errorf("opcua poller: tag %d has empty metric name", i)
		}
		if t.NodeID == "" {
			return nil, fmt.Errorf("opcua poller: tag %q has empty node id", t.Metric)
		}
		if t.Alias == 0 {
			return nil, fmt.Errorf("opcua poller: tag %q has zero alias", t.Metric)
		}
		if seen[t.Alias] {
			return nil, fmt.Errorf("opcua poller: duplicate alias %d (%q)", t.Alias, t.Metric)
		}
		seen[t.Alias] = true
	}
	return &Poller{Tags: tags}, nil
}

// nodeIDs returns the tag NodeIDs in config order — the batch to read.
func (p *Poller) nodeIDs() []string {
	ids := make([]string, len(p.Tags))
	for i, t := range p.Tags {
		ids[i] = t.NodeID
	}
	return ids
}

// coerce turns a server-typed value into a float64 per the tag's Type. ok is
// false when the value is nil (unreadable node) or a string that isn't numeric.
func coerce(v any, t Type) (float64, bool) {
	if v == nil {
		return 0, false
	}
	switch t {
	case TypeBool:
		if b, ok := v.(bool); ok {
			if b {
				return 1, true
			}
			return 0, true
		}
		return toFloat(v)
	case TypeString:
		if s, ok := v.(string); ok {
			f, err := strconv.ParseFloat(s, 64)
			return f, err == nil
		}
		return toFloat(v)
	default: // TypeInt, TypeFloat
		return toFloat(v)
	}
}

// toFloat coerces any of Go's numeric kinds (the concrete types gopcua yields
// from a Variant) to float64.
func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int:
		return float64(n), true
	case int8:
		return float64(n), true
	case int16:
		return float64(n), true
	case int32:
		return float64(n), true
	case int64:
		return float64(n), true
	case uint:
		return float64(n), true
	case uint8:
		return float64(n), true
	case uint16:
		return float64(n), true
	case uint32:
		return float64(n), true
	case uint64:
		return float64(n), true
	case bool:
		if n {
			return 1, true
		}
		return 0, true
	default:
		return 0, false
	}
}

// Sample reads every tag's current value via read and returns the decoded
// SparkPlug metrics. When birth is true the metric NAMES are included (for an
// NBIRTH alias table); otherwise only aliases + values are emitted (NDATA).
func (p *Poller) Sample(read ReadFunc, birth bool) ([]sparkplug.SimMetric, error) {
	vals, err := read(p.nodeIDs())
	if err != nil {
		return nil, fmt.Errorf("opcua read: %w", err)
	}
	if len(vals) != len(p.Tags) {
		return nil, fmt.Errorf("opcua read: got %d values for %d tags", len(vals), len(p.Tags))
	}

	ms := make([]sparkplug.SimMetric, 0, len(p.Tags))
	for i, t := range p.Tags {
		raw, ok := coerce(vals[i], t.Type)
		if !ok {
			return nil, fmt.Errorf("opcua decode %q (node %s): unreadable or non-numeric value %v", t.Metric, t.NodeID, vals[i])
		}
		scale := t.Scale
		if scale == 0 {
			scale = 1
		}
		v := raw * scale

		m := sparkplug.SimMetric{Alias: t.Alias}
		if birth {
			m.Name = t.Metric
		}
		if t.Long {
			m.Long = int64(v)
			m.IsLong = true
		} else {
			m.Double = v
		}
		ms = append(ms, m)
	}
	return ms, nil
}

// EncodeBirth samples all tags and encodes a retained NBIRTH (resets the seq).
func (p *Poller) EncodeBirth(read ReadFunc) ([]byte, error) {
	ms, err := p.Sample(read, true)
	if err != nil {
		return nil, err
	}
	return sparkplug.EncodeSim(ms, &p.seq, true)
}

// EncodeData samples all tags and encodes an NDATA (advances the seq).
func (p *Poller) EncodeData(read ReadFunc) ([]byte, error) {
	ms, err := p.Sample(read, false)
	if err != nil {
		return nil, err
	}
	return sparkplug.EncodeSim(ms, &p.seq, false)
}
