package session_test

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

func rt(suffix string, v any) rawtag.RawTag {
	return rawtag.RawTag{Metric: suffix, Value: v, Quality: true, TsMillis: 1782849957000}
}

// bdSeqOf pulls the bdSeq metric's LongValue out of a payload.
func bdSeqOf(t *testing.T, p *sparkplug.Payload) uint64 {
	t.Helper()
	for _, m := range p.GetMetrics() {
		if m.GetName() == "bdSeq" {
			if lv, ok := m.GetValue().(*sparkplug.Metric_LongValue); ok {
				return lv.LongValue
			}
		}
	}
	t.Fatal("no bdSeq metric in payload")
	return 0
}

func newPub() *session.Publisher {
	return session.New(newMapResolver(), aliasmap.New())
}

// TestDefinitiveBirth_DeclaredDeviceKey proves the ADR-0046 task-#18 wiring: with
// definitive birth on and a WithDeviceKeys map, the NBIRTH count metric carries the
// DECLARED device_key; with no map entry it derives from the topic (the bridge).
func TestDefinitiveBirth_DeclaredDeviceKey(t *testing.T) {
	const countName = parityPrefix + "/Admin/ProdProcessedCount/1/Unit"

	deviceKeyOf := func(pub *session.Publisher) string {
		t.Helper()
		pl, err := pub.BuildNBIRTH([]rawtag.RawTag{rt("/Admin/ProdProcessedCount/1/Unit", 42.0)})
		if err != nil {
			t.Fatalf("BuildNBIRTH: %v", err)
		}
		for _, m := range pl.GetMetrics() {
			if m.GetName() != countName {
				continue
			}
			ps := m.GetProperties()
			for i, k := range ps.GetKeys() {
				if k == "device_key" {
					return ps.GetValues()[i].GetStringValue()
				}
			}
			t.Fatal("count metric carries no device_key property")
		}
		t.Fatalf("count metric %q not in NBIRTH", countName)
		return ""
	}

	// Declared key wins.
	declared := session.New(newMapResolver(), aliasmap.New(),
		session.WithDefinitiveBirth(true),
		session.WithDeviceKeys(map[string]string{countName: "CPACK-DECLARED-L5-BREYER"}))
	if got := deviceKeyOf(declared); got != "CPACK-DECLARED-L5-BREYER" {
		t.Errorf("declared: device_key = %q, want CPACK-DECLARED-L5-BREYER", got)
	}

	// No map entry → topic-derived bridge (parityPrefix dash-joined).
	derived := session.New(newMapResolver(), aliasmap.New(), session.WithDefinitiveBirth(true))
	if got := deviceKeyOf(derived); got != "CPACK-SC-LINHAS-L5-BREYER" {
		t.Errorf("derived: device_key = %q, want CPACK-SC-LINHAS-L5-BREYER", got)
	}
}

func TestSeqResetOnBirth(t *testing.T) {
	pub := newPub()
	pub.NewConnection()
	snap := []rawtag.RawTag{rt("/Status/MachSpeed", 10.0)}

	b, _ := pub.BuildNBIRTH(snap)
	if b.GetSeq() != 0 {
		t.Fatalf("NBIRTH seq: got %d, want 0", b.GetSeq())
	}
	d1, _ := pub.BuildNDATA(snap)
	if d1.GetSeq() != 1 {
		t.Fatalf("NDATA#1 seq: got %d, want 1", d1.GetSeq())
	}
	d2, _ := pub.BuildNDATA(snap)
	if d2.GetSeq() != 2 {
		t.Fatalf("NDATA#2 seq: got %d, want 2", d2.GetSeq())
	}
	// A fresh birth resets the rolling sequence to 0 (spec).
	b2, _ := pub.BuildNBIRTH(snap)
	if b2.GetSeq() != 0 {
		t.Fatalf("rebirth seq: got %d, want 0", b2.GetSeq())
	}
}

func TestBdSeq_BirthEqualsDeath_AndAdvancesPerConnection(t *testing.T) {
	pub := newPub()
	snap := []rawtag.RawTag{rt("/Status/MachSpeed", 10.0)}

	// Connection 1: first bdSeq is 0; birth and death Last-Will must agree.
	bd0 := pub.NewConnection()
	if bd0 != 0 {
		t.Fatalf("first connection bdSeq: got %d, want 0", bd0)
	}
	b0, _ := pub.BuildNBIRTH(snap)
	death0, _ := pub.BuildNDEATH()
	if birth, death := bdSeqOf(t, b0), bdSeqOf(t, death0); birth != death {
		t.Fatalf("bdSeq mismatch conn1: NBIRTH=%d NDEATH(will)=%d — cloud can't correlate death→birth", birth, death)
	} else if birth != 0 {
		t.Fatalf("conn1 bdSeq: got %d, want 0", birth)
	}

	// Connection 2 (a reconnect): bdSeq advances; birth/death still agree.
	bd1 := pub.NewConnection()
	if bd1 != 1 {
		t.Fatalf("second connection bdSeq: got %d, want 1", bd1)
	}
	b1, _ := pub.BuildNBIRTH(snap)
	death1, _ := pub.BuildNDEATH()
	if birth, death := bdSeqOf(t, b1), bdSeqOf(t, death1); birth != death || birth != 1 {
		t.Fatalf("conn2 bdSeq: NBIRTH=%d NDEATH=%d, want both 1", birth, death)
	}
}

func TestNewTagForcesRebirth(t *testing.T) {
	pub := newPub()
	pub.NewConnection()

	// Birth freezes the alias for MachSpeed.
	pub.BuildNBIRTH([]rawtag.RawTag{rt("/Status/MachSpeed", 10.0)})

	// A dirty set of already-aliased tags needs no rebirth.
	if pub.NeedsRebirth([]rawtag.RawTag{rt("/Status/MachSpeed", 11.0)}) {
		t.Fatal("known tag must not force rebirth")
	}
	// A brand-new tag (never frozen into a BIRTH) forces a rebirth — else its
	// alias-only NDATA is unresolvable at the cloud.
	if !pub.NeedsRebirth([]rawtag.RawTag{rt("/Status/StateCurrent", 6)}) {
		t.Fatal("new tag must force rebirth")
	}
}
