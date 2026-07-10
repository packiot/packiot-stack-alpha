package main

import (
	"io"
	"log/slog"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/command"
)

// discardLogger silences the apply path's per-write logs; these tests assert on
// state, not logs.
func discardLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// TestDCMD_ExecutorToSim_Contract closes the ADR-0019 C1 write-back gap (#46b):
// it proves the command loop's two ends AGREE on the wire. The executor
// (command.BuildDCMD) encodes a real SparkPlug DCMD; the sim's real receiving
// path (applyDCMDToStates, decoding with the same sparkplug codec) applies it.
// Both ends existed and were unit-tested IN ISOLATION — this is the missing
// end-to-end assertion that a DCMD the executor emits actually lands the
// intended write on the machine. No broker: BuildDCMD.Body is the exact bytes
// PublishDCMD would put on MQTT, fed straight into the sim's decoder.
func TestDCMD_ExecutorToSim_Contract(t *testing.T) {
	// Target a real staging line so topic prefixes match exactly (the sim
	// matches a DCMD to a line by topic prefix).
	target := lines[1] // CPACK/SC/LINHAS/L5/BREYER
	prefix := target.topicPrefix()

	t.Run("param_write MachSpeed lands the override on the targeted line", func(t *testing.T) {
		dcmd, err := command.BuildDCMD(command.Command{
			Verb:        command.VerbParamWrite,
			PackmlTopic: prefix,
			Params:      map[string]any{"parameter": "Status/MachSpeed", "value": 87.5},
		}, "plc-sim")
		if err != nil {
			t.Fatalf("BuildDCMD: %v", err)
		}

		states := make([]simState, len(lines))
		applied, err := applyDCMDToStates(dcmd.Body, lines, states, discardLogger())
		if err != nil {
			t.Fatalf("applyDCMDToStates: %v", err)
		}
		if applied != 1 {
			t.Fatalf("want exactly 1 write applied, got %d", applied)
		}
		if !states[1].hasSpeedOverride || states[1].speedOverride != 87.5 {
			t.Fatalf("line[1] MachSpeed override = (%v, %v), want (true, 87.5)",
				states[1].hasSpeedOverride, states[1].speedOverride)
		}
		// The effect is observable: the sim now reports the override, not the seed.
		if got := states[1].effSpeed(target.MachSpeed); got != 87.5 {
			t.Fatalf("effSpeed = %v, want the applied override 87.5 (not seed %v)", got, target.MachSpeed)
		}
		// No collateral: no other line was mutated.
		for i, s := range states {
			if i != 1 && s.hasSpeedOverride {
				t.Fatalf("non-targeted line[%d] was mutated", i)
			}
		}
	})

	t.Run("po_setup writes Parameter30700 on the targeted line", func(t *testing.T) {
		dcmd, err := command.BuildDCMD(command.Command{
			Verb:        command.VerbPOSetup,
			PackmlTopic: prefix,
			Params:      map[string]any{"poNumber": "PO-88231"},
		}, "plc-sim")
		if err != nil {
			t.Fatalf("BuildDCMD: %v", err)
		}

		states := make([]simState, len(lines))
		applied, err := applyDCMDToStates(dcmd.Body, lines, states, discardLogger())
		if err != nil {
			t.Fatalf("applyDCMDToStates: %v", err)
		}
		if applied != 1 {
			t.Fatalf("want exactly 1 write applied, got %d", applied)
		}
		if states[1].poParam != "PO-88231" {
			t.Fatalf("line[1] poParam = %q, want PO-88231", states[1].poParam)
		}
	})

	t.Run("a DCMD for an unknown line applies nothing", func(t *testing.T) {
		dcmd, err := command.BuildDCMD(command.Command{
			Verb:        command.VerbParamWrite,
			PackmlTopic: "CPACK/SC/LINHAS/L99/NOPE", // no such sim line
			Params:      map[string]any{"parameter": "Status/MachSpeed", "value": 10},
		}, "plc-sim")
		if err != nil {
			t.Fatalf("BuildDCMD: %v", err)
		}
		states := make([]simState, len(lines))
		applied, err := applyDCMDToStates(dcmd.Body, lines, states, discardLogger())
		if err != nil {
			t.Fatalf("applyDCMDToStates: %v", err)
		}
		if applied != 0 {
			t.Fatalf("want 0 writes for an unknown line, got %d", applied)
		}
	})

	t.Run("a malformed body errors, does not panic or apply", func(t *testing.T) {
		states := make([]simState, len(lines))
		if _, err := applyDCMDToStates([]byte("not-a-sparkplug-payload"), lines, states, discardLogger()); err == nil {
			t.Fatal("want a decode error on a garbage body")
		}
	})
}
