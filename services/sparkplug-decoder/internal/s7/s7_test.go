package s7

import (
	"encoding/binary"
	"math"
	"testing"
)

func TestDecoders(t *testing.T) {
	// Build a buffer with known big-endian values.
	buf := make([]byte, 16)
	neg := int16(-7)
	binary.BigEndian.PutUint16(buf[0:], uint16(neg))           // INT at 0
	binary.BigEndian.PutUint32(buf[2:], uint32(int32(123456))) // DINT at 2
	binary.BigEndian.PutUint32(buf[6:], math.Float32bits(88.5)) // REAL at 6
	buf[10] = 0b0000_0100                                      // bit 2 set at byte 10

	if v, ok := GetInt(buf, 0); !ok || v != -7 {
		t.Fatalf("GetInt = %d,%v want -7", v, ok)
	}
	if v, ok := GetDInt(buf, 2); !ok || v != 123456 {
		t.Fatalf("GetDInt = %d,%v want 123456", v, ok)
	}
	if v, ok := GetReal(buf, 6); !ok || v != 88.5 {
		t.Fatalf("GetReal = %v,%v want 88.5", v, ok)
	}
	if v, ok := GetBool(buf, 10, 2); !ok || !v {
		t.Fatalf("GetBool bit2 = %v,%v want true", v, ok)
	}
	if v, ok := GetBool(buf, 10, 1); !ok || v {
		t.Fatalf("GetBool bit1 = %v,%v want false", v, ok)
	}
	// Out-of-bounds must not panic and must report !ok.
	if _, ok := GetDInt(buf, 14); ok {
		t.Fatalf("GetDInt past end should be !ok")
	}
}

func TestPollerSample(t *testing.T) {
	const prefix = "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15/NOVOFLEX_15"
	tags := []Tag{
		{Metric: prefix + "/Admin/ProdProcessedCount/1/Unit", Alias: 1, DB: 100, Offset: 0, Type: TypeDInt},
		{Metric: prefix + "/Status/MachSpeed", Alias: 2, DB: 100, Offset: 4, Type: TypeReal},
		{Metric: prefix + "/Status/StateCurrent", Alias: 3, DB: 100, Offset: 8, Type: TypeInt, Long: true},
	}
	p, err := NewPoller(tags)
	if err != nil {
		t.Fatalf("NewPoller: %v", err)
	}

	// Fake PLC: DB100 = [DINT 42000][REAL 120.0][INT 6].
	db := make([]byte, 10)
	binary.BigEndian.PutUint32(db[0:], uint32(int32(42000)))
	binary.BigEndian.PutUint32(db[4:], math.Float32bits(120.0))
	binary.BigEndian.PutUint16(db[8:], uint16(int16(6)))
	read := func(dbNum, start, size int) ([]byte, error) {
		if dbNum != 100 {
			t.Fatalf("unexpected DB %d", dbNum)
		}
		if size > len(db) {
			t.Fatalf("read size %d exceeds fake DB %d", size, len(db))
		}
		return db[start : start+size], nil
	}

	// NBIRTH: names present.
	ms, err := p.Sample(read, true)
	if err != nil {
		t.Fatalf("Sample birth: %v", err)
	}
	if len(ms) != 3 {
		t.Fatalf("want 3 metrics, got %d", len(ms))
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
		{Metric: "T/speed", Alias: 1, DB: 5, Offset: 0, Type: TypeInt, Scale: 0.1},
		{Metric: "T/count", Alias: 2, DB: 5, Offset: 2, Type: TypeDInt},
	}
	p, _ := NewPoller(tags)
	if plan := p.dbReadPlan(); plan[5] != 6 { // max(0+2, 2+4)=6
		t.Fatalf("read plan DB5 = %d want 6", plan[5])
	}
	db := make([]byte, 6)
	binary.BigEndian.PutUint16(db[0:], 250) // 250 * 0.1 = 25.0
	binary.BigEndian.PutUint32(db[2:], 999)
	ms, err := p.Sample(func(int, int, int) ([]byte, error) { return db, nil }, false)
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}
	if ms[0].Double != 25.0 {
		t.Fatalf("scaled speed = %v want 25.0", ms[0].Double)
	}
}

func TestNewPollerValidation(t *testing.T) {
	if _, err := NewPoller(nil); err == nil {
		t.Fatal("empty tags must error")
	}
	dup := []Tag{{Metric: "a", Alias: 1, Type: TypeInt}, {Metric: "b", Alias: 1, Type: TypeInt}}
	if _, err := NewPoller(dup); err == nil {
		t.Fatal("duplicate alias must error")
	}
	if _, err := NewPoller([]Tag{{Metric: "", Alias: 1, Type: TypeInt}}); err == nil {
		t.Fatal("empty metric must error")
	}
}
