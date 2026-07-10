// These tests drive the PROJECT'S REAL S7 client (internal/s7.Client, which
// wraps the gos7 pure-Go S7comm client) against the in-memory soft-PLC over a
// real TCP socket. Nothing is stubbed on the wire: the client performs the full
// COTP CR/CC handshake, S7 setup-communication PDU negotiation, and a ReadVar
// round-trip, and we assert the bytes that come back are exactly what we seeded.
// If the framing in softplc.go is off by a single byte, the real client fails to
// read and these tests go red — that is the point.
package softplc

import (
	"encoding/binary"
	"math"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/s7"
)

// DB100 seed layout — mirrors the demo tag set in cmd/s7-reader/main.go:
//
//	offset 0  DINT ProdProcessedCount = 123456
//	offset 4  DINT ProdConsumedCount  = 1000
//	offset 8  REAL MachSpeed          = 42.5
//	offset 12 INT  StateCurrent       = 6   (bytes 14..15 are zero padding)
const (
	seedProcessed = int32(123456)
	seedConsumed  = int32(1000)
	seedSpeed     = float32(42.5)
	seedState     = int16(6)
)

func seedDB100() []byte {
	db := make([]byte, 16)
	binary.BigEndian.PutUint32(db[0:], uint32(seedProcessed))
	binary.BigEndian.PutUint32(db[4:], uint32(seedConsumed))
	binary.BigEndian.PutUint32(db[8:], math.Float32bits(seedSpeed))
	binary.BigEndian.PutUint16(db[12:], uint16(seedState))
	return db
}

// startServer spins up a soft-PLC seeded with DB100 and returns it; the caller
// defers Close.
func startServer(t *testing.T) *Server {
	t.Helper()
	srv := New(map[int][]byte{100: seedDB100()})
	if err := srv.Start(); err != nil {
		t.Fatalf("soft-PLC Start: %v", err)
	}
	return srv
}

// TestRealClientReadsSeededBytes is the core wire test: the real gos7 client
// connects, negotiates, and AGReadDB(100, 0, 16) must return the exact 16 seeded
// bytes. This alone proves the CR/CC, setup ack, and ReadVar framing are correct.
func TestRealClientReadsSeededBytes(t *testing.T) {
	srv := startServer(t)
	defer srv.Close()

	client := s7.NewClient(srv.Addr(), 0, 2, 2*time.Second)
	defer client.Close()

	got, err := client.Read(100, 0, 16)
	if err != nil {
		t.Fatalf("client.Read(100,0,16): %v", err)
	}
	want := seedDB100()
	if len(got) != len(want) {
		t.Fatalf("read length = %d, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("byte %d = 0x%02x, want 0x%02x (full got=% x)", i, got[i], want[i], got)
		}
	}

	// Decode the raw bytes the same way the S7 decoders will, to prove the
	// big-endian layout survived the round-trip end to end.
	if v, _ := s7.GetDInt(got, 0); v != seedProcessed {
		t.Fatalf("ProdProcessedCount = %d, want %d", v, seedProcessed)
	}
	if v, _ := s7.GetDInt(got, 4); v != seedConsumed {
		t.Fatalf("ProdConsumedCount = %d, want %d", v, seedConsumed)
	}
	if v, _ := s7.GetReal(got, 8); v != seedSpeed {
		t.Fatalf("MachSpeed = %v, want %v", v, seedSpeed)
	}
	if v, _ := s7.GetInt(got, 12); v != seedState {
		t.Fatalf("StateCurrent = %d, want %d", v, seedState)
	}
}

// TestRealClientPartialRead exercises a sub-range read (start offset != 0), so
// the ReadVar address decoding (bit-address >> 3) is verified too.
func TestRealClientPartialRead(t *testing.T) {
	srv := startServer(t)
	defer srv.Close()

	client := s7.NewClient(srv.Addr(), 0, 2, 2*time.Second)
	defer client.Close()

	// Read just the MachSpeed REAL at offset 8 (4 bytes).
	got, err := client.Read(100, 8, 4)
	if err != nil {
		t.Fatalf("client.Read(100,8,4): %v", err)
	}
	if v, _ := s7.GetReal(got, 0); v != seedSpeed {
		t.Fatalf("partial MachSpeed = %v, want %v", v, seedSpeed)
	}
}

