package main

// ADR-0061 P2 — the decoder as the single binding authority.
//
// With BIRTH_BOUND_ROUTING on, every (N/D)BIRTH's counter metrics are bound
// through their DECLARED device_key (birthbind + the refdata resolver over
// core.device_bindings), and every analytics envelope built from that node's
// DATA is STAMPED with the bound ids: metrics[].id_equipment + metrics[].role,
// and the envelope's id_enterprise (the tenant comes from the binding, D3).
//
// Stamping changes no write: stream-engine still resolves through its PackML
// resolver and only COMPARES the stamped ids (the D7 verification run, P2b)
// until a tenant is switched (P2c). An unbound metric carries no ids — the
// consumer then falls back to its current resolver; nothing is guessed.

import (
	"log/slog"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/analyticspub"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/birthbind"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/mqtt"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/refdataresolver"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// birthBinder owns the birth table and its metrics. A nil *birthBinder is the
// OFF state: every method is a no-op, so the handler needs no flag checks.
type birthBinder struct {
	table    *birthbind.Table
	counters *prometheus.CounterVec // per-birth counter outcomes
	stamps   *prometheus.CounterVec // per-envelope stamping outcomes
	logger   *slog.Logger
}

// newBirthBinder builds the binder when BIRTH_BOUND_ROUTING is on, else nil.
func newBirthBinder(cfg *config.Config, reg prometheus.Registerer, logger *slog.Logger) *birthBinder {
	if !cfg.BirthBoundRouting {
		return nil
	}
	var resolver birthbind.DeviceResolver
	switch {
	case cfg.BirthBoundResolver == "refdata" && cfg.RefdataURL != "":
		resolver = refdataresolver.New(refdataresolver.Config{
			BaseURL:      cfg.RefdataURL,
			EnterpriseID: cfg.BirthBoundEnterpriseID, // optional filter; keys are globally unique
			InternalKey:  cfg.RefdataInternalKey,
			PositiveTTL:  time.Duration(cfg.BirthBoundResolverTTLSeconds) * time.Second,
			NegativeTTL:  time.Duration(cfg.BirthBoundResolverNegTTLSeconds) * time.Second,
			Logger:       logger,
		})
	case cfg.BirthBoundResolver == "refdata":
		logger.Error("BIRTH_BOUND_RESOLVER=refdata but REFDATA_URL is empty — nothing will bind (fail-closed)")
		resolver = birthbind.MapResolver{}
	default:
		resolver = birthbind.MapResolver(cfg.BirthBoundDeviceMap)
	}
	b := &birthBinder{
		table: birthbind.NewTable(resolver),
		counters: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "edge_transformer_birthbind_counters_total",
			Help: "Birth counter metrics by binding outcome (bound|no_key|unresolved|bad_role|no_alias) — ADR-0061 P2.",
		}, []string{"tenant", "result"}),
		stamps: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "edge_transformer_birthbind_envelopes_total",
			Help: "Analytics envelopes by birth-bound stamping outcome (stamped|unbound|mixed_tenant) — ADR-0061 P2.",
		}, []string{"tenant", "result"}),
		logger: logger,
	}
	reg.MustRegister(b.counters, b.stamps)
	logger.Info("birth-bound binding ENABLED (ADR-0061 P2): envelopes carry id_equipment/role/id_enterprise; consumers verify",
		slog.String("resolver", cfg.BirthBoundResolver))
	return b
}

// onBirth binds one NBIRTH/DBIRTH. Other message types are ignored.
func (b *birthBinder) onBirth(topic mqtt.Topic, p *sparkplug.Payload) {
	if b == nil || (topic.MessageType != "NBIRTH" && topic.MessageType != "DBIRTH") {
		return
	}
	res := b.table.ApplyBirth(topic.GroupID, topic.EdgeNodeID, topic.DeviceID, topic.MessageType == "NBIRTH", p, b.logger)
	tenant := strings.ToLower(topic.GroupID)
	for result, n := range map[string]int{
		"bound": res.Bound, "no_key": res.NoKey, "unresolved": res.Unresolved,
		"bad_role": res.BadRole, "no_alias": res.NoAlias,
	} {
		if n > 0 {
			b.counters.WithLabelValues(tenant, result).Add(float64(n))
		}
	}
}

// stamp writes the birth-bound ids onto env's metrics (by the birth-declared
// name) and the envelope's id_enterprise. Metrics already carrying ids are
// left alone. If the bindings in one envelope disagree on the tenant the
// envelope is a misconfiguration: every stamp is removed (fail-closed) and
// counted as mixed_tenant.
func (b *birthBinder) stamp(env *analyticspub.Envelope, group, edgeNode string) {
	if b == nil {
		return
	}
	tenant := strings.ToLower(group)
	ent, stamped, mixed := 0, 0, false
	for i := range env.Metrics {
		m := &env.Metrics[i]
		bd, ok := b.table.LookupName(group, edgeNode, m.Name)
		if !ok {
			continue
		}
		id := bd.IDEquipment
		m.IDEquipment = &id
		m.Role = "counter." + string(bd.Role)
		stamped++
		switch {
		case bd.IDEnterprise == 0:
		case ent == 0:
			ent = bd.IDEnterprise
		case ent != bd.IDEnterprise:
			mixed = true
		}
	}
	switch {
	case stamped == 0:
		b.stamps.WithLabelValues(tenant, "unbound").Inc()
	case mixed:
		for i := range env.Metrics {
			env.Metrics[i].IDEquipment, env.Metrics[i].Role = nil, ""
		}
		b.stamps.WithLabelValues(tenant, "mixed_tenant").Inc()
		b.logger.Warn("birthbind: one envelope's bindings span tenants — stamps removed (check device_bindings)",
			slog.String("group_id", group), slog.String("edge_node", edgeNode))
	default:
		if ent > 0 {
			env.IDEnterprise = &ent
		}
		b.stamps.WithLabelValues(tenant, "stamped").Inc()
	}
}
