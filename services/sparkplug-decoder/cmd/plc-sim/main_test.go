package main

import (
	"io"
	"log/slog"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/command"
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
	// Target a real staging MEMBER by IDENTITY, not slice position — #16
	// inserted bare line-topic entries ahead of the members, so hard indices
	// shifted. L5/BREYER also exercises the longest-prefix router: its DCMD
	// must resolve to the member, NOT the bare "CPACK/SC/LINHAS/L5" line entry
	// whose prefix it shares.
	ti := lineIndex("L5", "BREYER")
	if ti < 0 {
		t.Fatal("test fixture drift: no L5/BREYER member in lines")
	}
	target := lines[ti]
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
		if !states[ti].hasSpeedOverride || states[ti].speedOverride != 87.5 {
			t.Fatalf("line[%d] MachSpeed override = (%v, %v), want (true, 87.5)",
				ti, states[ti].hasSpeedOverride, states[ti].speedOverride)
		}
		// The effect is observable: the sim now reports the override, not the seed.
		if got := states[ti].effSpeed(target.MachSpeed); got != 87.5 {
			t.Fatalf("effSpeed = %v, want the applied override 87.5 (not seed %v)", got, target.MachSpeed)
		}
		// No collateral: exactly one entry mutated (longest-prefix routed the
		// member DCMD to the member, not also to the bare L5 line entry).
		for i, s := range states {
			if i != ti && s.hasSpeedOverride {
				t.Fatalf("non-targeted line[%d] (%s/%s) was mutated — DCMD router double-applied",
					i, lines[i].Line, lines[i].Unit)
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
		if states[ti].poParam != "PO-88231" {
			t.Fatalf("line[%d] poParam = %q, want PO-88231", ti, states[ti].poParam)
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

// lineIndex returns the index of the first entry matching (line, unit), or -1.
// Tests key on identity, not slice position, so #16's inserted line entries
// don't silently retarget an assertion.
func lineIndex(lineName, unit string) int {
	for i, l := range lines {
		if l.Line == lineName && l.Unit == unit {
			return i
		}
	}
	return -1
}

// TestLineParameter30700_SelfReferentialNoMemberCollision is the STATIC
// single-writer guard for #16. Each bare line entry (Unit=="") publishes
// Parameter30700 = its own Idx (the "line-machines CSV" Phase-9 reads). The
// invariant that keeps line-derivation OFF — so the line's counter has exactly
// one writer (its own-stream) and never the #456 second Phase-9 writer — is:
// no member of a line may carry the line's own Idx. If a member's Idx equalled
// the line's self-referential Idx, Phase-9's `machineIdx == firstMachine ||
// lastMachine` test (line_aggregation.go) would fire and re-derive the line
// from that member. This test fails loudly if a future edit reintroduces a
// colliding index.
func TestLineParameter30700_SelfReferentialNoMemberCollision(t *testing.T) {
	for _, ln := range lines {
		if ln.Unit != "" {
			continue // members don't publish Parameter30700 (see publishBirth)
		}
		for _, member := range lines {
			if member.Unit == "" || member.Line != ln.Line {
				continue
			}
			if member.Idx == ln.Idx {
				t.Fatalf("line %s self-ref Parameter30700 idx %d collides with member %s/%s idx %d — "+
					"Phase-9 line-derivation would fire and double-write the line counter (#456)",
					ln.Line, ln.Idx, member.Line, member.Unit, member.Idx)
			}
		}
	}
}

// TestDCMD_LongestPrefix_MemberNotLine directly guards the router regression
// #16 introduced: a member-targeted DCMD must land on the member alone, even
// though the bare line entry's prefix ("CPACK/SC/LINHAS/L5") is a prefix of the
// member's ("CPACK/SC/LINHAS/L5/BREYER"). Exactly one write, on the member.
func TestDCMD_LongestPrefix_MemberNotLine(t *testing.T) {
	member := lineIndex("L5", "BREYER")
	lineEntry := lineIndex("L5", "")
	if member < 0 || lineEntry < 0 {
		t.Skip("fixture has no L5 line+member pair to disambiguate")
	}

	dcmd, err := command.BuildDCMD(command.Command{
		Verb:        command.VerbParamWrite,
		PackmlTopic: lines[member].topicPrefix(), // CPACK/SC/LINHAS/L5/BREYER
		Params:      map[string]any{"parameter": "Status/MachSpeed", "value": 42.0},
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
		t.Fatalf("member DCMD applied %d writes, want exactly 1 (longest-prefix must not also hit the bare line entry)", applied)
	}
	if !states[member].hasSpeedOverride {
		t.Fatal("member L5/BREYER did not receive the DCMD")
	}
	if states[lineEntry].hasSpeedOverride {
		t.Fatal("bare L5 line entry was wrongly mutated by a member-targeted DCMD (double-apply)")
	}
}

// TestDCMD_LineTopic_RoutesToLineEntry is the complement: a LINE-topic DCMD
// (a PO set on the line) must route to the bare line entry, never a member.
func TestDCMD_LineTopic_RoutesToLineEntry(t *testing.T) {
	lineEntry := lineIndex("L5", "")
	if lineEntry < 0 {
		t.Skip("fixture has no bare L5 line entry")
	}
	dcmd, err := command.BuildDCMD(command.Command{
		Verb:        command.VerbPOSetup,
		PackmlTopic: lines[lineEntry].topicPrefix(), // CPACK/SC/LINHAS/L5
		Params:      map[string]any{"poNumber": "PO-LINE-1"},
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
		t.Fatalf("line DCMD applied %d writes, want exactly 1", applied)
	}
	if states[lineEntry].poParam != "PO-LINE-1" {
		t.Fatalf("line entry poParam = %q, want PO-LINE-1", states[lineEntry].poParam)
	}
}
