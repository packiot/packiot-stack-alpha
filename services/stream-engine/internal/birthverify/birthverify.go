// Package birthverify is the ADR-0061 D7 verification run: a temporary measuring
// instrument that compares the decoder's BIRTH-BOUND identity (stamped on each
// envelope by edge-transformer, ADR-0061 P2) with what the current PackML
// resolver (packml_register) says for the same metric. It writes NOTHING —
// the PackML resolver stays the only writer until a tenant is switched (P2c).
//
// Per counter metric (the only metrics the decoder binds today) it counts one
// result per tenant:
//
//	match               — stamped id_equipment, tenant and role all agree
//	mismatch_equipment  — stamped id_equipment ≠ packml_register's
//	mismatch_enterprise — stamped id_enterprise ≠ packml_register's
//	mismatch_role       — stamped role ≠ the role the leaf name implies
//	unbound             — no stamp (producer not yet conformant: no dk_ key /
//	                      definitive birth off) — coverage, not a disagreement
//	legacy_unresolved   — stamped, but packml_register has no active row
//	                      (the birth-bound side resolves something legacy can't)
//	legacy_error        — the PackML lookup failed (DB) — inconclusive
//
// A tenant may switch after zero mismatch_* for 7 consecutive days and no
// unbound left (D7). The package is deleted in P5 with the PackML resolver.
package birthverify

import (
	"context"
	"log/slog"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// Resolver is the PackML side (sparkplug.Resolver satisfies it).
type Resolver interface {
	Resolve(ctx context.Context, topic string) (*sparkplug.EquipmentInfo, error)
}

// Verifier compares stamps with the PackML resolver. A nil *Verifier is OFF.
type Verifier struct {
	res     Resolver
	results *prometheus.CounterVec
	logger  *slog.Logger
}

// New builds a Verifier and registers its counter on reg.
func New(res Resolver, reg prometheus.Registerer, logger *slog.Logger) *Verifier {
	v := &Verifier{
		res: res,
		results: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "oeecloud_worker_birthbind_verify_total",
			Help: "ADR-0061 D7 verification: counter metrics by birth-bound vs packml_register outcome " +
				"(match|mismatch_equipment|mismatch_enterprise|mismatch_role|unbound|legacy_unresolved|legacy_error). " +
				"tenant=lowercased group_id. A tenant switches after 0 mismatch_* for 7 days.",
		}, []string{"tenant", "result"}),
		logger: logger,
	}
	reg.MustRegister(v.results)
	return v
}

// legacyRole is the role the PackML leaf name implies (the classification the
// declared role replaces, ADR-0061 D2/D9). "" ⇒ not a counter.
func legacyRole(k sparkplug.MetricKind) string {
	switch k {
	case sparkplug.KindProdConsumedCount:
		return "counter.gross"
	case sparkplug.KindProdProcessedCount:
		return "counter.net"
	case sparkplug.KindProdDefectiveCount:
		return "counter.scrap"
	}
	return ""
}

// Check counts one result per counter metric of p. Never fails, never writes.
func (v *Verifier) Check(ctx context.Context, p *sparkplug.Payload, tenant string) {
	if v == nil || p == nil {
		return
	}
	ent, hasEnt := p.StampedEnterprise()
	for i := range p.Metrics {
		m := &p.Metrics[i]
		want := legacyRole(m.Classify())
		if want == "" {
			continue
		}
		id, stamped := m.StampedEquipment()
		if !stamped {
			v.results.WithLabelValues(tenant, "unbound").Inc()
			continue
		}
		info, err := v.res.Resolve(ctx, m.TopicForRegister())
		result := "match"
		switch {
		case err != nil:
			result = "legacy_error"
		case info == nil:
			result = "legacy_unresolved"
		case info.IDEquipment != id:
			result = "mismatch_equipment"
		case hasEnt && info.IDEnterprise != ent:
			result = "mismatch_enterprise"
		case m.Role != want:
			result = "mismatch_role"
		}
		v.results.WithLabelValues(tenant, result).Inc()
		if result != "match" && result != "legacy_error" {
			attrs := []any{slog.String("tenant", tenant), slog.String("result", result),
				slog.String("metric", m.Name), slog.Int("stamped_id_equipment", id),
				slog.String("stamped_role", m.Role), slog.String("legacy_role", want)}
			if info != nil {
				attrs = append(attrs, slog.Int("legacy_id_equipment", info.IDEquipment),
					slog.Int("legacy_id_enterprise", info.IDEnterprise))
			}
			if hasEnt {
				attrs = append(attrs, slog.Int("stamped_id_enterprise", ent))
			}
			v.logger.Warn("birthverify: birth-bound identity disagrees with packml_register", attrs...)
		}
	}
}
