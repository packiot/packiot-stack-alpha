// Topic parsing + trigger-suffix flags.

package calc_production_counters

import (
	"errors"
	"strings"
)

// ErrMalformedTopic is returned by ParseTopic when the input doesn't
// match the Sparkplug + counter-topic shape.
var ErrMalformedTopic = errors.New("calc_production_counters: malformed topic")

// TriggerFlags captures the compound trigger-suffix encoding present in
// the topic. Multiple flags may fire on the same topic (JS uses
// includes() checks that are not mutually exclusive).
type TriggerFlags struct {
	// TrigBase — has "***TRIG" prefix (any TRIG variant).
	TrigBase bool
	// TrigCS — "***TRIG_CS" — force Defective = Consumed - Processed.
	TrigCS bool
	// TrigCI — "***TRIG_CI" — force Consumed = Processed + Defective.
	TrigCI bool
	// TrigCEqualsI — "***TRIG_C=I" — set Consumed := Processed.
	TrigCEqualsI bool
	// TrigCEqualsO — "***TRIG_C=O" — set Processed := Consumed.
	TrigCEqualsO bool
	// TrigCO — "***TRIG_CO" — full reconstruction from ___IN_INCR + ___IN_SCRAP.
	TrigCO bool
	// StateSpeedThis — "***STATESPEED_THIS" — threshold logic moves to Processed.
	StateSpeedThis bool
}

// parseTopicFull parses the full Sparkplug counter topic into (unitTopic,
// counterKind, flags). See docs/phase-3-calc-production-counters-state-
// machine.md §2 for the topic anatomy.
//
// Example:
//
//	"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG_CS"
//	  → unit="CPACK/SC/LINHAS/L5/BREYER", kind=Consumed, TrigBase+TrigCS
func parseTopicFull(topic string) (unitTopic string, kind CounterKind, flags TriggerFlags, err error) {
	if topic == "" {
		return "", CounterKindUnknown, TriggerFlags{}, ErrMalformedTopic
	}
	sepIdx := strings.Index(topic, "***")
	if sepIdx < 0 {
		return "", CounterKindUnknown, TriggerFlags{}, ErrMalformedTopic
	}
	body := topic[:sepIdx]
	suffix := topic[sepIdx+3:]

	// Detect counter kind from the body substring. Multiple checks so a
	// bad topic (no counter name) falls to Unknown → caller drops.
	switch {
	case strings.Contains(body, "ProdProcessedCount"):
		kind = CounterKindProcessed
	case strings.Contains(body, "ProdConsumedCount"):
		kind = CounterKindConsumed
	case strings.Contains(body, "ProdDefectiveCount"):
		kind = CounterKindDefective
	default:
		return "", CounterKindUnknown, TriggerFlags{}, ErrMalformedTopic
	}

	// Extract the 5-segment unit topic (Enterprise/Site/Area/Line/Unit).
	parts := strings.Split(body, "/")
	if len(parts) < 5 {
		return "", CounterKindUnknown, TriggerFlags{}, ErrMalformedTopic
	}
	unitTopic = strings.Join(parts[:5], "/")

	// Parse trigger-suffix flags. JS uses includes() (substring) checks,
	// so ORDER MATTERS: TRIG_CO contains TRIG_C, TRIG_C=O contains C=O,
	// etc. Match longest first.
	sfx := strings.ToUpper(suffix)
	if strings.Contains(sfx, "STATESPEED_THIS") {
		flags.StateSpeedThis = true
	}
	if strings.Contains(sfx, "TRIG_C=I") {
		flags.TrigCEqualsI = true
	}
	if strings.Contains(sfx, "TRIG_C=O") {
		flags.TrigCEqualsO = true
	}
	if strings.Contains(sfx, "TRIG_CS") {
		flags.TrigCS = true
	}
	if strings.Contains(sfx, "TRIG_CI") {
		flags.TrigCI = true
	}
	if strings.Contains(sfx, "TRIG_CO") && !flags.TrigCEqualsO {
		// JS: `msg.topic.includes("***TRIG_CO")` fires on TRIG_CO but NOT
		// on TRIG_C=O (contains "TRIG_C=" not "TRIG_CO"). We match by
		// requiring the "TRIG_CO" substring absent the "=" that would
		// make it TRIG_C=O.
		flags.TrigCO = true
	}
	if strings.HasPrefix(sfx, "TRIG") {
		flags.TrigBase = true
	}
	return unitTopic, kind, flags, nil
}

// ParseTopic is the exported convenience wrapper — returns (unit, kind, err).
// Existing callers (scaffold tests, comparator) use this.
func ParseTopic(topic string) (unitTopic string, kind CounterKind, err error) {
	u, k, _, e := parseTopicFull(topic)
	return u, k, e
}
