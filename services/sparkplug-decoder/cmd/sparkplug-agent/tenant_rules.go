package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// tenantRulesFunc returns a tenant's derived ("calculation") rules as SAVED in
// the Customization Hub — client_descriptors.descriptor, resolved through the
// SAME generator (clientdescriptor.GenerateProfile) the hub validates and
// simulates with. found=false ⇒ the tenant has no stored descriptor.
//
// Why the DB and not the profiles dir: those files are bind mounts of the git
// checkout, so anything pushed there is reset by the next stack deploy — rules
// would silently stop. The descriptor row is where the hub saves, so reading it
// here means "saved in the hub" == "what the agent runs" after a restart.
type tenantRulesFunc func(ctx context.Context, group string) (rules []tenantprofile.DerivedRule, found bool, err error)

func descriptorRules(pool *pgxpool.Pool) tenantRulesFunc {
	return func(ctx context.Context, group string) ([]tenantprofile.DerivedRule, bool, error) {
		ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		var raw string
		err := pool.QueryRow(ctx,
			`SELECT descriptor::text FROM client_descriptors
			  WHERE upper(tenant_code) = upper($1) ORDER BY updated_at DESC LIMIT 1`, group).Scan(&raw)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, false, nil
		}
		if err != nil {
			return nil, false, fmt.Errorf("read descriptor: %w", err)
		}
		d, err := clientdescriptor.Parse([]byte(raw))
		if err != nil {
			return nil, false, fmt.Errorf("parse descriptor: %w", err)
		}
		prof, err := d.GenerateProfile()
		if err != nil {
			return nil, false, fmt.Errorf("generate profile: %w", err)
		}
		return prof.Derived, true, nil
	}
}

// allowlistEmits adds every rule's emitted suffix to the tenant's tag map when
// it is not already there, so a computed tag is accepted instead of dropped as
// "unmapped". Existing entries (and their types) are never changed.
func allowlistEmits(cfg *agentcfg.Config, rules []tenantprofile.DerivedRule) (added int, err error) {
	have := make(map[string]bool, len(cfg.RawTagMap))
	for _, e := range cfg.RawTagMap {
		have[e.MetricSuffix] = true
	}
	entries := append([]agentcfg.TagMapEntry(nil), cfg.RawTagMap...)
	for _, r := range rules {
		for _, s := range r.Emit {
			if !have[s] {
				have[s] = true
				entries = append(entries, agentcfg.TagMapEntry{MetricSuffix: s, Type: r.Type})
				added++
			}
		}
	}
	if added == 0 {
		return 0, nil
	}
	return added, cfg.SetRawTagMap(entries)
}
