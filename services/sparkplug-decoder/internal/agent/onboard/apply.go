package onboard

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/capture"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
)

// countIndexRE matches a flow-style `count_index: {value: N, confidence: X}`
// block on an equipment line so it can be replaced in place. The equipment rows
// are one-line YAML mappings (the P1 descriptor style), so a per-line regex swap
// preserves every comment, ordering, and unrelated field — a targeted edit, not
// a re-marshal that would reflow the whole file and blow up the review diff.
var countIndexRE = regexp.MustCompile(`count_index:\s*\{[^}]*\}`)

// applyCaptures rewrites the descriptor file IN PLACE, updating each changed
// member's count_index to the value+confidence the P2 reconciler captured on the
// live tee. This is what makes the loop "guided end-to-end without hand-editing":
// instead of printing a fragment the engineer must paste back (P2's manual
// affordance), the orchestrator writes the confirmed indices straight into the
// SSoT, so the next GENERATE/VALIDATE sees them.
//
// It reuses capture.MemberResult.Captured (the corrected Equipment the P2 engine
// already computed) — no index logic is re-derived here; this function only does
// the line surgery. Returns the topics it changed.
//
// Matching is by exact topic. Topics are unique + prefix-validated in the
// descriptor, and a member row always has fields after `topic:` (so `topic: T,`
// with the trailing comma cannot collide with a shorter line row `topic: T,`).
func applyCaptures(descriptorPath string, rep *capture.Report) ([]string, error) {
	changed := map[string]*clientdescriptor.Equipment{}
	for _, m := range rep.Members {
		if m.Captured != nil {
			changed[m.Captured.Topic] = m.Captured
		}
	}
	if len(changed) == 0 {
		return nil, nil
	}

	raw, err := os.ReadFile(descriptorPath)
	if err != nil {
		return nil, fmt.Errorf("onboard: read descriptor %s: %w", descriptorPath, err)
	}
	lines := strings.Split(string(raw), "\n")

	applied := map[string]bool{}
	for i, ln := range lines {
		for topic, eq := range changed {
			if applied[topic] {
				continue
			}
			if !lineIsTopic(ln, topic) {
				continue
			}
			repl := fmt.Sprintf("count_index: {value: %d, confidence: %s}",
				eq.CountIndex.Value, eq.CountIndex.Confidence)
			if countIndexRE.MatchString(ln) {
				lines[i] = countIndexRE.ReplaceAllString(ln, repl)
			} else {
				// No existing count_index on the row — insert one before the
				// closing brace. (Members always carry one in practice; this is
				// defensive so a hand-authored row missing it still gets set.)
				lines[i] = strings.TrimRight(ln, "} \t") + ", " + repl + "}"
			}
			applied[topic] = true
		}
	}

	var missed []string
	for topic := range changed {
		if !applied[topic] {
			missed = append(missed, topic)
		}
	}
	if len(missed) > 0 {
		return nil, fmt.Errorf("onboard: could not locate %d captured topic(s) in %s (line format changed?): %s",
			len(missed), descriptorPath, strings.Join(sortedTopics(missed), ", "))
	}

	if err := os.WriteFile(descriptorPath, []byte(strings.Join(lines, "\n")), 0o644); err != nil {
		return nil, fmt.Errorf("onboard: write descriptor %s: %w", descriptorPath, err)
	}
	out := make([]string, 0, len(applied))
	for topic := range applied {
		out = append(out, topic)
	}
	return sortedTopics(out), nil
}

// lineIsTopic reports whether an equipment line declares exactly `topic`. It
// looks for `topic: <topic>` followed by a field delimiter (comma) or the
// closing brace, so the line row `topic: X` never matches a member `topic: X/Y`.
func lineIsTopic(line, topic string) bool {
	needle := "topic: " + topic
	idx := strings.Index(line, needle)
	if idx < 0 {
		return false
	}
	rest := line[idx+len(needle):]
	rest = strings.TrimLeft(rest, " \t")
	return strings.HasPrefix(rest, ",") || strings.HasPrefix(rest, "}")
}
