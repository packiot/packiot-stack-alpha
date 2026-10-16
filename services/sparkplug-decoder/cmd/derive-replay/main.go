// Command derive-replay is the ADR-0058 P2.2 customization test/simulate harness.
// It feeds a stream of captured (or hand-authored) raw tags through the SAME
// production DERIVE stage a real client would use — Load descriptor →
// GenerateProfile → deriver.New → Process — and prints the synthesized tags. It
// answers "what would this client's derive/expr rules actually produce?" WITHOUT
// a live box: point it at the descriptor + a sample capture and read the emitted
// canonical counts.
//
// Why it exists: a customization (an integral, a sum, or an ADR-0058 expr) is
// only trustworthy if you can see its output on representative data BEFORE it
// ships. Unit tests hand-build a Profile; this harness proves the whole chain
// through the real descriptor loader + generator, so a rule that resolves wrong
// (bad {idx}, wrong segment, an unmapped var) shows up as a missing/wrong tag.
//
// Usage:
//
//	derive-replay -descriptor path/to/client.descriptor.yaml [-samples file.jsonl]
//
// Samples are JSON lines, one raw tag per line (the tee/reader wire shape):
//
//	{"metric":"/L5/SCRAP/Status/DW0","value":100,"ts_millis":1000}
//	{"metric":"/L5/SCRAP/Status/DW4","value":88,"ts_millis":1000}
//
// Each line is processed in arrival order (so cross-envelope LATCHING behaves as
// in production: a sum/expr re-emits once every input has been seen). With no
// -samples the harness reads JSONL from stdin.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/derivesim"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// sampleTag is the JSONL wire shape for one raw input tag.
type sampleTag struct {
	Metric   string  `json:"metric"`
	Value    float64 `json:"value"`
	TsMillis int64   `json:"ts_millis"`
}

// Emitted is one synthesized tag the deriver produced for a given input step.
// Aliased to the shared derivesim type so the CLI and the /v1/onboard/simulate
// endpoint report identical shapes.
type Emitted = derivesim.Emitted

// Replay runs samples (in order) through a deriver built from profile and returns
// every synthesized tag, in emission order. Thin wrapper over the shared
// derivesim core so the CLI and the HTTP endpoint can never drift.
func Replay(profile *tenantprofile.Profile, samples []rawtag.RawTag) []Emitted {
	return derivesim.Run(profile, samples)
}

func main() {
	descPath := flag.String("descriptor", "", "path to the client descriptor YAML (required)")
	samplesPath := flag.String("samples", "", "path to a JSONL sample file (default: stdin)")
	flag.Parse()

	if *descPath == "" {
		fmt.Fprintln(os.Stderr, "error: -descriptor is required")
		flag.Usage()
		os.Exit(2)
	}

	d, err := clientdescriptor.Load(*descPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load descriptor: %v\n", err)
		os.Exit(1)
	}
	profile, err := d.GenerateProfile()
	if err != nil {
		fmt.Fprintf(os.Stderr, "generate profile: %v\n", err)
		os.Exit(1)
	}

	// Show the resolved derive rules so the operator sees what is active.
	fmt.Fprintf(os.Stderr, "# tenant %s — %d derive rule(s):\n", profile.TenantPrefix, len(profile.Derived))
	for _, r := range profile.Derived {
		kind := "?"
		switch {
		case r.Integral != nil:
			kind = "integral"
		case r.Sum != nil:
			kind = "sum"
		case r.Expr != nil:
			kind = fmt.Sprintf("expr %q %v", r.Expr.Expr, r.Expr.Vars)
		}
		fmt.Fprintf(os.Stderr, "#   %s → %v [%s]\n", r.Segment, r.Emit, kind)
	}

	var in io.Reader = os.Stdin
	if *samplesPath != "" {
		f, err := os.Open(*samplesPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "open samples: %v\n", err)
			os.Exit(1)
		}
		defer f.Close()
		in = f
	}

	samples, err := readSamples(in)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read samples: %v\n", err)
		os.Exit(1)
	}

	emitted := Replay(profile, samples)
	for _, e := range emitted {
		fmt.Printf("EMIT %s = %v @%d  (after %s)\n", e.Metric, e.Value, e.TsMillis, e.AfterInput)
	}
	fmt.Fprintf(os.Stderr, "# %d samples in → %d synthesized tag(s) out\n", len(samples), len(emitted))
}

// readSamples parses JSONL raw tags into rawtag.RawTag values.
func readSamples(r io.Reader) ([]rawtag.RawTag, error) {
	var out []rawtag.RawTag
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	line := 0
	for sc.Scan() {
		line++
		b := sc.Bytes()
		if len(b) == 0 {
			continue
		}
		var s sampleTag
		if err := json.Unmarshal(b, &s); err != nil {
			return nil, fmt.Errorf("line %d: %w", line, err)
		}
		out = append(out, rawtag.RawTag{
			Metric:   s.Metric,
			Value:    s.Value,
			TsMillis: s.TsMillis,
			Quality:  true,
		})
	}
	return out, sc.Err()
}
