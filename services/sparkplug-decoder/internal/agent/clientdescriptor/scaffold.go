package clientdescriptor

// scaffold.go is the GREENFIELD half of onboarding. The importer (PR #687) covers
// MIGRATION — a legacy Node-RED flow becomes a descriptor plc: block. But a
// brand-new client has no legacy flow to import: a CS engineer would otherwise
// author the descriptor against a blank file. Scaffold emits a VALID starter
// descriptor from minimal input (tenant, site, line count, protocols) so the
// engineer edits fill-in-the-blanks values instead of inventing structure.
//
// The contract that keeps a scaffold trustworthy: what Scaffold emits ALWAYS
// round-trips through Parse (i.e. it is already a valid descriptor). It reaches
// that by emitting the ACTIVE, must-be-valid spine (tenant, prefix, templates,
// equipment, plc endpoints) as real structs, and leaving the parts that require
// site-specific physical addressing (the tag maps) as COMMENTED guidance — so the
// skeleton validates today and the engineer uncomments + fills the addresses.

import (
	"fmt"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// ScaffoldOptions is the minimal input a CS engineer supplies for a greenfield
// descriptor. Nothing here is a hardcoded tenant/enterprise identity — every id
// in the emitted descriptor is a clearly-marked placeholder the engineer replaces
// with real register values (the standing no-hardcoded-ids directive).
type ScaffoldOptions struct {
	// Tenant is the SparkPlug group_id / enterprise short-name (e.g. "acme"). It is
	// uppercased for the descriptor's tenant + canonical prefix (the canonical
	// model is uppercase), matching the authored descriptors under docs/clients/.
	Tenant string

	// Site is the site short-name (e.g. "sp"). Uppercased into the prefix as
	// <TENANT>/<SITE>.
	Site string

	// Lines is how many production lines to stub. Each emits one line equipment
	// (tp=3) plus one example member machine (tp=1) so the engineer sees both the
	// line and member shapes.
	Lines int

	// Protocols selects which PLC endpoint placeholders to emit — a subset of
	// {s7, modbus, opcua} (modbus is accepted as an alias for modbus_tcp). Empty
	// defaults to s7. A multi-protocol request also stamps the multi-source
	// pattern into the commented tag-map guidance.
	Protocols []string
}

// normalizeProtocol maps a user-facing protocol token to a descriptor protocol
// constant. "modbus" is accepted as the friendly alias for "modbus_tcp".
func normalizeProtocol(p string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(p)) {
	case "s7":
		return PLCProtocolS7, nil
	case "modbus", "modbus_tcp":
		return PLCProtocolModbusTCP, nil
	case "opcua", "opc-ua", "opc_ua":
		return PLCProtocolOPCUA, nil
	default:
		return "", fmt.Errorf("unknown protocol %q (want s7|modbus|opcua)", p)
	}
}

// resolveProtocols normalizes + de-dupes the requested protocol list, preserving
// first-seen order so the emitted endpoints are stable. Empty ⇒ [s7].
func resolveProtocols(in []string) ([]string, error) {
	if len(in) == 0 {
		return []string{PLCProtocolS7}, nil
	}
	seen := map[string]bool{}
	var out []string
	for _, p := range in {
		norm, err := normalizeProtocol(p)
		if err != nil {
			return nil, err
		}
		if seen[norm] {
			continue
		}
		seen[norm] = true
		out = append(out, norm)
	}
	return out, nil
}

// ptr is a tiny helper for the *int endpoint fields (rack/slot/unit_id) where a
// zero value is meaningful, so "present and 0" must be distinguishable from absent.
func ptr(i int) *int { return &i }

