package s7

import (
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// Tag binds one S7 address to one PackML/SparkPlug metric.
//
//   - Metric is the FULL SparkPlug metric name (the PackML topic path, e.g.
//     "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15/NOVOFLEX_15/Status/MachSpeed").
//     Its first segment is the tenant/group_id — the same convention plc-sim
//     and the packml_register routing use.
//   - Alias is the SparkPlug alias for compact NDATA (name↔alias bound in the
//     retained NBIRTH, mirroring plc-sim).
//   - DB/Offset/Bit/Type address the value in the PLC data block.
//   - Long emits the value as a SparkPlug Long (integer state metrics like
//     StateCurrent) rather than a Double (counters, speed).
//   - Scale multiplies the raw value (0 means 1 — no scaling).
type Tag struct {
	Metric string
	Alias  uint64
	DB     int
	Offset int
	Bit    int
	Type   Type
	Long   bool
	Scale  float64
}

// ReadFunc reads `size` bytes from data block `db` starting at `start`. The S7
// client satisfies it; tests inject a fake so the poller needs no live PLC.
type ReadFunc func(db, start, size int) ([]byte, error)

// Poller turns a set of S7 tags into SparkPlug NBIRTH/NDATA payloads. One
// Poller drives one edge node (one PLC session); it holds the SparkPlug
// sequence counter across ticks.
type Poller struct {
	Tags []Tag
	seq  uint64
}

// NewPoller validates the tags and returns a poller.
func NewPoller(tags []Tag) (*Poller, error) {
	if len(tags) == 0 {
		return nil, fmt.Errorf("s7 poller: no tags configured")
	}
	seen := map[uint64]bool{}
	for i, t := range tags {
		if t.Metric == "" {
			return nil, fmt.Errorf("s7 poller: tag %d has empty metric name", i)
		}
		if t.Alias == 0 {
			return nil, fmt.Errorf("s7 poller: tag %q has zero alias", t.Metric)
		}
		if seen[t.Alias] {
			return nil, fmt.Errorf("s7 poller: duplicate alias %d (%q)", t.Alias, t.Metric)
		}
		seen[t.Alias] = true
		if t.Type.Width() == 0 {
			return nil, fmt.Errorf("s7 poller: tag %q has unknown type", t.Metric)
		}
	}
	return &Poller{Tags: tags}, nil
}

// dbReadPlan groups tags by data block and computes the byte span to read for
// each — one AGReadDB per DB per tick, regardless of tag count.
func (p *Poller) dbReadPlan() map[int]int {
	plan := map[int]int{}
	for _, t := range p.Tags {
		if end := t.Offset + t.Type.Width(); end > plan[t.DB] {
			plan[t.DB] = end
		}
	}
	return plan
}

// Sample reads every tag's current value via read and returns the decoded
// SparkPlug metrics. When birth is true the metric NAMES are included (for an
// NBIRTH alias table); otherwise only aliases + values are emitted (NDATA).
func (p *Poller) Sample(read ReadFunc, birth bool) ([]sparkplug.SimMetric, error) {
	bufs := make(map[int][]byte, 4)
	for db, size := range p.dbReadPlan() {
		b, err := read(db, 0, size)
		if err != nil {
			return nil, fmt.Errorf("s7 read DB%d: %w", db, err)
		}
		bufs[db] = b
	}

	ms := make([]sparkplug.SimMetric, 0, len(p.Tags))
	for _, t := range p.Tags {
		raw, ok := decodeFloat(bufs[t.DB], t)
		if !ok {
			return nil, fmt.Errorf("s7 decode %q: DB%d buffer too short for offset %d", t.Metric, t.DB, t.Offset)
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
