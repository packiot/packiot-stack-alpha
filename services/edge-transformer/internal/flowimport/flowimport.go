// Package flowimport turns a legacy Node-RED flow (the array of nodes a factory
// hand-wired to read its PLCs) into the descriptor `plc:` block — the Phase-2
// DescriptorPLC subtree the Go s7/modbus/opcua readers consume.
//
// The problem it solves
// ---------------------
// Before ADR-0045 P2 a client migrating off hand-wired Node-RED had to hand-author
// every PLC endpoint (host, rack, slot) and every S7/Modbus/OPC-UA address into
// the descriptor's plc block. That addressing already EXISTS — in the client's
// Node-RED flow (the `s7 endpoint` node's rack/slot + its vartable of DB addresses,
// the `modbus-client`/`modbus-read` nodes). This package lifts it mechanically so
// the onboarding engineer transcribes nothing.
//
// What it can and cannot derive
// ------------------------------
// The flow carries PHYSICAL addressing faithfully (an `s7 endpoint`'s vartable is
// a literal addr→name table), so S7 tags come across cleanly. Two things it CANNOT
// invent, and refuses to guess at:
//
//   - a BARE-NUMBER S7 tag name (e.g. "514") is a legacy PLC count-index channel,
//     not a canonical metric. It is resolved against the descriptor's count-index
//     map when present; when it is not, the tag is emitted as a commented skeleton
//     with a TODO + a WARN, never dropped (dropping it would silently lose a
//     counter — the exact data-loss class ADR-0045 §C guards).
//   - a `modbus-read` node is a BLOCK read (a range of registers); the
//     per-register→metric binding lives in a downstream `function` node the flow
//     may not include. So Modbus yields the endpoint + a tag-map SKELETON (the
//     block ranges as a comment) + a WARN — never invented register bindings.
//
// Secret discipline: a PLC host is a secret. The emitted host_ref is a generated
// `secret://…` reference; the real host from the flow is printed to the operator
// as a provisioning table, NEVER inlined into the descriptor (ADR-0004 Layer-2).
package flowimport

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/clientdescriptor"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

// Node-RED node type tokens this importer understands.
const (
	nodeS7Endpoint   = "s7 endpoint"
	nodeModbusRead   = "modbus-read"
	nodeModbusClient = "modbus-client"
	// OPC-UA node types are handled if present; CPACK's OPC-UA lives on a
	// separate flow tab, so a flow with none is normal (Result.notes records it).
	nodeOPCUAItem   = "opcua-item"
	nodeOPCUAClient = "OpcUa-Client"
)

// flexInt decodes a JSON value that may be a number ("rack": 0) or a string
// ("rack": "0") — Node-RED is inconsistent (s7 rack/slot are strings, a
// modbus-client unit_id is a number). Absent ⇒ zero value + Set=false.
type flexInt struct {
	Val int
	Set bool
}

func (f *flexInt) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if s == "" || s == "null" || s == `""` {
		return nil
	}
	s = strings.Trim(s, `"`)
	if s == "" {
		return nil
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return fmt.Errorf("flexInt: %q not an integer: %w", s, err)
	}
	f.Val, f.Set = n, true
	return nil
}

// flowNode is the union of the node fields this importer reads. A Node-RED flow
// is a heterogeneous array; the fields not relevant to a node's Type stay zero.
type flowNode struct {
	ID   string `json:"id"`
	Type string `json:"type"`
	Name string `json:"name"`

	// s7 endpoint
	Address  string        `json:"address"`
	Rack     flexInt       `json:"rack"`
	Slot     flexInt       `json:"slot"`
	Vartable []vartableRow `json:"vartable"`

	// modbus-client
	TCPHost string  `json:"tcpHost"`
	TCPPort string  `json:"tcpPort"`
	UnitID  flexInt `json:"unit_id"`

	// modbus-read
	DataType string `json:"dataType"`
	Adr      string `json:"adr"`
	Quantity string `json:"quantity"`
}

type vartableRow struct {
	Addr string `json:"addr"`
	Name string `json:"name"`
}

// Options drives one import run.
type Options struct {
	// Descriptor supplies canonical.prefix (to normalize the flow's raw prefix),
	// the count-index → equipment map (to resolve bare-number tags), and the
	// equipment inventory (to look up id_equipment for a canonical topic).
	Descriptor *clientdescriptor.Descriptor
	// Tenant slug for the generated secret refs. Empty ⇒ lowercased descriptor.Tenant.
	Tenant string
	// Env for the generated secret refs (staging|production). Empty ⇒ "staging".
	Env string
}