// Scaffold builds a VALID starter Descriptor from the options. The returned
// descriptor passes Validate (so it round-trips through Parse), carries N lines +
// members with placeholder-but-positive ids, and one plc endpoint per requested
// protocol. It deliberately emits NO active tag maps — those need per-site
// physical addressing the engineer supplies (ScaffoldYAML shows them as commented
// examples). Pure: no I/O, deterministic in the options.
func Scaffold(opts ScaffoldOptions) (*Descriptor, error) {
	tenant := strings.ToUpper(strings.TrimSpace(opts.Tenant))
	if tenant == "" {
		return nil, fmt.Errorf("scaffold: --tenant is required")
	}
	site := strings.ToUpper(strings.TrimSpace(opts.Site))
	if site == "" {
		return nil, fmt.Errorf("scaffold: --site is required")
	}
	if opts.Lines < 1 {
		return nil, fmt.Errorf("scaffold: --lines must be >= 1, got %d", opts.Lines)
	}
	protos, err := resolveProtocols(opts.Protocols)
	if err != nil {
		return nil, fmt.Errorf("scaffold: %w", err)
	}

	prefix := tenant + "/" + site
	lower := strings.ToLower(tenant)

	d := &Descriptor{
		Tenant:       tenant,
		EnterpriseID: 0, // placeholder — real id_enterprise set by the engineer
		Canonical:    Canonical{Prefix: prefix},
		Mapping: Mapping{
			// equipment_id is the safe default: a member's count index falls back to
			// its register id until a live-tee CAPTURE confirms the real channel.
			CountIndexDefaultMode: "equipment_id",
		},
		// Minimal canonical leaves. The member set carries the two leaves the
		// multi-source pattern composes (speed + count); the line set carries a
		// bare state leaf. The engineer extends these to the client's real model.
		MetricTemplates: tenantprofile.MetricTemplates{
			Line: []tenantprofile.TemplateEntry{
				{Leaf: "/Status/StateCurrent", Type: "long"},
			},
			Member: []tenantprofile.TemplateEntry{
				{Leaf: "/Status/MachSpeed", Type: "double"},
				{Leaf: "/Admin/ProdProcessedCount/{idx}/Unit", Type: "double"},
			},
		},
		Agent: AgentWiring{
			EdgeNodeID:     lower + "-edge",
			InternalBroker: "tcp://mosquitto:1883",
			RawTopic:       lower + "/raw",
			UplinkBroker:   "ssl://REPLACE-INGEST-HOST:8883",
			MTLS: MTLSRefs{
				CertRef: secretRef(lower, "uplink-cert"),
				KeyRef:  secretRef(lower, "uplink-key"),
				CARef:   secretRef(lower, "uplink-ca"),
			},
		},
		Tee: TeeParams{
			IngestURL:   "https://REPLACE-INGEST-HOST:8444/v1/tags",
			TLSInsecure: true,
		},
	}

	// Equipment: per line, a line (tp=3) + one member machine (tp=1). Ids are
	// positive placeholders (Validate requires id_equipment > 0) on a per-line
	// stride so line/member ids never collide; the engineer swaps them for real
	// register ids. Member count indices start inferred — a fresh client has
	// captured nothing yet, and the cutover gate must refuse until a live tee
	// CONFIRMS each channel.
	for i := 1; i <= opts.Lines; i++ {
		base := 1000 + i*10
		lineTopic := fmt.Sprintf("%s/LINE%d", prefix, i)
		d.Equipment = append(d.Equipment, Equipment{
			Topic:       lineTopic,
			IDEquipment: base,
			TPEquipment: 3,
		})
		memberID := base + 1
		d.Equipment = append(d.Equipment, Equipment{
			Topic:       lineTopic + "/M1",
			IDEquipment: memberID,
			TPEquipment: 1,
			IDUnit:      ptr(memberID),
			CountIndex:  &CountIndexCapture{Value: memberID, Confidence: ConfidenceInferred},
		})
	}

	// PLC: one endpoint placeholder per requested protocol. Hosts/URLs are secret
	// refs (never values). No tag maps — those are the commented fill-in.
	plc := &DescriptorPLC{}
	for _, proto := range protos {
		plc.Endpoints = append(plc.Endpoints, scaffoldEndpoint(lower, proto))
	}
	d.PLC = plc

	if err := d.Validate(); err != nil {
		// A scaffold that does not validate is a bug in this generator, not user
		// error — surface it loudly rather than emit an invalid skeleton.
		return nil, fmt.Errorf("scaffold produced an invalid descriptor (generator bug): %w", err)
	}
	return d, nil
}

// secretRef builds a conventional secret:// pointer for a tenant credential.
func secretRef(lowerTenant, name string) string {
	return secretScheme + "packiot/" + lowerTenant + "/" + name
}

