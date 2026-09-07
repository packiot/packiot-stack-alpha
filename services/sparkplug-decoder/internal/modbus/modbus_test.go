package modbus

import (
	"encoding/binary"
	"math"
	"testing"
)

func TestDecoders(t *testing.T) {
	// Two registers holding an ABCD (big-endian word order) uint32 = 0x0001E240
	// = 123456, plus a float32 and a signed 16-bit register.
	buf := make([]byte, 12)
	binary.BigEndian.PutUint16(buf[0:], 0x0001) // high word
	binary.BigEndian.PutUint16(buf[2:], 0xE240) // low word  → 123456
	binary.BigEndian.PutUint32(buf[4:], math.Float32bits(88.5))
	neg := int16(-7)
	binary.BigEndian.PutUint16(buf[8:], uint16(neg)) // reinterpret via variable (constant conv would overflow)

	if v, ok := GetUint32(buf, 0, false); !ok || v != 123456 {
		t.Fatalf("GetUint32 ABCD = %d,%v want 123456", v, ok)
	}
	// Same bytes read word-swapped (CDAB) must NOT equal 123456 — proves the
	// swap actually reorders the words (0xE2400001).
	if v, ok := GetUint32(buf, 0, true); !ok || v != 0xE2400001 {
		t.Fatalf("GetUint32 CDAB = %#x,%v want 0xE2400001", v, ok)
	}
	if v, ok := GetFloat32(buf, 4, false); !ok || v != 88.5 {
		t.Fatalf("GetFloat32 = %v,%v want 88.5", v, ok)
	}
	if v, ok := GetInt16(buf, 8); !ok || v != -7 {
		t.Fatalf("GetInt16 = %d,%v want -7", v, ok)
	}
	if v, ok := GetUint16(buf, 0); !ok || v != 1 {
		t.Fatalf("GetUint16 = %d,%v want 1", v, ok)
	}
	// Out-of-bounds must not panic and must report !ok.
	if _, ok := GetUint32(buf, 10, false); ok {
		t.Fatalf("GetUint32 past end should be !ok")
	}
}

func TestCoilDecode(t *testing.T) {
	// Coils packed LSB-first: bit0 and bit9 set → byte0=0x01, byte1=0x02.
	buf := []byte{0x01, 0x02}
	if v, ok := GetCoil(buf, 0); !ok || !v {
		t.Fatalf("coil0 = %v,%v want true", v, ok)
	}
	if v, ok := GetCoil(buf, 1); !ok || v {
		t.Fatalf("coil1 = %v,%v want false", v, ok)
	}
	if v, ok := GetCoil(buf, 9); !ok || !v {
		t.Fatalf("coil9 = %v,%v want true", v, ok)
	}
	if _, ok := GetCoil(buf, 16); ok {
		t.Fatalf("coil16 past end should be !ok")
	}
}

func TestPollerSample(t *testing.T) {
	const prefix = "CPACK/PLANT/LINE1/MACH_1/MACH_1"
	tags := []Tag{
		{Metric: prefix + "/Admin/ProdProcessedCount/1/Unit", Alias: 1, Kind: KindHolding, Address: 0, Type: TypeUint32},
		{Metric: prefix + "/Status/MachSpeed", Alias: 2, Kind: KindHolding, Address: 2, Type: TypeFloat32},
		{Metric: prefix + "/Status/StateCurrent", Alias: 3, Kind: KindHolding, Address: 4, Type: TypeInt16, Long: true},
		{Metric: prefix + "/Status/Running", Alias: 4, Kind: KindCoil, Address: 0, Type: TypeBool},
	}
	p, err := NewPoller(tags)
	if err != nil {
		t.Fatalf("NewPoller: %v", err)
	}

	// Fake device: holding[0..4] = [uint32 42000][float32 120.0][int16 6];
	// coil[0] = true.
	hold := make([]byte, 10)
	binary.BigEndian.PutUint32(hold[0:], 42000)
	binary.BigEndian.PutUint32(hold[4:], math.Float32bits(120.0))
	binary.BigEndian.PutUint16(hold[8:], uint16(int16(6)))
	coils := []byte{0x01}
	read := func(kind Kind, start, qty uint16) ([]byte, error) {
		switch kind {
		case KindHolding:
			return hold[start*2 : (start+qty)*2], nil
		case KindCoil:
			return coils, nil
		default:
			t.Fatalf("unexpected kind %v", kind)
			return nil, nil
		}
	}

	// NBIRTH: names present.
	ms, err := p.Sample(read, true)
	if err != nil {
		t.Fatalf("Sample birth: %v", err)
	}
	if len(ms) != 4 {
		t.Fatalf("want 4 metrics, got %d", len(ms))
	}
	if ms[0].Name != tags[0].Metric || ms[0].Double != 42000 {
		t.Fatalf("processed = name=%q val=%v", ms[0].Name, ms[0].Double)
	}
	if ms[1].Double != 120.0 {
		t.Fatalf("machspeed = %v want 120", ms[1].Double)
	}
	if !ms[2].IsLong || ms[2].Long != 6 {
		t.Fatalf("state = long=%v val=%d want long 6", ms[2].IsLong, ms[2].Long)
	}
	if ms[3].Double != 1 {
		t.Fatalf("running coil = %v want 1", ms[3].Double)
	}

	// NDATA: names omitted (alias-only).
	ms2, err := p.Sample(read, false)
	if err != nil {
		t.Fatalf("Sample data: %v", err)
	}
	if ms2[0].Name != "" {
		t.Fatalf("NDATA must omit names, got %q", ms2[0].Name)
	}
	if ms2[0].Alias != 1 {
		t.Fatalf("NDATA must carry alias, got %d", ms2[0].Alias)
	}
}

func TestPollerScaleAndReadPlan(t *testing.T) {
	tags := []Tag{
		{Metric: "T/speed", Alias: 1, Kind: KindHolding, Address: 0, Type: TypeUint16, Scale: 0.1},
		{Metric: "T/count", Alias: 2, Kind: KindHolding, Address: 1, Type: TypeUint32},
	}
	p, _ := NewPoller(tags)
	plan := p.readPlan()
	// span: min addr 0, max end = 1+2 = 3 → start 0, end 3.
	if s := plan[KindHolding]; s.start != 0 || s.end != 3 {
		t.Fatalf("read plan holding = %+v want {0 3}", s)
	}
	// Registers 0..2: [250][X X] where reg0=250 → 250*0.1 = 25.0.
	hold := make([]byte, 6)
	binary.BigEndian.PutUint16(hold[0:], 250)
	binary.BigEndian.PutUint32(hold[2:], 999)
	ms, err := p.Sample(func(_ Kind, _, _ uint16) ([]byte, error) { return hold, nil }, false)
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}
	if ms[0].Double != 25.0 {
		t.Fatalf("scaled speed = %v want 25.0", ms[0].Double)
	}
	if ms[1].Double != 999 {
		t.Fatalf("count = %v want 999", ms[1].Double)
	}
}

func TestNewPollerValidation(t *testing.T) {
	if _, err := NewPoller(nil); err == nil {
		t.Fatal("empty tags must error")
	}
	dup := []Tag{
		{Metric: "a", Alias: 1, Kind: KindHolding, Type: TypeUint16},
		{Metric: "b", Alias: 1, Kind: KindHolding, Type: TypeUint16},
	}
	if _, err := NewPoller(dup); err == nil {
		t.Fatal("duplicate alias must error")
	}
	if _, err := NewPoller([]Tag{{Metric: "", Alias: 1, Kind: KindHolding, Type: TypeUint16}}); err == nil {
		t.Fatal("empty metric must error")
	}
}
