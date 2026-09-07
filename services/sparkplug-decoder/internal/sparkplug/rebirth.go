// SparkPlug B Rebirth mechanism — the durable self-heal for a stateful
// consumer that restarts and loses its per-publisher alias + counter baseline
// (task #31, ADR-0042).
//
// The spec mechanism (Tahu / SparkPlug B §"Node Control/Rebirth"): a host
// application that detects a sequence gap, a missing NBIRTH, or NDATA before
// NBIRTH publishes an NCMD to
//
//	spBv1.0/<GroupID>/NCMD/<EdgeNodeID>
//
// carrying the boolean metric "Node Control/Rebirth" = true. The edge node,
// on receiving it, MUST re-publish its full NBIRTH (complete metric + alias
// snapshot, seq reset to 0), which re-seeds the consumer.
//
// This file provides the two pure helpers both sides share: the ET (consumer)
// builds+encodes the NCMD, the agent (edge node) recognises it in a decoded
// payload. Keeping them in one place guarantees the metric name + datatype
// stay byte-identical across the request/response pair — a mismatch here would
// silently break the rebirth loop with no error anywhere.
package sparkplug

import "time"

// MetricNodeControlRebirth is the well-known SparkPlug B metric name that
// carries the rebirth request. Case + spacing are load-bearing: the edge node
// matches on the exact string.
const MetricNodeControlRebirth = "Node Control/Rebirth"

// BuildRebirthNCMD builds the NCMD payload that asks an edge node to re-publish
// its NBIRTH: a single boolean metric "Node Control/Rebirth" = true, stamped
// with the current time. NCMD does NOT participate in the rolling NDATA seq
// (it travels host→edge, out of band), so Seq is left unset.
func BuildRebirthNCMD() *Payload {
	ts := uint64(time.Now().UnixMilli())
	dt := uint32(DataType_Boolean.Number())
	name := MetricNodeControlRebirth
	return &Payload{
		Timestamp: &ts,
		Metrics: []*Metric{
			{
				Name:      &name,
				Timestamp: &ts,
				Datatype:  &dt,
				Value:     &Metric_BooleanValue{BooleanValue: true},
			},
		},
	}
}

// EncodeRebirthNCMD is BuildRebirthNCMD + Encode — the one call the consumer
// needs to produce the wire bytes.
func EncodeRebirthNCMD() ([]byte, error) {
	return Encode(BuildRebirthNCMD())
}

// IsRebirthRequest reports whether a decoded NCMD payload carries a truthy
// "Node Control/Rebirth" metric. Used by the edge node to decide whether an
// inbound NCMD is a rebirth trigger. A nil payload or a metric present-but-
// false returns false.
func IsRebirthRequest(p *Payload) bool {
	if p == nil {
		return false
	}
	for _, m := range p.GetMetrics() {
		if m.GetName() == MetricNodeControlRebirth {
			if _, ok := m.GetValue().(*Metric_BooleanValue); ok {
				return m.GetBooleanValue()
			}
		}
	}
	return false
}
