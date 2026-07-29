package mqtt

import (
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

func quietLogger() *slog.Logger { return slog.New(slog.NewJSONHandler(io.Discard, nil)) }

// capture records every publish the requester attempts.
type capture struct {
	mu     sync.Mutex
	topics []string
	bodies [][]byte
}

func (c *capture) fn(topic string, body []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.topics = append(c.topics, topic)
	c.bodies = append(c.bodies, body)
	return nil
}

// TestRequest_TopicAndPayload proves the requester publishes a well-formed
// rebirth NCMD to the node-level topic — the exact bytes the agent decodes.
func TestRequest_TopicAndPayload(t *testing.T) {
	cap := &capture{}
	r := newRequester(time.Minute, quietLogger())
	r.publish = cap.fn

	var metricHits []string
	r.SetMetric(func(g, e, trig string) { metricHits = append(metricHits, g+"/"+e+":"+trig) })

	r.Request("CPACK", "cpack-tee", "seq_gap")

	if len(cap.topics) != 1 {
		t.Fatalf("published %d NCMDs, want 1", len(cap.topics))
	}
	if want := "spBv1.0/CPACK/NCMD/cpack-tee"; cap.topics[0] != want {
		t.Fatalf("topic: got %q, want %q", cap.topics[0], want)
	}
	p, err := sparkplug.Decode(cap.bodies[0])
	if err != nil {
		t.Fatalf("decode published NCMD: %v", err)
	}
	if !sparkplug.IsRebirthRequest(p) {
		t.Fatal("published NCMD is not a valid rebirth request")
	}
	if len(metricHits) != 1 || metricHits[0] != "CPACK/cpack-tee:seq_gap" {
		t.Fatalf("metric hook: got %v, want [CPACK/cpack-tee:seq_gap]", metricHits)
	}
}

// TestRequest_DebouncePerNode proves the throttle: a burst for the same node
// sends exactly one NCMD within the interval, while a DIFFERENT node is not
// throttled (per-node keying).
func TestRequest_DebouncePerNode(t *testing.T) {
	cap := &capture{}
	r := newRequester(time.Hour, quietLogger())
	r.publish = cap.fn

	for i := 0; i < 5; i++ {
		r.Request("CPACK", "cpack-tee", "no_birth")
	}
	r.Request("CPACK", "other-node", "no_birth")

	if len(cap.topics) != 2 {
		t.Fatalf("debounce failed: sent %d NCMDs, want 2 (one per node): %v", len(cap.topics), cap.topics)
	}
}

// TestRequest_DebounceExpires proves a node CAN be re-requested once the
// interval elapses (the throttle is a window, not a one-shot latch).
func TestRequest_DebounceExpires(t *testing.T) {
	cap := &capture{}
	r := newRequester(10*time.Millisecond, quietLogger())
	r.publish = cap.fn

	r.Request("CPACK", "cpack-tee", "seq_gap")
	time.Sleep(20 * time.Millisecond)
	r.Request("CPACK", "cpack-tee", "seq_gap")

	if len(cap.topics) != 2 {
		t.Fatalf("after interval elapsed: sent %d, want 2", len(cap.topics))
	}
}
