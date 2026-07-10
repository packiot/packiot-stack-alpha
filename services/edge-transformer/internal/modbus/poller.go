package modbus

import (
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// Tag binds one Modbus address to one PackML/SparkPlug metric — the Modbus
// analogue of s7.Tag.
//
//   - Metric is the FULL SparkPlug metric name (the PackML topic path). Its
//     first segment is the tenant/group_id — the same convention plc-sim and
//     the packml_register routing use.
//   - Alias is the SparkPlug alias for compact NDATA (name↔alias bound in the
//     retained NBIRTH, mirroring plc-sim and the s7-reader).
//   - Kind selects the address space / function code (holding|input|coil|discrete).
//   - Address is the 0-based register or coil address.
//   - Quantity is how many registers the tag spans in the batch read plan
//     (0 = derive from Type). Register tags default to Type.Regs(); bit tags to 1.
//   - Type is the value encoding for register kinds (ignored for coil/discrete).
//   - WordSwap flips the two registers of a 32-bit value (CDAB vs ABCD) — a
//     device quirk (see decode.go). Ignored for 16-bit and bit tags.
//   - Long emits as a SparkPlug Long (integer state metrics) rather than Double.
//   - Scale multiplies the raw value (0 means 1 — no scaling).
type Tag struct {
	Metric   string
	Alias    uint64
	Kind     Kind
	Address  uint16
	Quantity uint16
	Type     Type
	WordSwap bool
	Long     bool
	Scale    float64
}

// regs returns how many registers/coils this tag occupies in a read plan. An
// explicit Quantity overrides the type default (e.g. a device that packs a
// value into more registers than the type strictly needs).
func (t Tag) regs() int {
	if t.Quantity > 0 {
		return int(t.Quantity)
	}
	if t.Kind.IsBit() {
		return 1
	}
	return t.Type.Regs()
}

// ReadFunc reads `quantity` registers/coils of address space `kind` starting at
// `start`, returning the raw bytes (register bytes big-endian, or packed coil
// bits). The Modbus client satisfies it; tests inject a fake so the poller
// needs no live PLC — the same seam trick as internal/s7.
type ReadFunc func(kind Kind, start, quantity uint16) ([]byte, error)

// Poller turns a set of Modbus tags into SparkPlug NBIRTH/NDATA payloads. One
// Poller drives one edge node (one Modbus session); it holds the SparkPlug
// sequence counter across ticks.
type Poller struct {
	Tags []Tag
	seq  uint64
}

// NewPoller validates the tags and returns a poller.
func NewPoller(tags []Tag) (*Poller, error) {
	if len(tags) == 0 {
		return nil, fmt.Errorf("modbus poller: no tags configured")
	}
	seen := map[uint64]bool{}
	for i, t := range tags {
		if t.Metric == "" {
			return nil, fmt.Errorf("modbus poller: tag %d has empty metric name", i)
		}
		if t.Alias == 0 {
			return nil, fmt.Errorf("modbus poller: tag %q has zero alias", t.Metric)
		}
		if seen[t.Alias] {
			return nil, fmt.Errorf("modbus poller: duplicate alias %d (%q)", t.Alias, t.Metric)
		}
		seen[t.Alias] = true
		if !t.Kind.IsBit() && t.Type.Regs() == 0 {
			return nil, fmt.Errorf("modbus poller: tag %q has unknown type", t.Metric)
		}
	}
	return &Poller{Tags: tags}, nil
}

// readSpan is the contiguous [start, start+quantity) block to read for one Kind.
type readSpan struct {
	start, end uint16 // end is exclusive (start + total registers/coils)
}

// readPlan groups tags by Kind and computes the minimal contiguous span to read
// for each — one Modbus request per Kind per tick, regardless of tag count.
// Sparse addresses within a kind are covered by one span from min to max; the
// decoder picks each tag out by offset. (A huge address gap would over-read; in
// practice a machine's registers cluster, matching the s7 single-DB read.)
func (p *Poller) readPlan() map[Kind]readSpan {
	plan := map[Kind]readSpan{}
	for _, t := range p.Tags {
		end := t.Address + uint16(t.regs())
		s, ok := plan[t.Kind]
		if !ok {
			plan[t.Kind] = readSpan{start: t.Address, end: end}
			continue
		}
		if t.Address < s.start {
			s.start = t.Address
		}
		if end > s.end {
			s.end = end
		}
		plan[t.Kind] = s
	}
	return plan
}

// Sample reads every tag's current value via read and returns the decoded
// SparkPlug metrics. When birth is true the metric NAMES are included (for an
// NBIRTH alias table); otherwise only aliases + values are emitted (NDATA).
func (p *Poller) Sample(read ReadFunc, birth bool) ([]sparkplug.SimMetric, error) {
	bufs := make(map[Kind][]byte, 4)
	starts := make(map[Kind]uint16, 4)
	for kind, span := range p.readPlan() {
		b, err := read(kind, span.start, span.end-span.start)
		if err != nil {
			return nil, fmt.Errorf("modbus read %v[%d..%d): %w", kind, span.start, span.end, err)
		}
		bufs[kind] = b
		starts[kind] = span.start
	}

	ms := make([]sparkplug.SimMetric, 0, len(p.Tags))
	for _, t := range p.Tags {
		raw, ok := decodeFloat(bufs[t.Kind], t, starts[t.Kind])
		if !ok {
			return nil, fmt.Errorf("modbus decode %q: buffer too short for %v address %d", t.Metric, t.Kind, t.Address)
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