// Result is one import's output: the descriptor plc block (marshaled with the
// skeleton/unresolved comments woven in), the operator's host provisioning table,
// warnings, and a summary the CLI prints.
type Result struct {
	// PLC is the structured (comment-free) plc block — the live, resolvable tags
	// only. Round-trips through yaml against clientdescriptor.DescriptorPLC.
	PLC clientdescriptor.DescriptorPLC
	// YAML is the emitted `plc:` block, with the modbus skeleton + unresolved
	// count-index skeletons woven in as comments (not part of PLC).
	YAML string
	// HostRefs maps each generated secret ref → the real host/URL from the flow,
	// for the operator to provision. Never emitted into YAML.
	HostRefs []HostRef
	// Warnings are the non-fatal issues (unresolved indices, modbus skeleton).
	Warnings []string

	// Counters for the CLI summary.
	NumEndpoints  int
	NumTagsMapped int
	NumUnresolved int
	NumSkeleton   int

	// Notes records benign observations (e.g. no OPC-UA nodes present).
	Notes []string
}

// HostRef is one endpoint's generated secret ref ↔ real host mapping.
type HostRef struct {
	Endpoint string
	Ref      string
	Host     string // the raw host/URL from the flow (secret VALUE — stderr only)
}

var (
	bareNumberRE = regexp.MustCompile(`^\d+$`)
	// s7AddrRE parses a vartable addr: DB<n>,<TYPE><off>[.<bit>].
	// TYPE ∈ DINT|INT|REAL|WORD|X (X = bit, requires the .<bit> group).
	s7AddrRE = regexp.MustCompile(`^DB(\d+),(DINT|INT|REAL|WORD|X)(\d+)(?:\.(\d+))?$`)
	slugRE   = regexp.MustCompile(`[^a-z0-9]+`)
)

