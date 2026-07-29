// onboard-capture is the ADR-0045 P2 LIVE-TEE COUNT-INDEX CAPTURE tool — the
// "capture" step of the CS-Admin onboarding loop describe → generate → CAPTURE
// → validate → cut over.
//
// What it does
// ------------
// A member's count index (`…/Admin/ProdProcessedCount/<IDX>/Unit`) is an
// arbitrary, unknowable PLC channel number (#601). The onboarding descriptor
// (ADR-0045 P1) carries each index tagged confirmed | inferred and refuses a
// cutover config while any inferred index remains. This tool turns inferred
// guesses into confirmed facts by OBSERVING what a client's live tee actually
// sends, then reconciling observed-vs-expected and emitting a corrected
// descriptor fragment. It is READ-ONLY: it reads files and does an HTTP GET of
// the agent's /healthz; it writes nothing to the agent, broker, or database.
//
// Inputs
// ------
//
//	--descriptor PATH   the ADR-0045 P1 client descriptor (expected indices +
//	                    confirmed/inferred confidence + inventory + templates).
//	--healthz PATH      a captured verbose /healthz JSON (the P0 unmapped set), OR
//	--agent-url URL     fetch /healthz live from a running agent (GET only).
//	--accepted PATH     optional newline-delimited list of ACCEPTED/mapped
//	                    suffixes (positive evidence). Without it, only MISMATCHes
//	                    (wrong indices surfacing as unmapped) can be captured;
//	                    correct-but-inferred members stay MISSING (unproven).
//	--only NAME         scope to one line/cell (e.g. "L6").
//	--json              emit the machine-readable report instead of the table.
//	--fragment PATH     write the descriptor fragment here (default: stdout tail).
//	--cutover           exit non-zero unless the scope is cutover-READY (every
//	                    opted-in member CONFIRMED) — the "no cutover on inferred"
//	                    gate, for CI.
//	--insecure          skip TLS verification for --agent-url (staging self-signed).
//
// The observed topic set = the accepted/mapped suffixes ∪ the P0 verbose
// /healthz unmapped suffixes. P0 must be run with AGENT_UNMAPPED_VERBOSE=true so
// /healthz enumerates unmapped_suffixes.
//
// Live invocation (documented; the agent is not reachable from every workstation)
// ------------------------------------------------------------------------------
//
//	# 1. Turn on the P0 verbose enumeration on the tenant's agent, let the tee run.
//	#    (AGENT_UNMAPPED_VERBOSE=true in the agent's env; restart; observe a shift.)
//	# 2. Capture the accepted set from the agent's SparkPlug NBIRTH (the tagstore
//	#    snapshot = every mapped metric that has received a value), e.g.:
//	#      mosquitto_sub -h <broker> -t 'spBv1.0/CPACK/NBIRTH/#' -C 1 \
//	#        | jq -r '.metrics[].name' > accepted.txt
//	# 3. Reconcile:
//	go run ./cmd/onboard-capture \
//	    --descriptor docs/clients/cpack.descriptor.yaml \
//	    --agent-url https://cpack-agent:9102 --insecure \
//	    --accepted accepted.txt \
//	    --only L6 --cutover
//
// A worked example (CPACK L6/L8) ships as an offline fixture set under
// internal/agent/capture/testdata; see the golden test for the exact shapes.
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/capture"
)

func main() {
	var (
		descriptorPath = flag.String("descriptor", "", "path to the ADR-0045 P1 client descriptor YAML (required)")
		healthzPath    = flag.String("healthz", "", "path to a captured verbose /healthz JSON fixture")
		agentURL       = flag.String("agent-url", "", "base URL of a running sparkplug-agent to GET /healthz from (e.g. https://cpack-agent:9102)")
		acceptedPath   = flag.String("accepted", "", "path to a newline-delimited accepted/mapped suffix list (optional)")
		only           = flag.String("only", "", "scope to one line/cell component, e.g. L6 (default: all members)")
		asJSON         = flag.Bool("json", false, "emit the machine-readable JSON report")
		fragmentPath   = flag.String("fragment", "", "write the descriptor fragment to this path (default: stdout)")
		cutover        = flag.Bool("cutover", false, "exit non-zero unless the scope is cutover-READY (no cutover on inferred)")
		insecure       = flag.Bool("insecure", false, "skip TLS verification for --agent-url (staging self-signed)")
	)
	flag.Parse()

	if err := run(*descriptorPath, *healthzPath, *agentURL, *acceptedPath, *only, *asJSON, *fragmentPath, *cutover, *insecure); err != nil {
		fmt.Fprintf(os.Stderr, "onboard-capture: %v\n", err)
		os.Exit(1)
	}
}

func run(descriptorPath, healthzPath, agentURL, acceptedPath, only string, asJSON bool, fragmentPath string, cutover, insecure bool) error {
	if descriptorPath == "" {
		return fmt.Errorf("--descriptor is required")
	}
	if healthzPath == "" && agentURL == "" {
		return fmt.Errorf("one of --healthz (fixture) or --agent-url (live) is required")
	}
	if healthzPath != "" && agentURL != "" {
		return fmt.Errorf("--healthz and --agent-url are mutually exclusive")
	}

	desc, err := capture.LoadDescriptor(descriptorPath)
	if err != nil {
		return err
	}

	var health *capture.Healthz
	if healthzPath != "" {
		health, err = capture.LoadHealthzFile(healthzPath)
	} else {
		health, err = fetchHealthz(agentURL, insecure)
	}
	if err != nil {
		return err
	}
	if !health.Components.UnmappedTags.Verbose {
		fmt.Fprintf(os.Stderr,
			"onboard-capture: WARNING — /healthz reports verbose=false; run the agent with "+
				"AGENT_UNMAPPED_VERBOSE=true so unmapped_suffixes are enumerated (MISMATCH capture needs them).\n")
	}

	var accepted []string
	if acceptedPath != "" {
		accepted, err = capture.LoadAcceptedFile(acceptedPath)
		if err != nil {
			return err
		}
	}

	rep, err := capture.Reconcile(desc, accepted, health, capture.Options{Only: only})
	if err != nil {
		return err
	}

	if asJSON {
		out, err := rep.JSON()
		if err != nil {
			return err
		}
		fmt.Println(string(out))
	} else {
		fmt.Print(rep.Text())
	}

	// Emit the descriptor fragment (the "paste back" artifact).
	frag := rep.Fragment()
	if frag != "" {
		if fragmentPath != "" {
			if err := os.WriteFile(fragmentPath, []byte(frag), 0o644); err != nil {
				return fmt.Errorf("write fragment %s: %w", fragmentPath, err)
			}
			fmt.Fprintf(os.Stderr, "\nwrote descriptor fragment → %s\n", fragmentPath)
		} else if !asJSON {
			fmt.Printf("\n%s", frag)
		}
	}

	if cutover && !rep.CutoverReady {
		return fmt.Errorf("cutover gate: scope %q is NOT READY (%d blocking)", rep.Scope, len(rep.Blocking))
	}
	return nil
}

// fetchHealthz does a read-only GET of <base>/healthz. It tolerates the 503 the
// agent returns when a component is degraded (unmapped tags never degrade
// health, but another component might) — a non-200 body is still parsed.
func fetchHealthz(base string, insecure bool) (*capture.Healthz, error) {
	url := strings.TrimRight(base, "/") + "/healthz"
	client := &http.Client{Timeout: 10 * time.Second}
	if insecure {
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} //nolint:gosec // staging self-signed, opt-in
	}
	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", url, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", url, err)
	}
	return capture.ParseHealthz(body)
}
