package main

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/birthbind"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// TestDefinitiveBirth_SimProducerToConsumerRoundTrip closes the ADR-0046 birth-
// bound gap for the SIM ingest path: it proves plc-sim's DEFINITIVE BIRTH is a
// CONFORMANT PRODUCER for the birth-bound consumer. The consumer path
// (birthbind.ApplyBirth → Lookup) has NO name-parse fallback — an alias with no
// live binding is dropped + rebirthed — so if the sim's birth omitted the
// role/device_key properties (the flag-OFF legacy shape), a birth-bound flip
// would drop every plc-sim counter. This test drives the two ends TOGETHER:
//
//	producer:  buildBirthMetrics(emitDefinitive=true) → EncodeSim(isBirth) → wire
//	consumer:  Decode → birthbind.ApplyBirth (MapResolver) → Lookup(alias)
//
// and asserts a synthetic DDATA alias routes to the right (id_equipment, role).
// The MapResolver stands in for packml_register (the identity SSoT), mapping the
// dash-joined equipment topics the sim declares as device_key.
func TestDefinitiveBirth_SimProducerToConsumerRoundTrip(t *testing.T) {
	const edgeNode = "plc-sim"

	// packml_register stand-in: device_key (dash-joined equipment topic) →
	// id_equipment. Keys must match what the sim derives at birth (topicPrefix
	// with "/"→"-"). Values are the staging surrogate ids from the topology map.
	resolver := birthbind.MapResolver{
		"CPACK-SC-LINHAS-L5":        47, // L5 line own-stream
		"CPACK-SC-LINHAS-L5-BREYER": 53, // L5/BREYER member
		"CPACK-SC-LINHAS-L3-PTH":    61, // L3/PTH member
	}

	// Produce a DEFINITIVE birth from the real sim builder (flag ON). Fresh zero
	// state is fine — routing is declared by name/alias/props, not by value.
	states := make([]simState, len(lines))
	for i := range states {
		states[i] = simState{state: 6}
	}
	ms := buildBirthMetrics(lines, states, true)

	var seq uint64
	body, err := sparkplug.EncodeSim(ms, &seq, true)
	if err != nil {
		t.Fatalf("EncodeSim NBIRTH: %v", err)
	}
	pl, err := sparkplug.Decode(body)
	if err != nil {
		t.Fatalf("Decode NBIRTH: %v", err)
	}

	// CONSUMER side: bind the node-scoped birth (deviceID empty; device_key rides
	// as a metric property, contract §3).
	table := birthbind.NewTable(resolver)
	bound, skipped := table.ApplyBirth(edgeNode, "", pl, nil)
	// Three counters × three resolvable device_keys = 9 bindings. Counters whose
	// device_key is NOT in the resolver (the other lines/members) fail closed →
	// skipped, never guessed.
	if bound != 9 {
		t.Fatalf("ApplyBirth bound = %d, want 9 (3 counters × 3 resolvable devices); skipped=%d", bound, skipped)
	}

	// Assert each declared counter alias routes to the expected (id, role). The
	// aliases are the sim's stable base+offset scheme (base=(lineIdx+1)*10;
	// +1=Consumed/gross, +2=Processed/net, +3=Defective/scrap) — the SAME table
	// a real DDATA references by alias only.
	type want struct {
		alias uint64
		id    int
		role  birthbind.Role
	}
	lineIdx := indexByTopic(t) // topicPrefix → position in `lines`
	cases := []want{
		{aliasFor(lineIdx["CPACK/SC/LINHAS/L5"], 1), 47, birthbind.RoleGross},
		{aliasFor(lineIdx["CPACK/SC/LINHAS/L5"], 2), 47, birthbind.RoleNet},
		{aliasFor(lineIdx["CPACK/SC/LINHAS/L5"], 3), 47, birthbind.RoleScrap},
		{aliasFor(lineIdx["CPACK/SC/LINHAS/L5/BREYER"], 1), 53, birthbind.RoleGross},
		{aliasFor(lineIdx["CPACK/SC/LINHAS/L5/BREYER"], 2), 53, birthbind.RoleNet},
		{aliasFor(lineIdx["CPACK/SC/LINHAS/L3/PTH"], 3), 61, birthbind.RoleScrap},
	}
	for _, c := range cases {
		b, ok := table.Lookup(edgeNode, c.alias)
		if !ok {
			t.Errorf("Lookup(alias=%d): no binding — a birth-bound flip would DROP this counter", c.alias)
			continue
		}
		if b.IDEquipment != c.id || b.Role != c.role {
			t.Errorf("Lookup(alias=%d) = (id=%d, role=%s), want (id=%d, role=%s)",
				c.alias, b.IDEquipment, b.Role, c.id, c.role)
		}
	}

	// SYNTHETIC DDATA: the routing is by alias ONLY (no name, no props on DDATA),
	// exactly as the sim's tick loop emits. Prove the gross counter for L5/BREYER
	// resolves through the DDATA-shaped payload the consumer actually sees.
	grossAlias := aliasFor(lineIdx["CPACK/SC/LINHAS/L5/BREYER"], 1)
	ddata, err := sparkplug.EncodeSim(
		[]sparkplug.SimMetric{{Alias: grossAlias, Double: 1234}}, &seq, false)
	if err != nil {
		t.Fatalf("EncodeSim NDATA: %v", err)
	}
	dp, err := sparkplug.Decode(ddata)
	if err != nil {
		t.Fatalf("Decode NDATA: %v", err)
	}
	m := dp.GetMetrics()[0]
	if m.GetName() != "" || m.GetProperties() != nil {
		t.Fatalf("DDATA metric must be alias+value only (name=%q, props=%v)", m.GetName(), m.GetProperties())
	}
	b, ok := table.Lookup(edgeNode, m.GetAlias())
	if !ok || b.IDEquipment != 53 || b.Role != birthbind.RoleGross {
		t.Fatalf("DDATA alias=%d routed to (id=%d, role=%s, ok=%v), want (53, gross, true)",
			m.GetAlias(), b.IDEquipment, b.Role, ok)
	}
}

