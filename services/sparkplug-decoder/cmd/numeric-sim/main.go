// numeric-sim — a DUMB numeric-counter tee simulator for STAGING validation of
// the stack-side numeric-count-index translation layer (ADR-0045 §2.3, task #13).
//
// It stands in for a bispharma/bisnago legacy edge whose real PLC feed is not yet
// wired: it POSTs the legacy `counterData[{id,value}]` envelope — bare numeric
// count ids + monotone ABSOLUTE totalizers — to a running sparkplug-agent's
// POST /v1/counters front-door (AGENT_NUMERIC_INGEST_ENABLED=true). The agent
// translates each id → a canonical SparkPlug metric, births/NDATAs it to the
// cloud edge-transformer, and the counters-only Calc computes OEE. No client edge
// is needed — this IS the client's dumb tee, synthesized.
//
// It forwards ONLY {id,value} — no topic strings, no canonical names — exactly
// what the "proper translation layer" directive requires of the edge. All naming
// intelligence lives stack-side in the agent's count-index table.
//
// Usage:
//
//	numeric-sim --url https://localhost:9104/v1/counters --key "$KEY" \
//	    --group BISPHARMA --gateway bispharma-edge \
//	    --ids 164,165,166,167,168,169 \
//	    --polls 5 --interval 2s --start 40000 --step 30 --insecure
//
// --ids is the set of legacy count ids to emit (a couple of lines' worth). Each
// id gets its own monotone totalizer starting near --start, advancing ~--step
// (±jitter) per poll — the absolute-totalizer shape the stack derives deltas
// from (never negative; the reset case is exercised with --reset-at).
package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

type counter struct {
	ID    int     `json:"id"`
	Value float64 `json:"value"`
}

type envelope struct {
	Group       string    `json:"group"`
	Gateway     string    `json:"gateway"`
	Timestamp   int64     `json:"timestamp"`
	CounterData []counter `json:"counterData"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "numeric-sim:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		url      = flag.String("url", "https://localhost:9104/v1/counters", "agent /v1/counters front-door URL")
		key      = flag.String("key", os.Getenv("AGENT_INGEST_API_KEY"), "X-Ingest-Key (defaults to AGENT_INGEST_API_KEY)")
		group    = flag.String("group", "BISPHARMA", "tenant group stamped in the envelope (scope guard)")
		gateway  = flag.String("gateway", "bispharma-edge", "gateway id stamped in the envelope")
		idsCSV   = flag.String("ids", "164,165,166,167,168,169", "comma-separated legacy count ids to emit")
		polls    = flag.Int("polls", 5, "number of poll cycles to send")
		interval = flag.Duration("interval", 2*time.Second, "delay between polls")
		start    = flag.Float64("start", 40000, "starting absolute totalizer value")
		step     = flag.Float64("step", 30, "nominal totalizer advance per poll (jittered)")
		resetAt  = flag.Int("reset-at", -1, "poll index at which to simulate a counter reset (totalizer→small); -1 = never")
		insecure = flag.Bool("insecure", true, "skip TLS verification (staging self-signed)")
	)
	flag.Parse()

	if strings.TrimSpace(*key) == "" {
		return fmt.Errorf("--key or AGENT_INGEST_API_KEY is required (refusing to POST without an ingest key)")
	}
	ids, err := parseIDs(*idsCSV)
	if err != nil {
		return err
	}
	if len(ids) == 0 {
		return fmt.Errorf("--ids is empty")
	}

	// One monotone totalizer per id (absolute; the stack derives the delta).
	tot := make(map[int]float64, len(ids))
	for i, id := range ids {
		tot[id] = *start + float64(i)*1000 // stagger starts so ids are distinguishable
	}

	client := &http.Client{
		Timeout:   10 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: *insecure}},
	}
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))

	for p := 0; p < *polls; p++ {
		env := envelope{Group: *group, Gateway: *gateway, Timestamp: time.Now().UnixMilli()}
		for _, id := range ids {
			if p == *resetAt {
				tot[id] = rng.Float64() * *step // counter reset: totalizer drops (delta clamp exercised)
			} else if p > 0 {
				tot[id] += *step + float64(rng.Intn(int(*step)+1)) - *step/2 // jittered, never negative
				if tot[id] < 0 {
					tot[id] = 0
				}
			}
			env.CounterData = append(env.CounterData, counter{ID: id, Value: rounded(tot[id])})
		}
		if err := post(client, *url, *key, env); err != nil {
			return fmt.Errorf("poll %d: %w", p, err)
		}
		fmt.Printf("numeric-sim: poll %d/%d → %d counters (group=%s)\n", p+1, *polls, len(env.CounterData), *group)
		if p < *polls-1 {
			time.Sleep(*interval)
		}
	}
	fmt.Println("numeric-sim: done")
	return nil
}

func post(client *http.Client, url, key string, env envelope) error {
	body, err := json.Marshal(env)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Ingest-Key", key)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	buf := new(bytes.Buffer)
	_, _ = buf.ReadFrom(resp.Body)
	if resp.StatusCode != http.StatusAccepted {
		return fmt.Errorf("status %d: %s", resp.StatusCode, buf.String())
	}
	fmt.Printf("  → 202 %s\n", strings.TrimSpace(buf.String()))
	return nil
}

func parseIDs(csv string) ([]int, error) {
	var out []int
	for _, s := range strings.Split(csv, ",") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		n, err := strconv.Atoi(s)
		if err != nil {
			return nil, fmt.Errorf("bad id %q: %w", s, err)
		}
		out = append(out, n)
	}
	return out, nil
}

func rounded(v float64) float64 { return float64(int64(v)) }