// TestPollerRoundTripsThroughRealClient wires the real client into an s7.Poller
// (the production path cmd/s7-reader uses) and asserts the seeded values arrive
// as SparkPlug metrics through EncodeBirth/EncodeData. Sample() carries the
// decoded values; EncodeBirth/EncodeData prove the encode path accepts them.
func TestPollerRoundTripsThroughRealClient(t *testing.T) {
	srv := startServer(t)
	defer srv.Close()

	client := s7.NewClient(srv.Addr(), 0, 2, 2*time.Second)
	defer client.Close()

	const prefix = "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15/NOVOFLEX_15"
	tags := []s7.Tag{
		{Metric: prefix + "/Admin/ProdProcessedCount/1/Unit", Alias: 1, DB: 100, Offset: 0, Type: s7.TypeDInt},
		{Metric: prefix + "/Admin/ProdConsumedCount/1/Unit", Alias: 2, DB: 100, Offset: 4, Type: s7.TypeDInt},
		{Metric: prefix + "/Status/MachSpeed", Alias: 3, DB: 100, Offset: 8, Type: s7.TypeReal},
		{Metric: prefix + "/Status/StateCurrent", Alias: 4, DB: 100, Offset: 12, Type: s7.TypeInt, Long: true},
	}
	poller, err := s7.NewPoller(tags)
	if err != nil {
		t.Fatalf("NewPoller: %v", err)
	}

	// Sample(birth=true) reads all four tags through the real client in ONE
	// AGReadDB (dbReadPlan reads offset 0..16) and returns decoded metrics.
	ms, err := poller.Sample(client.Read, true)
	if err != nil {
		t.Fatalf("poller.Sample: %v", err)
	}
	if len(ms) != 4 {
		t.Fatalf("want 4 metrics, got %d", len(ms))
	}
	if ms[0].Name != tags[0].Metric || ms[0].Double != float64(seedProcessed) {
		t.Fatalf("processed metric = name=%q val=%v want %d", ms[0].Name, ms[0].Double, seedProcessed)
	}
	if ms[1].Double != float64(seedConsumed) {
		t.Fatalf("consumed = %v want %d", ms[1].Double, seedConsumed)
	}
	if ms[2].Double != float64(seedSpeed) {
		t.Fatalf("machspeed = %v want %v", ms[2].Double, seedSpeed)
	}
	if !ms[3].IsLong || ms[3].Long != int64(seedState) {
		t.Fatalf("state = long=%v val=%d want long %d", ms[3].IsLong, ms[3].Long, seedState)
	}

	// The encode path must accept those samples and emit non-empty payloads.
	birth, err := poller.EncodeBirth(client.Read)
	if err != nil {
		t.Fatalf("EncodeBirth: %v", err)
	}
	if len(birth) == 0 {
		t.Fatal("EncodeBirth produced empty payload")
	}
	data, err := poller.EncodeData(client.Read)
	if err != nil {
		t.Fatalf("EncodeData: %v", err)
	}
	if len(data) == 0 {
		t.Fatal("EncodeData produced empty payload")
	}
}

// TestUnknownDBErrors: reading a DB the server doesn't have must surface an error
// through the real client (item return code != 0xFF) — and must NOT panic the
// server. The soft-PLC stays up for the next connection.
func TestUnknownDBErrors(t *testing.T) {
	srv := startServer(t)
	defer srv.Close()

	client := s7.NewClient(srv.Addr(), 0, 2, 2*time.Second)
	defer client.Close()

	if _, err := client.Read(999, 0, 4); err == nil {
		t.Fatal("read of unknown DB999 should error, got nil")
	}
}

// TestOutOfRangeErrors: a read past the end of a known DB must error, not read
// garbage or panic.
func TestOutOfRangeErrors(t *testing.T) {
	srv := startServer(t)
	defer srv.Close()

	client := s7.NewClient(srv.Addr(), 0, 2, 2*time.Second)
	defer client.Close()

	// DB100 is 16 bytes; asking for 100 bytes overruns it.
	if _, err := client.Read(100, 0, 100); err == nil {
		t.Fatal("out-of-range read should error, got nil")
	}
}

// TestReconnectAfterError proves the client's redial discipline works against
// the soft-PLC: a failing read drops the gos7 session, and the very next Read
// transparently reconnects (new CR/CC + setup) and succeeds. This is the
// behaviour cmd/s7-reader relies on to recover from a PLC blip.
func TestReconnectAfterError(t *testing.T) {
	srv := startServer(t)
	defer srv.Close()

	client := s7.NewClient(srv.Addr(), 0, 2, 2*time.Second)
	defer client.Close()

	// First read fails (unknown DB) → Client.Read closes the handler.
	if _, err := client.Read(999, 0, 4); err == nil {
		t.Fatal("expected error reading unknown DB")
	}
	// Next read must redial and succeed against a fresh connection.
	got, err := client.Read(100, 0, 16)
	if err != nil {
		t.Fatalf("read after reconnect: %v", err)
	}
	if v, _ := s7.GetDInt(got, 0); v != seedProcessed {
		t.Fatalf("post-reconnect ProdProcessedCount = %d, want %d", v, seedProcessed)
	}
}

// TestSetDBHotSwap verifies SetDB replaces block contents mid-flight and the
// real client observes the new bytes on the next read.
func TestSetDBHotSwap(t *testing.T) {
	srv := startServer(t)
	defer srv.Close()

	client := s7.NewClient(srv.Addr(), 0, 2, 2*time.Second)
	defer client.Close()

	newDB := make([]byte, 16)
	binary.BigEndian.PutUint32(newDB[0:], uint32(int32(777777)))
	srv.SetDB(100, newDB)

	got, err := client.Read(100, 0, 4)
	if err != nil {
		t.Fatalf("read after SetDB: %v", err)
	}
	if v, _ := s7.GetDInt(got, 0); v != 777777 {
		t.Fatalf("hot-swapped value = %d, want 777777", v)
	}
}
