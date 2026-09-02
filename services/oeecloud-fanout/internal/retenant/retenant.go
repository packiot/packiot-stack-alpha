// Package retenant is the pure re-tenant transform at the heart of the
// twin fan-out. It rewrites a decoded-SparkPlug envelope so that a message
// produced for a SOURCE tenant (e.g. CPACK) becomes a byte-faithful clone
// addressed to a TARGET tenant (e.g. SBXCPACK), with zero DB / broker deps
// so it is fully unit-testable.
//
// # Why a cross-tenant clone is double-count-safe
//
// The retired same-tenant mirror-worker-go replayed prod's PO actions back
// into the SAME staging tenant, so it had to be the SOLE writer of any given
// row or it would double-write. This transform is the opposite: it emits ONLY
// to a DIFFERENT tenant (SBXCPACK, enterprise 2000003) whose packml_register
// rows, id_equipment ids (+2,000,000 offset) and F3 rows are DISJOINT from the
// source tenant's (CPACK, enterprise 3). The source tenant's own pipeline is
// untouched — it keeps flowing to its own queue/enterprise. Because source and
// target never share a destination row, republishing the clone can never
// double-count the source. See the package doc on the fan-out consumer for the
// broker-side no-loop argument (the target routing key never matches this
// consumer's bindings).
//
// # What the transform does
//
//  1. Rewrites every metrics[].name whose FIRST topic segment (the SparkPlug
//     GroupID) equals the source group → the target group. The GroupID is
//     exactly what the downstream worker lowercases into the tenant used for
//     packml_register resolution and routing, so rewriting it re-tenants the
//     whole envelope. For CPACK all topics are `CPACK/SC/...`, so this is the
//     `CPACK/SC → SBXCPACK/SC` rewrite the twin backfill expects, generalized
//     to the first segment.
//  2. CLEARS any resolved-equipment-id field (id_equipment / equipment_id) at
//     the top level or per metric, so the sandbox worker re-resolves the id
//     against its OWN SBXCPACK register rows rather than inheriting the source
//     tenant's ids. NOTE: on the wire today the envelope carries no such field
//     — the only per-metric `id` is the PackML PARAMETER id (30700-30899) that
//     the worker needs for PO-control classification, so we deliberately DO NOT
//     touch `id`. The clear is a forward-safe guard for envelopes that ever
//     carry a pre-resolved equipment id.
//  3. Rewrites a top-level tenant/group_id string field to the target tenant if
//     one is present (again, none on the current wire shape — forward-safe).
//
// Everything else (timestamps, values, counters, source_type, gateway, and any
// unknown fields) is preserved byte-for-byte: the body is decoded with
// json.Number so large integer timestamps/counters round-trip exactly, and
// re-marshaled from a generic map so fields the struct doesn't know about are
// not dropped.
package retenant

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// Config parameterizes the transform so the same code serves any twin
// (source tenant → target tenant), which is what the config-as-data
// onboarding RabbitMQ provisioning (#22) will generate per twin.
type Config struct {
	// SourceGroup is the SparkPlug GroupID (first topic segment) of the tenant
	// being cloned, e.g. "CPACK". Compared case-insensitively.
	SourceGroup string
	// TargetGroup is the GroupID to rewrite into, e.g. "SBXCPACK".
	TargetGroup string
}

// equipmentIDFields are the metric/top-level keys that, IF present, hold a
// pre-resolved equipment id inherited from the source tenant. They are cleared
// so the target worker re-resolves against its own register. `id` is
// intentionally NOT in this list — it is the PackML parameter id, not an
// equipment id.
var equipmentIDFields = []string{"id_equipment", "equipment_id", "idequipment"}

// tenantFields are top-level keys that, IF present, name the tenant/group and
// must be rewritten to the target so a downstream consumer that trusts the
// envelope field (rather than the metric prefix) still routes correctly.
var tenantFields = []string{"tenant", "group_id", "groupid"}

