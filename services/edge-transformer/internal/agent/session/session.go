// Package session is the producer-side SparkPlug B state machine (ADR-0042
// §2.2 net-new #4) — the mirror of the cloud consumer's internal/sparkplug
// StateStore. It mints NBIRTH (seq=0, full name↔alias table, bdSeq),
// NDATA (rolling seq, alias-only report-by-exception values), and NDEATH
// (bdSeq) for the MQTT Last-Will.
//
// bdSeq discipline (ADR-0042 open-Q1): bdSeq is a real monotonic counter, not
// the 0-stub s7-reader/plc-sim leave it at. The bdSeq carried in an NDEATH
// (registered as the Last-Will at connect) MUST equal the bdSeq in the NBIRTH
// of the SAME connection, so the cloud correlates death→birth. NewConnection
// advances it once per connection lifecycle.
package session

import (
	"fmt"
	"sync"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// Resolver maps a raw-tag metric SUFFIX to the full SparkPlug metric name +
// datatype. Backed by the agent's raw_tag_map (agentcfg).
type Resolver interface {
	// Resolve returns the full SparkPlug name + datatype for a suffix.
	// ok=false for an unmapped suffix (the caller skips it — it was meant to
	// be dropped-with-metric upstream).
	Resolve(suffix string) (name string, dt sparkplug.DataType, ok bool)
}

// Publisher is the SparkPlug B session state machine for one edge node.
// Concurrency: Build* + NewConnection are mutex-guarded; the agent calls them
// from the tick loop + the connect handler.
type Publisher struct {
	resolver Resolver
	aliases  *aliasmap.Table

	mu      sync.Mutex
	seq     uint64 // rolling NDATA sequence (mod 256); NBIRTH resets to 0
	bdSeq   uint64 // birth/death sequence — same value across a birth+its death
	started bool   // has the first connection cycle begun?
}

// New constructs a Publisher. The alias allocator is owned here so BIRTH and
// DATA share one stable name↔alias table.
func New(resolver Resolver, aliases *aliasmap.Table) *Publisher {
	return &Publisher{resolver: resolver, aliases: aliases}
}

// NewConnection advances the birth/death sequence for a new connection cycle
// and returns the value to stamp into BOTH this connection's NBIRTH and its
// NDEATH Last-Will. The first connection is bdSeq=0; each reconnect increments
// (mod 256). Call once per (re)connect, before registering the LWT.
func (p *Publisher) NewConnection() uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.started {
		p.bdSeq = (p.bdSeq + 1) & 0xff
	}
	p.started = true
	return p.bdSeq
}

// BdSeq returns the current birth/death sequence (diagnostic).
func (p *Publisher) BdSeq() uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.bdSeq
}

// Seq returns the current rolling NDATA sequence (diagnostic).
func (p *Publisher) Seq() uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.seq
}

// BuildNBIRTH freezes the full snapshot into an NBIRTH payload: seq reset to
// 0, every metric carrying Name + allocated Alias + Datatype + Value, plus the
// bdSeq metric. Allocating aliases here (in the stable, suffix-sorted snapshot
// order tagstore.Snapshot guarantees) is what makes the name↔alias table
// reproducible. Unmapped suffixes are skipped defensively.
func (p *Publisher) BuildNBIRTH(snapshot []rawtag.RawTag) (*sparkplug.Payload, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.seq = 0
	ts := maxTS(snapshot)
	pl := &sparkplug.Payload{Timestamp: u64(ts), Seq: u64(p.seq)}
	for _, t := range snapshot {
		name, dt, ok := p.resolver.Resolve(t.Metric)
		if !ok {
			continue
		}
		alias, _ := p.aliases.Alias(name)
		m := &sparkplug.Metric{
			Name:      strp(name),
			Alias:     u64(alias),
			Timestamp: u64(tagTS(t, ts)),
			Datatype:  u32(uint32(dt.Number())),
		}
		if err := setValue(m, dt, t.Value); err != nil {
			return nil, fmt.Errorf("session: NBIRTH metric %q: %w", name, err)
		}
		pl.Metrics = append(pl.Metrics, m)
	}
	// bdSeq — the birth half of the birth/death correlation (must match the
	// NDEATH Last-Will's bdSeq for this connection).
	pl.Metrics = append(pl.Metrics, bdSeqMetric(p.bdSeq, ts))
	return pl, nil
}

// BuildNDATA builds an alias-only NDATA payload from the report-by-exception
// dirty set: seq advances (mod 256), each metric carries only Alias + Value +
// Timestamp (no Name, no Datatype — the cloud StateStore falls back to the
// BIRTH-established datatype per alias). Callers MUST have ensured no dirty tag
// is a NeedsRebirth tag first (else the alias is unresolvable at the cloud).
func (p *Publisher) BuildNDATA(dirty []rawtag.RawTag) (*sparkplug.Payload, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.seq = (p.seq + 1) & 0xff
	ts := maxTS(dirty)
	pl := &sparkplug.Payload{Timestamp: u64(ts), Seq: u64(p.seq)}
	for _, t := range dirty {
		name, dt, ok := p.resolver.Resolve(t.Metric)
		if !ok {
			continue
		}
		// Alias-reference form. The tag must already be aliased (BuildNBIRTH
		// or a prior build allocated it); Alias returns the stable value.
		alias, _ := p.aliases.Alias(name)
		m := &sparkplug.Metric{
			Alias:     u64(alias),
			Timestamp: u64(tagTS(t, ts)),
		}
		if err := setValue(m, dt, t.Value); err != nil {
			return nil, fmt.Errorf("session: NDATA alias %d: %w", alias, err)
		}
		pl.Metrics = append(pl.Metrics, m)
	}
	return pl, nil
}

