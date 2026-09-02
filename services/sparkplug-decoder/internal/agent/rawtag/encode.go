package rawtag

import (
	"encoding/json"
	"fmt"
)

// OutTag is one tag reading to encode into the Tier-1 envelope — the
// producer-side counterpart of RawTag. A connectivity plane (the s7-reader,
// or a Node-RED tee) fills Metric + Value (+ an optional Long type hint) and
// hands a slice to Encode. Value must be a JSON scalar (number, bool, string):
// exactly what decodeValue accepts on the way back in.
type OutTag struct {
	Metric string
	Value  any
	Long   bool
}

// Encode builds one raw-tag envelope body: the inverse of Decode. endpoint +
// scanTS (unix-millis) head the envelope; each OutTag becomes a suffix-named
// tag reading. The output marshals to the SAME JSON Decode consumes (field
// names endpoint, scan_ts, tags, metric, value, long), so Encode→Decode is a
// round-trip that preserves metric, value, and the long hint. Per-tag quality
// (q), timestamp (ts), and param id are producer concerns the s7-reader path
// does not set today, so they are left at their absent/zero (omitempty) form.
func Encode(endpoint string, scanTS int64, tags []OutTag) ([]byte, error) {
	env := envelope{
		Endpoint: endpoint,
		ScanTS:   scanTS,
		Tags:     make([]envelopeTag, 0, len(tags)),
	}
	for _, t := range tags {
		raw, err := json.Marshal(t.Value)
		if err != nil {
			return nil, fmt.Errorf("rawtag: encode tag %q value: %w", t.Metric, err)
		}
		env.Tags = append(env.Tags, envelopeTag{
			Metric: t.Metric,
			Value:  json.RawMessage(raw),
			Long:   t.Long,
		})
	}
	return json.Marshal(env)
}