// Import is the pure core: parse the flow bytes, project onto the descriptor,
// return the plc block + provisioning table + warnings. Deterministic.
func Import(flowJSON []byte, opts Options) (*Result, error) {
	if opts.Descriptor == nil {
		return nil, fmt.Errorf("flowimport: a descriptor is required (for canonical.prefix + count-index resolution)")
	}
	var nodes []flowNode
	if err := json.Unmarshal(flowJSON, &nodes); err != nil {
		return nil, fmt.Errorf("flowimport: parse flow json: %w", err)
	}

	tenant := strings.ToLower(strings.TrimSpace(opts.Tenant))
	if tenant == "" {
		tenant = strings.ToLower(strings.TrimSpace(opts.Descriptor.Tenant))
	}
	env := strings.TrimSpace(opts.Env)
	if env == "" {
		env = "staging"
	}
	prefix := opts.Descriptor.Canonical.Prefix

	res := &Result{}
	idxMap := buildCountIndexMap(opts.Descriptor)
	topicID := buildTopicIDMap(opts.Descriptor)

	// Ordered comment blocks appended after the structured YAML.
	var modbusSkeletons []string
	var unresolvedNotes []string

	for _, n := range nodes {
		switch n.Type {
		case nodeS7Endpoint:
			ep := clientdescriptor.DescriptorPLCEndpoint{
				Name:     n.Name,
				Protocol: clientdescriptor.PLCProtocolS7,
				HostRef:  secretRef(tenant, env, n.Name, "host", res, n.Address),
			}
			rack, slot := n.Rack.Val, n.Slot.Val
			ep.Rack, ep.Slot = &rack, &slot
			res.PLC.Endpoints = append(res.PLC.Endpoints, ep)

			// Group this endpoint's resolvable tags by packml_topic (the canonical
			// equipment path) so packml_topic+metric reconstructs the SparkPlug name.
			groups := map[string]*clientconfig.S7EndpointTags{}
			var order []string
			addTag := func(packmlTopic string, tag clientconfig.S7Tag) {
				g, ok := groups[packmlTopic]
				if !ok {
					g = &clientconfig.S7EndpointTags{
						Endpoint:    n.Name,
						PackMLTopic: packmlTopic,
						IDEquipment: topicID[packmlTopic],
					}
					groups[packmlTopic] = g
					order = append(order, packmlTopic)
				}
				g.Tags = append(g.Tags, tag)
			}

			for _, row := range n.Vartable {
				db, off, bit, typ, err := parseS7Addr(row.Addr)
				if err != nil {
					// An addr we cannot parse is a skeleton note, never a silent drop.
					unresolvedNotes = append(unresolvedNotes,
						fmt.Sprintf("endpoint %q: unparseable addr %q (name %q)", n.Name, row.Addr, row.Name))
					res.NumSkeleton++
					continue
				}
				name := strings.TrimSpace(row.Name)
				switch {
				case strings.Contains(name, "/"):
					// (a) FULL canonical name → strip ***TRIG suffix + normalize prefix.
					packmlTopic, metric, ok := splitCanonical(name, prefix)
					if !ok {
						unresolvedNotes = append(unresolvedNotes,
							fmt.Sprintf("endpoint %q: name %q has no /Admin//Status/ metric leaf — cannot split", n.Name, name))
						res.NumSkeleton++
						continue
					}
					addTag(packmlTopic, s7Tag(metric, db, off, bit, typ))
					res.NumTagsMapped++
				case bareNumberRE.MatchString(name):
					// (b) BARE NUMBER → a legacy count index. Resolve via descriptor.
					idx, _ := strconv.Atoi(name)
					if r, ok := idxMap[idx]; ok {
						addTag(r.topic, s7Tag(r.leaf, db, off, bit, typ))
						res.NumTagsMapped++
					} else {
						unresolvedNotes = append(unresolvedNotes,
							fmt.Sprintf("endpoint %q: %s → count-index %d UNRESOLVED (no descriptor mapping) — resolve to equipment + count_index",
								n.Name, row.Addr, idx))
						res.NumUnresolved++
					}
				default:
					// An opaque non-canonical, non-numeric label (e.g. "19A").
					unresolvedNotes = append(unresolvedNotes,
						fmt.Sprintf("endpoint %q: %s → unrecognized tag name %q (not canonical, not a count-index)",
							n.Name, row.Addr, name))
					res.NumUnresolved++
				}
			}
			for _, t := range order {
				res.PLC.S7TagMap = append(res.PLC.S7TagMap, *groups[t])
			}

		case nodeModbusClient:
			ep := clientdescriptor.DescriptorPLCEndpoint{
				Name:     n.Name,
				Protocol: clientdescriptor.PLCProtocolModbusTCP,
				HostRef:  secretRef(tenant, env, n.Name, "host", res, n.TCPHost),
			}
			if n.UnitID.Set {
				u := n.UnitID.Val
				ep.UnitID = &u
			}
			res.PLC.Endpoints = append(res.PLC.Endpoints, ep)

		case nodeModbusRead:
			// A block read: the per-register→metric map lives in a downstream
			// function node the flow may not carry. Emit a skeleton note only.
			q, _ := strconv.Atoi(strings.TrimSpace(n.Quantity))
			a, _ := strconv.Atoi(strings.TrimSpace(n.Adr))
			end := a
			if q > 0 {
				end = a + q - 1
			}
			modbusSkeletons = append(modbusSkeletons, fmt.Sprintf(
				"%s: %s block adr %d..%d (%d regs) — per-register→metric map lives in the downstream function node",
				n.Name, n.DataType, a, end, q))
			res.NumSkeleton++

		case nodeOPCUAItem, nodeOPCUAClient:
			// Present-but-handled path: CPACK's OPC-UA is on a separate tab, so the
			// acceptance flow has none. Record the node so it is not silently ignored.
			res.Notes = append(res.Notes, fmt.Sprintf("opcua node %q (%s) present — OPC-UA import is minimal; verify node_ids", n.Name, n.Type))
		}
	}

	res.NumEndpoints = len(res.PLC.Endpoints)
	if !hasType(nodes, nodeOPCUAItem) && !hasType(nodes, nodeOPCUAClient) {
		res.Notes = append(res.Notes, "no OPC-UA nodes in this flow (CPACK's OPC-UA lives on a separate tab) — S7 + Modbus only")
	}

	// Warnings summarize the two non-fatal classes.
	if res.NumUnresolved > 0 {
		res.Warnings = append(res.Warnings, fmt.Sprintf("%d bare/opaque S7 tag(s) UNRESOLVED — emitted as skeleton comments, NOT dropped", res.NumUnresolved))
	}
	if len(modbusSkeletons) > 0 {
		res.Warnings = append(res.Warnings, fmt.Sprintf("%d modbus block read(s) → tag-map SKELETON only (need the L6 function node's per-register map)", len(modbusSkeletons)))
	}

	yamlOut, err := renderYAML(&res.PLC, modbusSkeletons, unresolvedNotes)
	if err != nil {
		return nil, err
	}
	res.YAML = yamlOut
	return res, nil
}

