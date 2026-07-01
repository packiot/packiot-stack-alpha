// Topic parsing + trigger-kind routing. Extracted so the port PR's
// decision-tree body can call the same helper functions this scaffold
// establishes.

package calc_production_counters

import (
	"errors"
	"strings"
)

// ErrMalformedTopic is returned by ParseTopic when the input doesn't
// match the Sparkplug + counter-suffix shape.
var ErrMalformedTopic = errors.New("calc_production_counters: malformed topic")

// ParseTopic splits the Sparkplug counter topic into (unitTopic, kind).
// Example:
//   "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***IN"
//     → unitTopic="CPACK/SC/LINHAS/L5/BREYER", kind=CounterKindConsumed
func ParseTopic(topic string) (unitTopic string, kind CounterKind, err error) {
	if topic == "" {
		return "", CounterKindUnknown, ErrMalformedTopic
	}
	// Split off the ***<TRIG> suffix
	sep := "***"
	idx := strings.LastIndex(topic, sep)
	if idx < 0 {
		return "", CounterKindUnknown, ErrMalformedTopic
	}
	suffix := topic[idx+len(sep):]
	body := topic[:idx]

	kind = kindFromSuffix(suffix)
	if kind == CounterKindUnknown {
		return "", CounterKindUnknown, ErrMalformedTopic
	}

	// The unit topic is the first 5 segments of the body
	parts := strings.Split(body, "/")
	if len(parts) < 5 {
		return "", CounterKindUnknown, ErrMalformedTopic
	}
	unitTopic = strings.Join(parts[:5], "/")
	return unitTopic, kind, nil
}

// kindFromSuffix maps the trigger suffix (after `***`) to a CounterKind.
// Case-insensitive because prod payloads have both.
func kindFromSuffix(s string) CounterKind {
	switch strings.ToUpper(s) {
	case "IN":
		return CounterKindConsumed
	case "OUT":
		return CounterKindProcessed
	case "SCRAPED", "SCRAP", "SCRAPPED":
		return CounterKindScrapped
	case "TRIG":
		return CounterKindTrigger
	default:
		return CounterKindUnknown
	}
}