// scaffoldEndpoint returns a protocol-appropriate endpoint placeholder with a
// stable name (<proto>-plc) and secret-ref host/URL. The protocol-specific fields
// (rack/slot for S7, unit_id for Modbus, endpoint_url_ref + security for OPC-UA)
// are pre-filled with the common defaults the readers expect.
func scaffoldEndpoint(lowerTenant, proto string) DescriptorPLCEndpoint {
	ep := DescriptorPLCEndpoint{PollingInterval: "1s"}
	switch proto {
	case PLCProtocolS7:
		ep.Name = "s7-plc"
		ep.Protocol = PLCProtocolS7
		ep.HostRef = secretRef(lowerTenant, "s7-plc-host")
		ep.Rack = ptr(0)
		ep.Slot = ptr(1)
	case PLCProtocolModbusTCP:
		ep.Name = "modbus-plc"
		ep.Protocol = PLCProtocolModbusTCP
		ep.HostRef = secretRef(lowerTenant, "modbus-plc-host")
		ep.UnitID = ptr(1)
	case PLCProtocolOPCUA:
		ep.Name = "opcua-plc"
		ep.Protocol = PLCProtocolOPCUA
		ep.EndpointURLRef = secretRef(lowerTenant, "opcua-plc-url")
		ep.SecurityPolicy = "None"
		ep.SecurityMode = "None"
	}
	return ep
}

// ScaffoldYAML renders a scaffold to commented YAML: a header explaining the
// fill-in-the-blanks workflow, the marshalled (valid) descriptor spine, and a
// COMMENTED tag-map guidance block that shows how to bind each endpoint — and,
// for a multi-protocol request, the multi-source pattern (two endpoints → one
// equipment). The commented block is pure comment, so the whole document still
// parses back to the same Descriptor Scaffold built.
func ScaffoldYAML(opts ScaffoldOptions) ([]byte, error) {
	d, err := Scaffold(opts)
	if err != nil {
		return nil, err
	}
	body, err := yaml.Marshal(d)
	if err != nil {
		return nil, fmt.Errorf("scaffold: marshal descriptor: %w", err)
	}
	var b strings.Builder
	b.WriteString(scaffoldHeader(d))
	b.Write(body)
	b.WriteString(scaffoldTagMapGuide(d))
	return []byte(b.String()), nil
}

// scaffoldHeader is the leading comment block: what the file is + the TODO list a
// CS engineer must complete before the descriptor is cutover-ready.
func scaffoldHeader(d *Descriptor) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s onboarding descriptor — GENERATED SKELETON (onboard-gen scaffold).\n", d.Tenant)
	b.WriteString("#\n")
	b.WriteString("# This is a VALID starter descriptor: it already round-trips through\n")
	b.WriteString("# clientdescriptor.Parse. Fill in the blanks below, then regenerate the\n")
	b.WriteString("# onboarding artifacts with:  onboard-gen --descriptor <this-file>\n")
	b.WriteString("#\n")
	b.WriteString("# TODO before cutover:\n")
	b.WriteString("#   1. enterprise_id       — set the real packml_register id_enterprise (now 0).\n")
	b.WriteString("#   2. equipment ids        — replace the placeholder id_equipment/id_unit values\n")
	b.WriteString("#                             (currently 10x0/10x1 strides) with real register ids.\n")
	b.WriteString("#   3. REPLACE-INGEST-HOST  — the agent uplink + tee ingest host.\n")
	b.WriteString("#   4. plc tag maps         — uncomment the block at the BOTTOM of this file and\n")
	b.WriteString("#                             fill each tag's physical address (S7 db/offset,\n")
	b.WriteString("#                             Modbus register, OPC-UA node_id).\n")
	b.WriteString("#   5. count indices        — every member starts confidence: inferred; capture\n")
	b.WriteString("#                             each channel on a live tee and flip to confirmed\n")
	b.WriteString("#                             (onboard-gen --cutover refuses while any is inferred).\n")
	b.WriteString("#\n")
	return b.String()
}

