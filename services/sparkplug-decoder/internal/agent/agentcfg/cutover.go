// cutover.go — the PER-TENANT tag-map cutover policy (ADR-0045 Phase-2a).
//
// The problem it closes: AGENT_TAGMAP_FROM_REGISTER (register.go's dial) is a
// BOOT-TIME process env var — global, all-or-nothing. There is no per-tenant,
// DB-driven way to flip ONE tenant onto the register-driven (config-as-data)
// tag map, so edge-api's Phase-1 `POST /api/onboarding/cutover` endpoint can't
// actuate the flip. This file supplies the READ side of that actuation.
//
// The flip STATE already exists as data: edge-api's cutover endpoint sets
// `client_descriptors.status = 'cutover'` for the tenant (one row per
// id_enterprise, status ∈ draft|generated|captured|validated|cutover). The
// agent — which is per-tenant (one process per SparkPlug group_id) and already
// has DB access for the register loader — reads that status at boot and lets it
// decide the tag-map source. No new flag surface: the descriptor status IS the
// per-tenant switch.
//
// Precedence (documented + tested): the global AGENT_TAGMAP_FROM_REGISTER
// override wins (back-compat + emergency switch); otherwise the tenant's
// client_descriptors.status decides. A missing row or a read error is a SAFE
// fallback to the CURRENT behaviour (the static YAML map) — the flip is never
// silent and a DB hiccup never flips a tenant or crashes the agent.
//
// Refresh lifecycle = OPTION A (restart-to-apply). The whole tag-map machinery
// is startup-only: register.go's loader opens a transient pool, builds the map
// once, and closes it — there is no config/tagmap refresh loop anywhere in the
// agent. Mirroring that, this status read is a BOOT read: a mid-run cutover
// takes effect on the agent's next (re)start. Live-refresh (poll the status +
// rebuild the map without a restart) is deliberately deferred to a Phase-2b/ops
// follow-up rather than bolting a bespoke refresh loop onto a boot-only loader.
package agentcfg

// StatusCutover is the client_descriptors.status value that flips a tenant onto
// the register-driven (config-as-data) tag map. edge-api's Phase-1 cutover
// endpoint writes it; the agent reads it. Kept as a named constant so the
// contract between the two repos is a single spelled-out token.
const StatusCutover = "cutover"

// TagMapSource is the resolved origin of the agent's raw_tag_map for this boot.
type TagMapSource struct {
	// UseRegister is true when the map must be built from packml_register + the
	// tenant profile (register.go); false keeps the static YAML raw_tag_map.
	UseRegister bool
	// Reason is a bounded, machine-readable token for the boot log line and the
	// sparkplug_agent_tagmap_register_active gauge label (e.g. "env_override",
	// "descriptor_cutover", "descriptor_absent", "descriptor_error").
	Reason string
}

// Selection reasons (bounded set — safe as a Prometheus label).
const (
	ReasonEnvOverride       = "env_override"        // AGENT_TAGMAP_FROM_REGISTER=true forced register-driven
	ReasonDescriptorCutover = "descriptor_cutover"  // client_descriptors.status == cutover
	ReasonDescriptorAbsent  = "descriptor_absent"   // no descriptor row for this tenant yet
	ReasonDescriptorError   = "descriptor_error"    // status read failed → safe static fallback
	reasonDescriptorStatus  = "descriptor_status_"  // + <status> for a non-cutover lifecycle state
)

// SelectTagMapSource is the PURE per-tenant tag-map source policy (no DB, no
// env, no IO — fully unit-testable). Inputs:
//   - envOverride: AGENT_TAGMAP_FROM_REGISTER, the global override.
//   - status:      the tenant's client_descriptors.status ("" ⇒ no row).
//   - statusErr:   a non-nil read error (table missing, DB down, scan error).
//
// Precedence: env override > per-tenant status. Fail-safe: a read error or a
// non-cutover/absent status both resolve to the static map (UseRegister=false),
// so the agent only ever flips ON a definite signal and never crashes on a bad
// read.
func SelectTagMapSource(envOverride bool, status string, statusErr error) TagMapSource {
	// 1. Global override wins — back-compat + emergency switch. It short-circuits
	//    before the descriptor is even consulted, so a forced tenant flips even
	//    if the descriptor table is unreadable.
	if envOverride {
		return TagMapSource{UseRegister: true, Reason: ReasonEnvOverride}
	}
	// 2. A read error is a SAFE fallback, never a flip. (Checked before the
	//    status switch so a non-empty-but-stale status can't leak through.)
	if statusErr != nil {
		return TagMapSource{UseRegister: false, Reason: ReasonDescriptorError}
	}
	// 3. Per-tenant status decides.
	switch status {
	case StatusCutover:
		return TagMapSource{UseRegister: true, Reason: ReasonDescriptorCutover}
	case "":
		return TagMapSource{UseRegister: false, Reason: ReasonDescriptorAbsent}
	default:
		// A pre-cutover lifecycle state (draft/generated/captured/validated):
		// static map, but keep the actual status in the reason for observability.
		return TagMapSource{UseRegister: false, Reason: reasonDescriptorStatus + status}
	}
}