// Retenant rewrites body from the source tenant to the target tenant.
//
// Returns:
//   - out: the re-tenanted envelope bytes (only meaningful when ours==true).
//   - ours: true when the envelope belonged to SourceGroup and was rewritten;
//     false when the message is for some OTHER tenant and must be left alone
//     (the caller acks it WITHOUT republishing — this is the no-cross-
//     contamination guard for the shared 2-segment `sparkplug.data` binding,
//     which carries every tenant's traffic).
//   - err: the body was not a decodable envelope object (deterministic poison —
//     the caller should drop+count, never retry).
func Retenant(body []byte, cfg Config) (out []byte, ours bool, err error) {
	// UseNumber keeps every JSON number as its exact source text, so a 13-digit
	// millisecond timestamp or a large totalizer counter round-trips verbatim
	// instead of being reformatted through float64.
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var env map[string]any
	if decErr := dec.Decode(&env); decErr != nil {
		return nil, false, fmt.Errorf("retenant: decode envelope: %w", decErr)
	}

	metricsRaw, ok := env["metrics"].([]any)
	if !ok {
		// No metrics array → cannot determine the tenant, and it is not the
		// envelope shape we clone. Treat as "not ours" so the caller drops it
		// without contaminating the target.
		return nil, false, nil
	}

	src := strings.ToUpper(cfg.SourceGroup)
	tgt := cfg.TargetGroup

	// Determine ownership from the first metric that carries a name. We must
	// NOT rewrite a message whose group is some other tenant (the shared
	// `sparkplug.data` binding delivers every tenant's traffic here).
	if grp := firstGroup(metricsRaw); !strings.EqualFold(grp, src) {
		return nil, false, nil
	}

	// Rewrite every metric name's leading group segment + clear inherited
	// equipment ids.
	for _, m := range metricsRaw {
		metric, ok := m.(map[string]any)
		if !ok {
			continue
		}
		if name, ok := metric["name"].(string); ok {
			metric["name"] = rewriteGroup(name, src, tgt)
		}
		for _, f := range equipmentIDFields {
			delete(metric, f)
		}
	}

	// Forward-safe: rewrite a top-level tenant/group field + clear a top-level
	// inherited equipment id, if the wire shape ever grows them.
	for _, f := range tenantFields {
		if _, present := env[f]; present {
			env[f] = strings.ToLower(tgt)
		}
	}
	for _, f := range equipmentIDFields {
		delete(env, f)
	}

	out, err = json.Marshal(env)
	if err != nil {
		return nil, false, fmt.Errorf("retenant: marshal envelope: %w", err)
	}
	return out, true, nil
}

// firstGroup returns the first topic segment (GroupID) of the first metric that
// has a non-empty name, mirroring the worker's tenantOf().
func firstGroup(metricsRaw []any) string {
	for _, m := range metricsRaw {
		metric, ok := m.(map[string]any)
		if !ok {
			continue
		}
		name, ok := metric["name"].(string)
		if !ok || name == "" {
			continue
		}
		if i := strings.IndexByte(name, '/'); i > 0 {
			return name[:i]
		}
		return name
	}
	return ""
}

// rewriteGroup replaces the leading group segment of a SparkPlug topic name
// when it matches src (case-insensitive), preserving the rest of the path
// verbatim. `CPACK/SC/LINHAS/L5/...` with src=CPACK,tgt=SBXCPACK becomes
// `SBXCPACK/SC/LINHAS/L5/...`. A name whose group does not match src is
// returned unchanged (defensive — the ownership check already gated this).
func rewriteGroup(name, src, tgt string) string {
	i := strings.IndexByte(name, '/')
	if i < 0 {
		// Single-segment name that IS the group.
		if strings.EqualFold(name, src) {
			return tgt
		}
		return name
	}
	if strings.EqualFold(name[:i], src) {
		return tgt + name[i:]
	}
	return name
}
