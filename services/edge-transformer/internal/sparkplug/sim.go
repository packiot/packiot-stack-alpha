// sim.go — payload construction helpers for plc-sim (10.9-staging).
// Thin sugar over the protobuf types so the simulator reads like a
// topology description instead of proto plumbing.
package sparkplug

import "time"

// SimMetric is one metric in a simulator NBIRTH/NDATA.
//   - NBIRTH: set Name + Alias (+ value fields).
//   - NDATA: set Alias only (alias-reference form, the wire-efficient
//     shape the StateStore resolves).
type SimMetric struct {
	Name   string
	Alias  uint64
	Double float64
	Long   int64
	Text   string
	IsLong bool
	IsText bool
}

// EncodeSim builds and encodes a payload from SimMetrics, advancing
// the Sparkplug seq counter (NBIRTH resets it to 0 per spec).
func EncodeSim(ms []SimMetric, seq *uint64, isBirth bool) ([]byte, error) {
	ts := nowMillis()
	if isBirth {
		*seq = 0
	} else {
		*seq = (*seq + 1) % 256
	}
	p := &Payload{Timestamp: &ts, Seq: simU64(*seq)}
	for _, m := range ms {
		pm := &Metric{Alias: simU64(m.Alias), Timestamp: &ts}
		if m.Name != "" {
			n := m.Name
			pm.Name = &n
		}
		switch {
		case m.IsText:
			pm.Datatype = simU32(uint32(DataType_String))
			pm.Value = &Metric_StringValue{StringValue: m.Text}
		case m.IsLong:
			pm.Datatype = simU32(uint32(DataType_Int64))
			pm.Value = &Metric_LongValue{LongValue: uint64(m.Long)}
		default:
			pm.Datatype = simU32(uint32(DataType_Double))
			pm.Value = &Metric_DoubleValue{DoubleValue: m.Double}
		}
		p.Metrics = append(p.Metrics, pm)
	}
	if isBirth {
		bd := "bdSeq"
		p.Metrics = append(p.Metrics, &Metric{
			Name: &bd, Timestamp: &ts,
			Datatype: simU32(uint32(DataType_Int64)),
			Value:    &Metric_LongValue{LongValue: 0},
		})
	}
	return Encode(p)
}

// Second-aligned: the worker's shift-fill companion (and prod's
// trigger semantics) key rows on second-truncated timestamps; ms
// precision made the fill's WHERE match nothing (100% NULL hours
// post-cutover — the parity check that caught it).
func nowMillis() uint64 { return uint64(time.Now().Truncate(time.Second).UnixMilli()) }

func simU64(v uint64) *uint64 { return &v }
func simU32(v uint32) *uint32 { return &v }