// BuildNDEATH builds the NDEATH payload for the MQTT Last-Will: a single bdSeq
// metric carrying THIS connection's bdSeq. An ungraceful agent loss then
// surfaces to the cloud as a death correlated to the matching birth. No seq
// (NDEATH is out-of-band w.r.t. the rolling NDATA sequence).
func (p *Publisher) BuildNDEATH() (*sparkplug.Payload, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	pl := &sparkplug.Payload{Metrics: []*sparkplug.Metric{bdSeqMetric(p.bdSeq, 0)}}
	return pl, nil
}

// NeedsRebirth reports whether any tag in the set resolves to a name the alias
// table has NOT yet frozen — a brand-new tag that appeared since the last
// BIRTH. Emitting it as alias-only NDATA would be unresolvable at the cloud
// (ADR-0042 §2.2: "isNew anywhere ⇒ force rebirth"), so the agent rebirths the
// full snapshot first. Read-only: it does NOT allocate (uses aliasmap.Has).
func (p *Publisher) NeedsRebirth(tags []rawtag.RawTag) bool {
	for _, t := range tags {
		name, _, ok := p.resolver.Resolve(t.Metric)
		if !ok {
			continue
		}
		if !p.aliases.Has(name) {
			return true
		}
	}
	return false
}

// bdSeqMetric builds the canonical bdSeq metric (Int64, name "bdSeq").
func bdSeqMetric(bdSeq, ts uint64) *sparkplug.Metric {
	m := &sparkplug.Metric{
		Name:     strp("bdSeq"),
		Datatype: u32(uint32(sparkplug.DataType_Int64.Number())),
		Value:    &sparkplug.Metric_LongValue{LongValue: bdSeq},
	}
	if ts != 0 {
		m.Timestamp = u64(ts)
	}
	return m
}

// setValue coerces a raw scalar (float64 | bool | string | nil) into the
// wire-format oneof Value for the configured SparkPlug datatype. A nil value
// leaves the metric value unset (a SparkPlug null — legal per spec).
func setValue(m *sparkplug.Metric, dt sparkplug.DataType, v any) error {
	if v == nil {
		return nil
	}
	switch dt {
	case sparkplug.DataType_Double:
		f, err := toFloat(v)
		if err != nil {
			return err
		}
		m.Value = &sparkplug.Metric_DoubleValue{DoubleValue: f}
	case sparkplug.DataType_Float:
		f, err := toFloat(v)
		if err != nil {
			return err
		}
		m.Value = &sparkplug.Metric_FloatValue{FloatValue: float32(f)}
	case sparkplug.DataType_Int64:
		f, err := toFloat(v)
		if err != nil {
			return err
		}
		m.Value = &sparkplug.Metric_LongValue{LongValue: uint64(int64(f))}
	case sparkplug.DataType_Int32:
		f, err := toFloat(v)
		if err != nil {
			return err
		}
		m.Value = &sparkplug.Metric_IntValue{IntValue: uint32(int32(f))}
	case sparkplug.DataType_Boolean:
		b, ok := v.(bool)
		if !ok {
			return fmt.Errorf("value %v is not a bool", v)
		}
		m.Value = &sparkplug.Metric_BooleanValue{BooleanValue: b}
	case sparkplug.DataType_String:
		s, ok := v.(string)
		if !ok {
			return fmt.Errorf("value %v is not a string", v)
		}
		m.Value = &sparkplug.Metric_StringValue{StringValue: s}
	default:
		return fmt.Errorf("unsupported datatype %v", dt)
	}
	return nil
}

func toFloat(v any) (float64, error) {
	switch x := v.(type) {
	case float64:
		return x, nil
	case bool:
		if x {
			return 1, nil
		}
		return 0, nil
	default:
		return 0, fmt.Errorf("value %v (%T) is not numeric", v, v)
	}
}

// maxTS returns the greatest tag timestamp in the set (the payload-level ts),
// or 0 if none carry one — callers stamp the metric-level ts per tag.
func maxTS(tags []rawtag.RawTag) uint64 {
	var max int64
	for _, t := range tags {
		if t.TsMillis > max {
			max = t.TsMillis
		}
	}
	return uint64(max)
}

func tagTS(t rawtag.RawTag, fallback uint64) uint64 {
	if t.TsMillis > 0 {
		return uint64(t.TsMillis)
	}
	return fallback
}

func u64(v uint64) *uint64 { return &v }
func u32(v uint32) *uint32 { return &v }
func strp(s string) *string { return &s }