// s7Tag builds a clientconfig.S7Tag from a parsed addr.
func s7Tag(metric string, db, off, bit int, typ string) clientconfig.S7Tag {
	t := clientconfig.S7Tag{Metric: metric, DB: db, Offset: off, Type: typ}
	if typ == "bool" {
		t.Bit = bit
	}
	return t
}

// parseS7Addr parses a Node-RED S7 vartable addr into (db, offset, bit, type).
// WORD is mapped to type "int" (a 16-bit word carries an integer count/value);
// X<off>.<bit> is a bool. Returns an error for an addr shape it does not know.
func parseS7Addr(addr string) (db, off, bit int, typ string, err error) {
	m := s7AddrRE.FindStringSubmatch(strings.TrimSpace(addr))
	if m == nil {
		return 0, 0, 0, "", fmt.Errorf("unrecognized S7 addr %q", addr)
	}
	db, _ = strconv.Atoi(m[1])
	off, _ = strconv.Atoi(m[3])
	switch m[2] {
	case "DINT":
		typ = "dint"
	case "INT", "WORD":
		typ = "int"
	case "REAL":
		typ = "real"
	case "X":
		typ = "bool"
		if m[4] == "" {
			return 0, 0, 0, "", fmt.Errorf("bit addr %q missing .<bit>", addr)
		}
		bit, _ = strconv.Atoi(m[4])
	}
	return db, off, bit, typ, nil
}

// splitCanonical takes a FULL canonical vartable name, strips the ***TRIG… suffix,
// normalizes its raw tenant prefix to the descriptor's canonical.prefix (the flow
// carries "C-PACK/SC…" where the canonical model is "CPACK/SC…"), then splits it
// at the first /Admin/ or /Status/ metric leaf into (packml_topic, metric). The
// split matches the descriptor's equipment-topic structure so packml_topic+metric
// reconstructs the full canonical name and, with canonical.prefix stripped, the
// agent raw_tag_map metric_suffix (the ADR-0045 §C key).
func splitCanonical(name, prefix string) (packmlTopic, metric string, ok bool) {
	// Strip the "***TRIG_C=I" style trailing directive.
	if i := strings.Index(name, "***"); i >= 0 {
		name = name[:i]
	}
	name = strings.TrimSpace(name)

	// Normalize the raw prefix to the canonical prefix by segment count: replace
	// the first N segments (N = segments in canonical.prefix) — this absorbs the
	// C-PACK → CPACK dash fixup without hard-coding it.
	nPrefix := len(strings.Split(prefix, "/"))
	segs := strings.Split(name, "/")
	if len(segs) > nPrefix {
		name = prefix + "/" + strings.Join(segs[nPrefix:], "/")
	}

	// Split at the first metric-leaf root.
	for _, root := range []string{"/Admin/", "/Status/"} {
		if i := strings.Index(name, root); i > 0 {
			return name[:i], name[i:], true
		}
	}
	return "", "", false
}

// countIndexResolved is a resolved bare-number: the equipment topic + the fully
// formed canonical metric leaf (already index-substituted).
type countIndexResolved struct {
	topic string
	leaf  string
}

