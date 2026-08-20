package onboard

import (
	"fmt"
	"strings"
)

// scaffoldDescriptor renders a starter client descriptor for a new tenant — the
// DESCRIBE stage's authoring aid. It is a COMMENTED template pre-filled with the
// tenant + enterprise the CS engineer supplied and the canonical metric-template
// defaults every CPACK-shaped tenant shares, with the per-client quirk + inventory
// sections stubbed and annotated. The engineer fills the equipment list and any
// mapping quirks, then runs `onboard describe` to validate it.
//
// It deliberately produces a descriptor that FAILS validation until real
// equipment is added (the equipment: block is empty) — an empty descriptor must
// not look onboard-able. That failure is the guide-rail: DESCRIBE is not "done"
// until there is something to onboard.
func scaffoldDescriptor(tenant string, enterpriseID int, prefix string) string {
	up := strings.ToUpper(tenant)
	low := strings.ToLower(tenant)
	if prefix == "" {
		prefix = up
	}
	return fmt.Sprintf(`# %s.descriptor.yaml — %s CLIENT DESCRIPTOR (ADR-0045 P1, the SSoT).
#
# This is the ONE artifact you author to onboard %s. From it, the onboard
# orchestrator generates all four downstream artifacts (tenant conversion
# profile, packml_register SQL, agent client.yaml, Node-RED tee snippet) — you
# hand-edit NONE of them (ADR-0045 §2.2 "generate, never hand-edit").
#
# Flow:  onboard describe → generate → capture → validate → cutover
# Fill the sections below, then run:  onboard describe --descriptor %s.descriptor.yaml

tenant: %s
enterprise_id: %d                      # packml_register.id_enterprise (cross-tenant guard)

canonical:
  prefix: %s                           # tenant_prefix — the canonical (post-fixup) head;
                                       # every equipment topic must start with it.

# ── raw → canonical mapping (per-client quirks, normalized STACK-SIDE per
#    ADR-0045 §2.3 Option B). Start empty; add only what THIS PLC needs. ────────
mapping:
  count_index_default_mode: equipment_id   # fallback for any un-captured member
  prefix_fixups: []                        # e.g. {from: "C-PACK/", to: "%s/"}
  metric_aliases: []                       # e.g. {from: "Status/CurMachSpeed", to: "Status/MachSpeed"}
  parameter_aliases: []                    # e.g. {from: "Status/Parameter", to: "Status/Parameter30700", applies_to: line}

# ── line-vs-member canonical metric templates (the superset allowlist) ────────
# These defaults match the CPACK worked example; adjust leaves only if this
# tenant's PLC emits a different canonical metric set.
metric_templates:
  line:
    - {leaf: "/Admin/ProdConsumedCount", type: double}
    - {leaf: "/Admin/ProdProcessedCount", type: double}
    - {leaf: "/Admin/ProdDefectiveCount", type: double}
    - {leaf: "/Status/MachSpeed", type: double}
    - {leaf: "/Status/StateCurrent", type: long}
    - {leaf: "/Status/Parameter30700", type: string}
  member:
    - {leaf: "/Admin/ProdConsumedCount/{idx}/Unit", type: double}
    - {leaf: "/Admin/ProdProcessedCount/{idx}/Unit", type: double}
    - {leaf: "/Admin/ProdDefectiveCount/{idx}/Unit", type: double}
    - {leaf: "/Status/MachSpeed", type: double}
    - {leaf: "/Status/StateCurrent", type: long}

# ── equipment inventory (lines tp=3 + members tp=1) ───────────────────────────
# One row per line and per member. id_equipment = the register surrogate id.
# For members, count_index.value = the OBSERVED PLC channel index and confidence
# is 'inferred' until a live-tee CAPTURE confirms it. NO tenant cuts over while
# any member is 'inferred' (ADR-0045 §2.4b). Example rows (replace with real):
#
#   - {topic: %s/LINE1, id_equipment: 100, tp_equipment: 3}
#   - {topic: %s/LINE1/MEMBERA, id_equipment: 101, tp_equipment: 1, id_unit: 101, count_index: {value: 0, confidence: inferred}}
equipment: []                            # <-- REQUIRED: add lines + members here

# ── agent wiring (→ client.yaml, the agentcfg descriptor) ─────────────────────
agent:
  edge_node_id: %s-tee
  internal_broker: tcp://mosquitto:1883
  raw_topic: edge/raw/%s/#
  uplink_broker: tcp://mosquitto:1883
  mtls:                                  # Mode-B mTLS CN=<tenant>; secret refs, never values
    cert_ref: ""
    key_ref: ""
    ca_ref: ""

# ── Node-RED tee snippet parameters (→ %s-tee-node.json) ──────────────────────
tee:
  ingest_url: "https://REPLACE-ME:8446/ingest/sparkplug"
  ingest_key_env: %s_INGEST_KEY          # tee reads the key from env, never hardcoded
  gateway: %s-edge
  tls_insecure: true                     # staging self-signed
`,
		low, up, up, low,
		up, enterpriseID,
		prefix,
		up,
		prefix, prefix,
		low, low,
		low, up, low)
}
