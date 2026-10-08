package main

import (
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/birthbind"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// 47 = a line own-stream (no registered counter path); 68 = a machine with registered gross + net paths, no scrap.
var testBindings = []binding{
	{IDEquipment: 47, DeviceKey: "dk_00000000000000000000000000000047", Topic: "Client 1/SC/Area 1/L5",
		Carries: map[uint64]bool{slotGross: true, slotNet: true, slotScrap: true, slotSpeed: true}}, // no state
	{IDEquipment: 68, DeviceKey: "dk_00000000000000000000000000000068", Topic: "Client 1/SC/Area 1/L6/BREYER",
		Counters: parseCounters([]string{
			"ProdConsumedCount|Client 1/SC/Area 1/L6/BREYER/Admin/ProdConsumedCount/91/Unit",
			"ProdProcessedCount|Client 1/SC/Area 1/L6/BREYER/Admin/ProdProcessedCount/91/Unit",
			"ProdConsumedCount|Client 1/SC/Area 1/L6/BREYER/Admin/ProdConsumedCount/91/Unit", // seed duplicate
		}),
		Carries: map[uint64]bool{slotGross: true, slotNet: true, slotScrap: true, slotSpeed: true, slotState: true}},
	// 53: registered net path, but the seed never carries net → net must not be published (it would read as scrap)
	{IDEquipment: 53, DeviceKey: "dk_00000000000000000000000000000053", Topic: "Client 1/SC/Area 1/L5/BREYER",
		Carries: map[uint64]bool{slotGross: true, slotScrap: true, slotSpeed: true, slotState: true}},
}

func freshState() (map[int]int, map[int]*eqState) {
	idx, st := map[int]int{}, map[int]*eqState{}
	for i, b := range testBindings {
		idx[b.IDEquipment], st[b.IDEquipment] = i, &eqState{}
	}
	return idx, st
}

// The birth seed-replay emits must bind on the REAL consumer (birthbind): every counter, state and speed metric
// routes by alias to the equipment its declared device_key resolves to — never by name.
func TestBirth_ProducerToConsumerRoundTrip(t *testing.T) {
	_, st := freshState()
	ms, err := buildBirth(testBindings, st)
	if err != nil {
		t.Fatal(err)
	}
	var seq uint64
	body, err := sparkplug.EncodeSim(ms, &seq, true)
	if err != nil {
		t.Fatal(err)
	}
	pl, err := sparkplug.Decode(body)
	if err != nil {
		t.Fatal(err)
	}
	table := birthbind.NewTable(birthbind.MapResolver{
		testBindings[0].DeviceKey: 47,
		testBindings[1].DeviceKey: 68,
		testBindings[2].DeviceKey: 53,
	})
	res := table.ApplyBirth("DEV", "seed-replay", "", true, pl, nil)
	// 47: 3 synthesized counters + speed (no state); 68: its 2 registered counters + speed + state;
	// 53: gross + scrap (no net carried) + speed + state
	if res.Bound != 12 || res.Skipped() != 0 {
		t.Fatalf("bound %d, want 12; skipped=%d", res.Bound, res.Skipped())
	}
	for _, m := range pl.GetMetrics() {
		if m.GetName() == "Client 1/SC/Area 1/L5/Status/StateCurrent" || m.GetName() == "Client 1/SC/Area 1/L5/BREYER/Admin/ProdProcessedCount/53/Unit" {
			t.Errorf("published %q, which the seed never carries", m.GetName())
		}
	}
	roles := map[uint64]birthbind.Role{slotGross: birthbind.RoleGross, slotNet: birthbind.RoleNet, slotScrap: birthbind.RoleScrap}
	for i, b := range testBindings {
		for slot, want := range roles {
			got, ok := table.Lookup("DEV", "seed-replay", aliasBase(i)+slot)
			if b.metricName(slot) == "" {
				if ok {
					t.Errorf("eq %d slot %d is not registered but bound", b.IDEquipment, slot)
				}
				continue
			}
			if !ok || got.IDEquipment != b.IDEquipment || got.Role != want {
				t.Errorf("alias %d → (%d, %s, %v), want (%d, %s)", aliasBase(i)+slot, got.IDEquipment, got.Role, ok, b.IDEquipment, want)
			}
		}
	}
	// names: registered paths verbatim; the line gets the own-stream shape; state under the shortest topic
	names := map[string]bool{}
	for _, m := range pl.GetMetrics() {
		names[m.GetName()] = true
	}
	for _, n := range []string{
		"Client 1/SC/Area 1/L6/BREYER/Admin/ProdConsumedCount/91/Unit",
		"Client 1/SC/Area 1/L6/BREYER/Status/StateCurrent",
		"Client 1/SC/Area 1/L5/Admin/ProdProcessedCount/47/Unit",
		"Client 1/SC/Area 1/L5/Status/MachSpeed",
	} {
		if !names[n] {
			t.Errorf("birth lacks %q", n)
		}
	}
	if names["Client 1/SC/Area 1/L6/BREYER/Admin/ProdDefectiveCount/91/Unit"] {
		t.Error("68 has no registered scrap path but one was invented")
	}
	for i, b := range testBindings {
		for slot, want := range map[uint64]string{slotState: "state.current", slotSpeed: "speed.current"} {
			if b.metricName(slot) == "" {
				continue
			}
			got, ok := table.Lookup("DEV", "seed-replay", aliasBase(i)+slot)
			if !ok || got.IDEquipment != b.IDEquipment || got.Declared != want {
				t.Errorf("alias %d → (%d, %q, %v), want (%d, %q)", aliasBase(i)+slot, got.IDEquipment, got.Declared, ok, b.IDEquipment, want)
			}
		}
	}
	// every birth metric declares its role + device_key (ADR-0061 D2) — except the spec's bdSeq session metric
	for _, m := range pl.GetMetrics() {
		if m.GetName() == "bdSeq" {
			continue
		}
		var role, key string
		ps := m.GetProperties()
		for k, name := range ps.GetKeys() {
			switch name {
			case "role":
				role = ps.GetValues()[k].GetStringValue()
			case "device_key":
				key = ps.GetValues()[k].GetStringValue()
			}
		}
		if role == "" || key == "" {
			t.Errorf("birth metric %q: role=%q device_key=%q — every metric must declare both", m.GetName(), role, key)
		}
	}
}

// Counters are cumulative running sums of the seed increments; equipments without rows send nothing; a line
// (no state in the seed) sends counters but no state.
func TestStep_CumulativeCountersAndReportByException(t *testing.T) {
	idx, st := freshState()
	ts := time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)
	rows := []sample{
		{IDEquipment: 68, Ts: ts, Gross: 37, Net: 36, HasGross: true, HasNet: true, Speed: 148, HasSpeed: true, State: 6, HasState: true},
		{IDEquipment: 68, Ts: ts.Add(15 * time.Second), Gross: 38, Net: 37, Scrap: 1, HasGross: true, HasNet: true, HasScrap: true},
		// 53 sends gross only in this row: net/scrap NULL must not be sent as 0
		{IDEquipment: 53, Ts: ts, Gross: 37, HasGross: true},
	}
	ms := step(testBindings, idx, st, rows)
	got := map[uint64]sparkplug.SimMetric{}
	for _, m := range ms {
		got[m.Alias] = m
	}
	b68 := aliasBase(idx[68])
	if got[b68+slotGross].Double != 75 || got[b68+slotNet].Double != 73 {
		t.Fatalf("counters not cumulative: %+v", ms)
	}
	if _, ok := got[b68+slotScrap]; ok {
		t.Fatal("68 has no registered scrap path but sent scrap")
	}
	if got[b68+slotState].Long != 6 || got[b68+slotSpeed].Double != 148 {
		t.Fatalf("state/speed not sent: %+v", ms)
	}
	if _, ok := got[aliasBase(idx[47])+slotGross]; ok {
		t.Fatal("equipment 47 had no rows but sent data")
	}
	b53 := aliasBase(idx[53])
	if got[b53+slotGross].Double != 37 {
		t.Fatalf("53 gross = %v, want 37", got[b53+slotGross].Double)
	}
	for _, sl := range []uint64{slotNet, slotScrap, slotState, slotSpeed} {
		if _, ok := got[b53+sl]; ok {
			t.Errorf("53 slot %d was NULL in the row but sent", sl)
		}
	}

	// next window: line 47 counters only, 68 keeps counting from 75
	ms = step(testBindings, idx, st, []sample{
		{IDEquipment: 47, Ts: ts.Add(30 * time.Second), Gross: 10, Net: 10, HasGross: true, HasNet: true},
		{IDEquipment: 68, Ts: ts.Add(30 * time.Second), Gross: 5, Net: 5, HasGross: true, HasNet: true},
	})
	got = map[uint64]sparkplug.SimMetric{}
	for _, m := range ms {
		got[m.Alias] = m
	}
	if got[b68+slotGross].Double != 80 {
		t.Fatalf("68 gross = %v, want 80", got[b68+slotGross].Double)
	}
	b47 := aliasBase(idx[47])
	if got[b47+slotGross].Double != 10 {
		t.Fatalf("47 gross = %v, want 10", got[b47+slotGross].Double)
	}
	if _, ok := got[b47+slotState]; ok {
		t.Fatal("line 47 has no state in the seed but sent one")
	}
}

func TestParseEnterprises(t *testing.T) {
	if got, err := parseEnterprises(" 3, 5 "); err != nil || len(got) != 2 || got[0] != 3 || got[1] != 5 {
		t.Fatalf("got %v %v", got, err)
	}
	if got, err := parseEnterprises(""); err != nil || got != nil {
		t.Fatalf("empty: got %v %v", got, err)
	}
	if _, err := parseEnterprises("x"); err == nil {
		t.Fatal("want error for non-integer")
	}
}
