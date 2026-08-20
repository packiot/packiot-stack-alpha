package capture

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
)

// stateGlyph gives each verdict a stable ASCII marker for the text report (no
// unicode/emoji — keeps the report grep-able and terminal-safe).
func stateGlyph(s State) string {
	switch s {
	case StateConfirmed:
		return "[OK ]"
	case StateMismatch:
		return "[!! ]"
	case StateMissing:
		return "[ ? ]"
	case StateUnmapped:
		return "[ORPH]"
	default:
		return "[   ]"
	}
}

// Text renders the human-readable reconciliation report.
func (r *Report) Text() string {
	var b strings.Builder
	fmt.Fprintf(&b, "ADR-0045 P2 — live-tee count-index capture\n")
	fmt.Fprintf(&b, "tenant=%s  scope=%s\n\n", r.Tenant, r.Scope)

	fmt.Fprintf(&b, "%-6s %-22s %-9s %-9s %-9s  %s\n",
		"state", "member", "expected", "observed", "via", "note")
	fmt.Fprintf(&b, "%s\n", strings.Repeat("-", 96))
	for _, m := range r.Members {
		observed := "-"
		if m.Observed != nil {
			observed = fmt.Sprintf("%d", *m.Observed)
		}
		via := string(m.Channel)
		if via == "" {
			via = "-"
		}
		fmt.Fprintf(&b, "%-6s %-22s %-9s %-9s %-9s  %s\n",
			stateGlyph(m.State), m.Key,
			expectedCell(m), observed, via, m.Note)
	}
	if len(r.Orphans) > 0 {
		fmt.Fprintf(&b, "\norphan count topics (no member in descriptor):\n")
		for _, o := range r.Orphans {
			fmt.Fprintf(&b, "  %s  index=%d via=%s  %s\n", stateGlyph(StateUnmapped), o.Index, o.Channel, o.Suffix)
		}
	}

	fmt.Fprintf(&b, "\nsummary: ")
	for _, s := range []State{StateConfirmed, StateMismatch, StateMissing, StateUnmapped} {
		fmt.Fprintf(&b, "%s=%d  ", s, r.Counts[s])
	}
	fmt.Fprintf(&b, "\n\n")

	if r.CutoverReady {
		fmt.Fprintf(&b, "CUTOVER: READY — every opted-in member CONFIRMED.\n")
	} else {
		fmt.Fprintf(&b, "CUTOVER: NOT READY — %d blocking (no cutover on inferred):\n", len(r.Blocking))
		for _, bl := range r.Blocking {
			fmt.Fprintf(&b, "  - %s\n", bl)
		}
	}
	return b.String()
}

// expectedCell renders the expected index + its descriptor confidence.
func expectedCell(m MemberResult) string {
	c := "?"
	switch m.ExpectedConfidence {
	case ConfidenceConfirmed:
		c = "c"
	case ConfidenceInferred:
		c = "i"
	}
	return fmt.Sprintf("%d(%s)", m.Expected, c)
}

// JSON renders the machine-readable report.
func (r *Report) JSON() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

// Fragment renders the descriptor FRAGMENT: the equipment rows whose count index
// this capture changed (a MISMATCH corrected to the real index, or an inferred
// flag flipped to confirmed on live evidence), in the exact flow-style YAML of
// the P1 descriptor so it pastes straight back. Members that did not change are
// omitted; MISSING members are omitted (they stay inferred, deliberately). An
// empty return means the descriptor already matches reality for this scope.
func (r *Report) Fragment() string {
	var changed []MemberResult
	for _, m := range r.Members {
		if m.Captured != nil {
			changed = append(changed, m)
		}
	}
	if len(changed) == 0 {
		return ""
	}
	sort.Slice(changed, func(i, j int) bool { return changed[i].Topic < changed[j].Topic })

	var b strings.Builder
	fmt.Fprintf(&b, "# ADR-0045 P2 capture — descriptor fragment (paste into equipment:)\n")
	fmt.Fprintf(&b, "# tenant=%s scope=%s — %d row(s) updated from live-tee observation.\n",
		r.Tenant, r.Scope, len(changed))
	fmt.Fprintf(&b, "# each row's count_index is now confidence: confirmed (observed on the wire).\n")
	for _, m := range changed {
		reason := "confirmed"
		if m.State == StateMismatch {
			reason = fmt.Sprintf("was %d (%s), tee sends %d", m.Expected, m.ExpectedConfidence, *m.Observed)
		} else {
			reason = fmt.Sprintf("was inferred, observed %d", m.Expected)
		}
		fmt.Fprintf(&b, "%s  # %s\n", formatEquip(*m.Captured), reason)
	}
	return b.String()
}

// formatEquip emits one equipment row in the P1 descriptor's flow style, e.g.
// "  - {topic: CPACK/SC/LINHAS/L8/DXL, id_equipment: 73, tp_equipment: 1,
// id_unit: 73, count_index: {value: 511, confidence: confirmed}}".
func formatEquip(e clientdescriptor.Equipment) string {
	var b strings.Builder
	fmt.Fprintf(&b, "  - {topic: %s, id_equipment: %d, tp_equipment: %d",
		e.Topic, e.IDEquipment, e.TPEquipment)
	if e.IDUnit != nil {
		fmt.Fprintf(&b, ", id_unit: %d", *e.IDUnit)
	}
	if e.CountIndex != nil {
		fmt.Fprintf(&b, ", count_index: {value: %d, confidence: %s}",
			e.CountIndex.Value, e.CountIndex.Confidence)
	}
	b.WriteString("}")
	return b.String()
}