// scaffoldTagMapGuide emits the COMMENTED tag-map section — the part that needs
// per-site physical addressing. It references the real endpoint names + the first
// member's topic/id from the scaffold, and when the tenant is multi-protocol it
// shows the MULTI-SOURCE pattern: two endpoints of different protocols pointing at
// the SAME packml_topic + id_equipment so one equipment's message is composed from
// two PLCs. See docs/clients/examples/multisource.descriptor.yaml for a worked,
// tested instance.
func scaffoldTagMapGuide(d *Descriptor) string {
	// The first member is the natural binding target for the examples.
	var memberTopic string
	var memberID int
	for _, e := range d.Equipment {
		if e.TPEquipment == 1 {
			memberTopic = e.Topic
			memberID = e.IDEquipment
			break
		}
	}
	// Which protocols does this scaffold carry, and under which endpoint name?
	epByProto := map[string]string{}
	var protos []string
	for _, ep := range d.PLC.Endpoints {
		if _, ok := epByProto[ep.Protocol]; !ok {
			protos = append(protos, ep.Protocol)
		}
		epByProto[ep.Protocol] = ep.Name
	}
	sort.Strings(protos)
	multi := len(protos) > 1

	var b strings.Builder
	b.WriteString("\n")
	b.WriteString("# ─────────────────────────────────────────────────────────────────────────\n")
	b.WriteString("# PLC TAG MAPS — uncomment + fill the physical addresses, then move under `plc:`.\n")
	if multi {
		b.WriteString("#\n")
		b.WriteString("# MULTI-SOURCE: the entries below point BOTH protocols at the SAME equipment\n")
		fmt.Fprintf(&b, "# (%s, id %d) — two PLCs compose ONE SparkPlug message. Each tag's\n", memberTopic, memberID)
		b.WriteString("# <packml_topic><metric>, minus canonical.prefix, MUST equal a metric_suffix the\n")
		b.WriteString("# agent synthesizes for that equipment (from metric_templates) or the agent will\n")
		b.WriteString("# silently drop it (ADR-0045 §C). See docs/clients/examples/multisource.descriptor.yaml.\n")
	} else {
		b.WriteString("# Each tag's <packml_topic><metric>, minus canonical.prefix, MUST equal a\n")
		b.WriteString("# metric_suffix the agent synthesizes for that equipment (ADR-0045 §C).\n")
	}
	b.WriteString("#\n")

	// The first printed map owns the equipment; every SUBSEQUENT map (position > 0)
	// gets the "SAME equipment" note — so the multi-source point reads correctly
	// regardless of protocol ordering.
	for i, proto := range protos {
		name := epByProto[proto]
		note := ""
		if multi && i > 0 {
			note = "   # SAME equipment as the map above (multi-source composition)"
		}
		switch proto {
		case PLCProtocolS7:
			b.WriteString("# s7_tag_map:\n")
			fmt.Fprintf(&b, "#   - endpoint: %s\n", name)
			fmt.Fprintf(&b, "#     packml_topic: %s%s\n", memberTopic, note)
			fmt.Fprintf(&b, "#     id_equipment: %d\n", memberID)
			b.WriteString("#     tags:\n")
			fmt.Fprintf(&b, "#       - {metric: \"/Admin/ProdProcessedCount/%d/Unit\", db: 1, offset: 0, type: dint}\n", memberID)
		case PLCProtocolModbusTCP:
			b.WriteString("# modbus_tag_map:\n")
			fmt.Fprintf(&b, "#   - endpoint: %s\n", name)
			fmt.Fprintf(&b, "#     packml_topic: %s%s\n", memberTopic, note)
			fmt.Fprintf(&b, "#     id_equipment: %d\n", memberID)
			b.WriteString("#     tags:\n")
			b.WriteString("#       - {metric: \"/Status/MachSpeed\", kind: holding, address: 100, type: float32}\n")
		case PLCProtocolOPCUA:
			b.WriteString("# opcua_tag_map:\n")
			fmt.Fprintf(&b, "#   - endpoint: %s\n", name)
			fmt.Fprintf(&b, "#     packml_topic: %s%s\n", memberTopic, note)
			fmt.Fprintf(&b, "#     id_equipment: %d\n", memberID)
			b.WriteString("#     tags:\n")
			b.WriteString("#       - {metric: \"/Status/MachSpeed\", node_id: \"ns=2;s=Machine.Speed\", type: float}\n")
		}
	}
	return b.String()
}
