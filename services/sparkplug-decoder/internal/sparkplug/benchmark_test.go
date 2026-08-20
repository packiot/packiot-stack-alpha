// Sparkplug B decode/encode benchmarks.
//
// ADR-0010 claims the Go decoder is 10-100× faster than Node-RED's JS path.
// These benchmarks measure the Go side directly. The Node-RED side can be
// measured separately by capturing CPU profile snapshots from the existing
// SparkPlug subflow (a Phase 1 follow-up).
//
// Run with:
//   go test -bench=. -benchmem ./internal/sparkplug/
//
// Or for a specific shape:
//   go test -bench=BenchmarkDecode_NDATA_100 -benchmem ./internal/sparkplug/
//
// b.SetBytes is called so `-bench` reports throughput in MB/s, which is more
// useful than ns/op for thinking about MQTT-broker-rate sizing.

package sparkplug

import (
	"testing"
)

// benchDecode is the shared body for all decode benchmarks. It pre-encodes
// the payload OUTSIDE the timer so we measure only the Decode hot path.
func benchDecode(b *testing.B, p *Payload) {
	body, err := Encode(p)
	if err != nil {
		b.Fatalf("setup encode: %v", err)
	}
	b.SetBytes(int64(len(body)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := Decode(body)
		if err != nil {
			b.Fatalf("decode: %v", err)
		}
	}
}

// benchEncode measures the symmetric encode path.
func benchEncode(b *testing.B, p *Payload) {
	body, err := Encode(p)
	if err != nil {
		b.Fatalf("setup encode: %v", err)
	}
	b.SetBytes(int64(len(body)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := Encode(p)
		if err != nil {
			b.Fatalf("encode: %v", err)
		}
	}
}

// ── NBIRTH (full metric definitions with names + aliases) ────────────────────
// Larger wire size; represents the per-connect cost.

func BenchmarkDecode_NBIRTH_1(b *testing.B)    { benchDecode(b, newNBIRTH(1, 1700000000000)) }
func BenchmarkDecode_NBIRTH_10(b *testing.B)   { benchDecode(b, newNBIRTH(10, 1700000000000)) }
func BenchmarkDecode_NBIRTH_100(b *testing.B)  { benchDecode(b, newNBIRTH(100, 1700000000000)) }
func BenchmarkDecode_NBIRTH_1000(b *testing.B) { benchDecode(b, newNBIRTH(1000, 1700000000000)) }

// ── NDATA (alias-only, the 95% case) ─────────────────────────────────────────
// Smaller wire size; represents real-time PLC data rate.

func BenchmarkDecode_NDATA_1(b *testing.B)    { benchDecode(b, newNDATA(1, 1700000000000, 1)) }
func BenchmarkDecode_NDATA_10(b *testing.B)   { benchDecode(b, newNDATA(10, 1700000000000, 1)) }
func BenchmarkDecode_NDATA_100(b *testing.B)  { benchDecode(b, newNDATA(100, 1700000000000, 1)) }
func BenchmarkDecode_NDATA_1000(b *testing.B) { benchDecode(b, newNDATA(1000, 1700000000000, 1)) }

// ── Encode (for completeness; production path is consumer-only) ──────────────

func BenchmarkEncode_NBIRTH_100(b *testing.B) { benchEncode(b, newNBIRTH(100, 1700000000000)) }
func BenchmarkEncode_NDATA_100(b *testing.B)  { benchEncode(b, newNDATA(100, 1700000000000, 1)) }

// ── Parallel scaling (validates we can shard decoders if needed) ─────────────
//
// Sparkplug B's per-publisher alias-table state means each subscriber goroutine
// owns its own table — they don't share. So decoding is embarrassingly
// parallel ACROSS publishers. b.RunParallel models that: GOMAXPROCS goroutines
// each running the decode hot path independently. The ns/op should stay flat
// (or improve) as GOMAXPROCS rises.

func BenchmarkDecode_NDATA_100_Parallel(b *testing.B) {
	p := newNDATA(100, 1700000000000, 1)
	body, err := Encode(p)
	if err != nil {
		b.Fatalf("setup: %v", err)
	}
	b.SetBytes(int64(len(body)))
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			if _, err := Decode(body); err != nil {
				b.Fatalf("decode: %v", err)
			}
		}
	})
}

func BenchmarkDecode_NBIRTH_100_Parallel(b *testing.B) {
	p := newNBIRTH(100, 1700000000000)
	body, err := Encode(p)
	if err != nil {
		b.Fatalf("setup: %v", err)
	}
	b.SetBytes(int64(len(body)))
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			if _, err := Decode(body); err != nil {
				b.Fatalf("decode: %v", err)
			}
		}
	})
}