// buildCountIndexMap projects the descriptor's members (CountIndex) and lines
// (LineRoles) into index → (equipment topic, canonical leaf). A bare-number S7
// tag whose value is a key here resolves to a real canonical metric; anything
// else is unresolved. A member's leaf comes from the descriptor's {idx} member
// template; a line role's leaf is /Admin/Prod<Role>Count/<idx>/Unit — the SAME
// leaf strings the oeecloud-worker classifier keys on.
func buildCountIndexMap(d *clientdescriptor.Descriptor) map[int]countIndexResolved {
	memberTmpl := "/Admin/ProdProcessedCount/{idx}/Unit"
	for _, t := range d.MetricTemplates.Member {
		if strings.Contains(t.Leaf, "{idx}") {
			memberTmpl = t.Leaf
			break
		}
	}
	m := map[int]countIndexResolved{}
	for _, e := range d.Equipment {
		if e.CountIndex != nil {
			leaf := strings.ReplaceAll(memberTmpl, "{idx}", strconv.Itoa(e.CountIndex.Value))
			m[e.CountIndex.Value] = countIndexResolved{topic: e.Topic, leaf: leaf}
		}
		for _, r := range e.LineRoles {
			roleLeaf := lineRoleLeaf(r.Role)
			if roleLeaf == "" {
				continue
			}
			m[r.CountIndex] = countIndexResolved{
				topic: e.Topic,
				leaf:  fmt.Sprintf("/Admin/%s/%d/Unit", roleLeaf, r.CountIndex),
			}
		}
	}
	return m
}

// lineRoleLeaf mirrors clientdescriptor's (private) lineRoleLeaf map.
func lineRoleLeaf(role string) string {
	switch role {
	case clientdescriptor.LineRoleConsumed:
		return "ProdConsumedCount"
	case clientdescriptor.LineRoleProcessed:
		return "ProdProcessedCount"
	case clientdescriptor.LineRoleDefective:
		return "ProdDefectiveCount"
	}
	return ""
}

// buildTopicIDMap maps a canonical equipment topic → its id_equipment, so an
// emitted tag group can carry the right id when the equipment is already in the
// descriptor (0 otherwise — the operator fills it when adding the equipment).
func buildTopicIDMap(d *clientdescriptor.Descriptor) map[string]int {
	m := map[string]int{}
	for _, e := range d.Equipment {
		m[e.Topic] = e.IDEquipment
	}
	return m
}

// secretRef generates the host secret reference and records the real host for the
// operator's provisioning table. The real host is a secret VALUE — it goes only
// into res.HostRefs (stderr), never into the returned YAML.
func secretRef(tenant, env, endpoint, kind string, res *Result, host string) string {
	ref := fmt.Sprintf("secret://packiot/%s/%s/%s-%s", env, tenant, slug(endpoint), kind)
	if strings.TrimSpace(host) != "" {
		res.HostRefs = append(res.HostRefs, HostRef{Endpoint: endpoint, Ref: ref, Host: host})
	}
	return ref
}

// slug lowercases + collapses non-alphanumerics to single dashes (endpoint names
// carry spaces: "S7 115" → "s7-115").
func slug(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	s = slugRE.ReplaceAllString(s, "-")
	return strings.Trim(s, "-")
}

func hasType(nodes []flowNode, t string) bool {
	for _, n := range nodes {
		if n.Type == t {
			return true
		}
	}
	return false
}

// renderYAML marshals the structured plc block and weaves the modbus + unresolved
// skeletons in as indented comments (yaml struct marshaling cannot carry them, and
// they must NOT become live entries — a zero-tag modbus map or an id_equipment=0
// unresolved tag would fail the clientconfig validator). The comments are notes
// for the operator; they are ignored on re-parse, so the block round-trips.
func renderYAML(plc *clientdescriptor.DescriptorPLC, modbusSkeletons, unresolvedNotes []string) (string, error) {
	var buf strings.Builder
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2) // match the descriptor's 2-space style for clean splicing
	if err := enc.Encode(map[string]any{"plc": plc}); err != nil {
		return "", fmt.Errorf("flowimport: marshal plc block: %w", err)
	}
	_ = enc.Close()
	var b strings.Builder
	b.WriteString(buf.String())
	if len(modbusSkeletons) > 0 {
		b.WriteString("\n  # ── modbus_tag_map SKELETON (per-register map from the downstream function node — NOT in this flow) ──\n")
		b.WriteString("  # modbus_tag_map:\n")
		for _, s := range modbusSkeletons {
			b.WriteString("  #   - " + s + "\n")
		}
		b.WriteString("  #     TODO: bind each register to /Admin/Prod{Consumed,Processed}Count/<idx>/Unit on its member topic\n")
	}
	if len(unresolvedNotes) > 0 {
		sort.Strings(unresolvedNotes)
		b.WriteString("\n  # ── UNRESOLVED S7 tags (count-index / opaque names — NOT dropped, resolve then add to s7_tag_map) ──\n")
		for _, s := range unresolvedNotes {
			b.WriteString("  #   " + s + "\n")
		}
	}
	return b.String(), nil
}
