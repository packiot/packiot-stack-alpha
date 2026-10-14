// Restart regression for the 2026-10-08 staging deploy loss: a decoder restart
// wiped the in-memory Calc baselines, the first post-restart reading was
// first-observation-seeded (emitted nothing) and one reading's delta per counter
// stream vanished. This drives the REAL MQTT handler + a file-backed outbox
// across a simulated restart and asserts Σ emitted increments == counter
// movement. The control run (durable state off) reproduces the loss.

package main

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/analyticspub"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/mqtt"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/outbox"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/transforms/calc_production_counters"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"google.golang.org/protobuf/proto"
)

const restartCounter = "BISPHARMASTAGING/SITE/AREA/L1/M1/Admin/ProdProcessedCount/1/Unit"

func spPayload(t *testing.T, seq uint64, ts uint64, birth bool, counter uint64) []byte {
	t.Helper()
	m := &sparkplug.Metric{
		Alias:     proto.Uint64(1),
		Timestamp: proto.Uint64(ts),
		Datatype:  proto.Uint32(uint32(sparkplug.DataType_Int64)),
		Value:     &sparkplug.Metric_LongValue{LongValue: counter},
	}
	if birth {
		m.Name = proto.String(restartCounter)
	}
	b, err := sparkplug.Encode(&sparkplug.Payload{Timestamp: proto.Uint64(ts), Seq: proto.Uint64(seq), Metrics: []*sparkplug.Metric{m}})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// decoderProcess is one decoder lifetime: fresh alias table + fresh Calc state
// (+ checkpoint restore when durable), sharing the on-disk outbox.
func decoderProcess(t *testing.T, path string, durable bool) (mqtt.Handler, *outbox.Store) {
	t.Helper()
	store, err := outbox.Open(outbox.Config{Path: path, Capacity: 1000})
	if err != nil {
		t.Fatal(err)
	}
	hooks := newTestCalcHooks(t)
	hooks.resetHeal = true
	hooks.noSpeedGuardFallback = true
	if durable {
		hooks.tracked = calc_production_counters.NewTrackedState(calc_production_counters.NewMemState())
		hooks.state = hooks.tracked
		restoreCalcState(context.Background(), store, hooks.tracked, testLogger())
	}
	h := sparkplugHandler(sparkplug.NewStateStore(), nil, store, nil, hooks,
		false, true, false, true, true, nil, nil, testLogger())
	return h, store
}

func feed(t *testing.T, h mqtt.Handler, seq *uint64, ts *uint64, birth bool, v uint64) {
	t.Helper()
	typ := "NDATA"
	if birth {
		typ = "NBIRTH"
	}
	topic := mqtt.Topic{Namespace: "spBv1.0", GroupID: "BISPHARMASTAGING", MessageType: typ, EdgeNodeID: "box"}
	if err := h(context.Background(), topic, spPayload(t, *seq, *ts, birth, v)); err != nil {
		t.Fatal(err)
	}
	*seq++
	*ts += 12_000
}

// sumIncrements reads every envelope in the outbox and sums the emitted
// (delta) values of the counter.
func sumIncrements(t *testing.T, store *outbox.Store) int64 {
	t.Helper()
	msgs, err := store.Peek(context.Background(), 1000)
	if err != nil {
		t.Fatal(err)
	}
	var sum int64
	for _, m := range msgs {
		var ox outboxEnvelope
		if err := json.Unmarshal(m.Payload, &ox); err != nil {
			t.Fatal(err)
		}
		var env analyticspub.Envelope
		if err := json.Unmarshal(ox.Body, &env); err != nil {
			t.Fatal(err)
		}
		for _, mm := range env.Metrics {
			if mm.Name == restartCounter {
				sum += int64(mm.Value.(float64))
			}
		}
	}
	return sum
}

func runRestartScenario(t *testing.T, durable bool) int64 {
	path := filepath.Join(t.TempDir(), "outbox.db")
	seq, ts := uint64(0), uint64(1_791_000_000_000)

	h, store := decoderProcess(t, path, durable)
	feed(t, h, &seq, &ts, true, 1000) // NBIRTH (retained)
	for _, v := range []uint64{1000, 1013, 1026} {
		feed(t, h, &seq, &ts, false, v)
	}
	_ = store.Close() // ── deploy: container recreated ──

	h, store = decoderProcess(t, path, durable)
	defer store.Close()
	seq = 0
	feed(t, h, &seq, &ts, true, 1026) // agent re-births on reconnect
	for _, v := range []uint64{1042, 1055} {
		feed(t, h, &seq, &ts, false, v)
	}
	return sumIncrements(t, store)
}

func TestDecoderRestartLosesNoIncrement(t *testing.T) {
	const movement = 1055 - 1000
	if got := runRestartScenario(t, false); got == movement {
		t.Fatalf("control (CALC_STATE_DURABLE=false) unexpectedly kept every increment (Σ=%d) — the scenario no longer reproduces the restart loss", got)
	} else {
		t.Logf("control (in-memory state): Σ increments=%d vs counter movement=%d — %d lost at the restart", got, movement, movement-got)
	}
	if got := runRestartScenario(t, true); got != movement {
		t.Fatalf("durable Calc state: Σ increments=%d, want counter movement %d", got, movement)
	}
}

func TestRestoreCalcStateSetsGauge(t *testing.T) {
	path := filepath.Join(t.TempDir(), "outbox.db")
	store, err := outbox.Open(outbox.Config{Path: path})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.EnqueueBatch(context.Background(), nil, []outbox.StateRow{{Kind: "int", Key: "a", Int: 1}, {Kind: "time_ms", Key: "b", Int: 2}}); err != nil {
		t.Fatal(err)
	}
	restoreCalcState(context.Background(), store, calc_production_counters.NewTrackedState(calc_production_counters.NewMemState()), testLogger())
	if got := testutil.ToFloat64(calcStateRestored); got != 2 {
		t.Fatalf("calc_state_restored_entries = %v, want 2", got)
	}
}
