package handlers

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

func TestNormalizeMetricTimestamps(t *testing.T) {
	const now = int64(1790000000000)       // 2026-09
	const payloadTs = int64(1789999000000) // plausible payload stamp
	const own = int64(1789998000000)       // plausible metric stamp
	const unsetClock = int64(556000)       // 1970-01-01 00:09:16 — device booted w/o clock (P10)

	cases := []struct {
		name            string
		metric, payload int64
		want            int64
	}{
		{"own plausible stamp kept", own, payloadTs, own},
		{"missing (0) → payload", 0, payloadTs, payloadTs},
		{"unset device clock → payload", unsetClock, payloadTs, payloadTs},
		{"both missing → now", 0, 0, now},
		{"both unset clock → now", unsetClock, unsetClock, now},
	}
	for _, c := range cases {
		p := &sparkplug.Payload{Timestamp: c.payload, Metrics: []sparkplug.Metric{{Timestamp: c.metric}}}
		normalizeMetricTimestamps(p, now)
		if got := p.Metrics[0].Timestamp; got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
}