// TestDefinitiveBirth_FlagOffNoProperties pins the no-op invariant: with the flag
// OFF the birth carries NO counter_role property, so the birth-bound consumer
// binds nothing (every counter fails closed). This is what makes the flag a safe,
// reversible deploy — OFF producer + OFF consumer is the current legacy path.
func TestDefinitiveBirth_FlagOffNoProperties(t *testing.T) {
	states := make([]simState, len(lines))
	ms := buildBirthMetrics(lines, states, false)
	for _, m := range ms {
		if m.Props != nil {
			t.Fatalf("flag OFF: metric %q carries Props — birth must be byte-identical to legacy", m.Name)
		}
	}
	var seq uint64
	body, _ := sparkplug.EncodeSim(ms, &seq, true)
	pl, _ := sparkplug.Decode(body)
	table := birthbind.NewTable(birthbind.MapResolver{"CPACK-SC-LINHAS-L5-BREYER": 53})
	if bound, _ := table.ApplyBirth("plc-sim", "", pl, nil); bound != 0 {
		t.Fatalf("flag OFF: ApplyBirth bound = %d, want 0 (no role properties to bind)", bound)
	}
}

// aliasFor reproduces the sim's stable alias scheme: base=(lineIdx+1)*10, then
// +off (1=Consumed, 2=Processed, 3=Defective) — the same offsets line.metrics
// assigns. Kept local to the test so a scheme change here fails loudly.
func aliasFor(lineIdx int, off uint64) uint64 { return uint64((lineIdx+1)*10) + off }

// indexByTopic maps each line's topicPrefix to its position in the `lines`
// table, so the test refers to lines by topic instead of brittle numeric
// indices. Fails if two entries share a topicPrefix (they must not).
func indexByTopic(t *testing.T) map[string]int {
	t.Helper()
	m := make(map[string]int, len(lines))
	for i, l := range lines {
		p := l.topicPrefix()
		if _, dup := m[p]; dup {
			t.Fatalf("duplicate topicPrefix %q in lines table", p)
		}
		m[p] = i
	}
	return m
}
