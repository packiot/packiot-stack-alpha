// onboard — the ADR-0045 P3 CLIENT-ONBOARDING ORCHESTRATOR.
//
// One guided tool that a Customer Success engineer drives end-to-end to onboard
// a factory, wrapping the P1 generator (cmd/onboard-gen) and the P2 capture
// reconciler (cmd/onboard-capture) into a single stateful flow. It never
// hand-edits an artifact and never executes a cutover; it orchestrates the five
// ADR-0045 §2.5 stages and enforces the "no cutover on inferred data" gate.
//
// The flow (each command records progress in <tenant>.onboard.json):
//
//	onboard describe --descriptor PATH [--init --tenant T --enterprise N --prefix P]
//	    ① scaffold a starter descriptor (with --init) and/or validate it.
//	onboard generate --descriptor PATH [--out DIR]
//	    ② run P1 → emit the four artifacts to a per-client dir.
//	onboard capture  --descriptor PATH (--healthz F | --agent-url U) [--accepted F] [--only L] [--apply]
//	    ③ reconcile live-tee indices; --apply rewrites inferred → confirmed in the descriptor.
//	onboard validate --descriptor PATH [--healthz F | --agent-url U] [--accepted F]
//	    ④ readiness gate: all-confirmed + cutover config builds + (optional) Mode-A parity.
//	onboard cutover  --descriptor PATH
//	    ⑤ PRINT the cutover checklist — hard-gated on ④ green; executes NOTHING.
//	onboard status   --descriptor PATH
//	    show where the tenant is in the flow.
//	onboard run      --descriptor PATH [--healthz F ...] [--apply] [--out DIR]
//	    guided: describe → generate → (capture if observations given) → validate, then stop.
//
// Read-only against the world: it reads files + one HTTP GET of /healthz, and
// writes only the manifest, the generated artifacts, and (with --apply) the
// descriptor's captured indices. No DB writes, no broker writes, no cutover.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/onboard"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]
	if err := dispatch(cmd, args); err != nil {
		fmt.Fprintf(os.Stderr, "onboard %s: %v\n", cmd, err)
		os.Exit(1)
	}
}

func dispatch(cmd string, args []string) error {
	switch cmd {
	case "describe":
		return cmdDescribe(args)
	case "generate":
		return cmdGenerate(args)
	case "capture":
		return cmdCapture(args)
	case "validate":
		return cmdValidate(args)
	case "cutover":
		return cmdCutover(args)
	case "status":
		return cmdStatus(args)
	case "run":
		return cmdRun(args)
	case "-h", "--help", "help":
		usage()
		return nil
	default:
		usage()
		return fmt.Errorf("unknown command %q", cmd)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `onboard — ADR-0045 P3 client-onboarding orchestrator

Usage: onboard <command> [flags]

Commands:
  describe   ① scaffold (--init) and/or validate a client descriptor
  generate   ② emit the four artifacts from the descriptor
  capture    ③ reconcile live-tee count indices (--apply to confirm in place)
  validate   ④ readiness gate (all-confirmed + cutover builds + Mode-A parity)
  cutover    ⑤ print the cutover checklist (hard-gated; executes nothing)
  status     show the tenant's progress through the flow
  run        guided: describe → generate → capture → validate

All commands take --descriptor PATH. Run 'onboard <command> -h' for flags.
`)
}

// newFS builds a flagset that prints its own usage on error.
func newFS(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	return fs
}

func cmdDescribe(args []string) error {
	fs := newFS("describe")
	descriptor := fs.String("descriptor", "", "path to the client descriptor YAML (required)")
	initFlag := fs.Bool("init", false, "scaffold a starter descriptor if the file does not exist")
	tenant := fs.String("tenant", "", "tenant short-name for --init (e.g. CPACK)")
	enterprise := fs.Int("enterprise", 0, "enterprise_id for --init")
	prefix := fs.String("prefix", "", "canonical tenant_prefix for --init (default: <TENANT>)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *descriptor == "" {
		return fmt.Errorf("--descriptor is required")
	}
	l := &onboard.Loop{DescriptorPath: *descriptor}
	_, err := l.Describe(onboard.DescribeOptions{
		Scaffold: *initFlag, Tenant: *tenant, EnterpriseID: *enterprise, Prefix: *prefix,
	})
	return err
}

func cmdGenerate(args []string) error {
	fs := newFS("generate")
	descriptor := fs.String("descriptor", "", "path to the client descriptor YAML (required)")
	out := fs.String("out", "", "per-client artifact output dir (default: gen/<tenant>/)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *descriptor == "" {
		return fmt.Errorf("--descriptor is required")
	}
	l := &onboard.Loop{DescriptorPath: *descriptor, OutDir: *out}
	_, err := l.Generate(onboard.GenerateOptions{OutDir: *out})
	return err
}

func cmdCapture(args []string) error {
	fs := newFS("capture")
	descriptor := fs.String("descriptor", "", "path to the client descriptor YAML (required)")
	healthz := fs.String("healthz", "", "path to a captured verbose /healthz JSON fixture")
	agentURL := fs.String("agent-url", "", "base URL of a running sparkplug-agent to GET /healthz from")
	accepted := fs.String("accepted", "", "path to a newline-delimited accepted/mapped suffix list (optional)")
	only := fs.String("only", "", "scope to one line/cell component, e.g. L6")
	apply := fs.Bool("apply", false, "rewrite the descriptor's inferred indices to confirmed in place")
	insecure := fs.Bool("insecure", false, "skip TLS verification for --agent-url (staging self-signed)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *descriptor == "" {
		return fmt.Errorf("--descriptor is required")
	}
	l := &onboard.Loop{DescriptorPath: *descriptor}
	_, _, err := l.Capture(onboard.CaptureOptions{
		HealthzPath: *healthz, AgentURL: *agentURL, Insecure: *insecure,
		AcceptedPath: *accepted, Only: *only, Apply: *apply,
	})
	return err
}

func cmdValidate(args []string) error {
	fs := newFS("validate")
	descriptor := fs.String("descriptor", "", "path to the client descriptor YAML (required)")
	healthz := fs.String("healthz", "", "path to a verbose /healthz JSON fixture (enables Mode-A parity gate)")
	agentURL := fs.String("agent-url", "", "base URL of a running sparkplug-agent (enables Mode-A parity gate)")
	accepted := fs.String("accepted", "", "path to a newline-delimited accepted/mapped suffix list (optional)")
	insecure := fs.Bool("insecure", false, "skip TLS verification for --agent-url")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *descriptor == "" {
		return fmt.Errorf("--descriptor is required")
	}
	l := &onboard.Loop{DescriptorPath: *descriptor}
	_, res, err := l.Validate(onboard.ValidateOptions{
		HealthzPath: *healthz, AgentURL: *agentURL, Insecure: *insecure, AcceptedPath: *accepted,
	})
	if err != nil {
		return err
	}
	if !res.Green {
		return fmt.Errorf("validate gate RED (not cutover-eligible)")
	}
	return nil
}

func cmdCutover(args []string) error {
	fs := newFS("cutover")
	descriptor := fs.String("descriptor", "", "path to the client descriptor YAML (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *descriptor == "" {
		return fmt.Errorf("--descriptor is required")
	}
	l := &onboard.Loop{DescriptorPath: *descriptor}
	_, err := l.Cutover()
	return err
}

func cmdStatus(args []string) error {
	fs := newFS("status")
	descriptor := fs.String("descriptor", "", "path to the client descriptor YAML (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *descriptor == "" {
		return fmt.Errorf("--descriptor is required")
	}
	l := &onboard.Loop{DescriptorPath: *descriptor}
	_, err := l.Status()
	return err
}

// cmdRun is the guided end-to-end driver: describe → generate → (capture, if
// observations are supplied) → validate, printing each stage and stopping before
// the human-gated cutover. It is the "one guided tool" headline — a CS engineer
// runs one command and is walked to the cutover gate.
func cmdRun(args []string) error {
	fs := newFS("run")
	descriptor := fs.String("descriptor", "", "path to the client descriptor YAML (required)")
	out := fs.String("out", "", "per-client artifact output dir (default: gen/<tenant>/)")
	healthz := fs.String("healthz", "", "verbose /healthz JSON fixture — enables the CAPTURE + parity stages")
	agentURL := fs.String("agent-url", "", "running sparkplug-agent URL — enables the CAPTURE + parity stages")
	accepted := fs.String("accepted", "", "accepted/mapped suffix list (optional)")
	only := fs.String("only", "", "scope capture to one line/cell component")
	apply := fs.Bool("apply", false, "let capture rewrite inferred indices to confirmed in place")
	insecure := fs.Bool("insecure", false, "skip TLS verification for --agent-url")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *descriptor == "" {
		return fmt.Errorf("--descriptor is required")
	}
	l := &onboard.Loop{DescriptorPath: *descriptor, OutDir: *out}

	fmt.Fprintln(os.Stdout, "── ① describe ─────────────────────────────────────────")
	if _, err := l.Describe(onboard.DescribeOptions{}); err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, "\n── ② generate ─────────────────────────────────────────")
	if _, err := l.Generate(onboard.GenerateOptions{OutDir: *out}); err != nil {
		return err
	}
	if *healthz != "" || *agentURL != "" {
		fmt.Fprintln(os.Stdout, "\n── ③ capture ──────────────────────────────────────────")
		if _, _, err := l.Capture(onboard.CaptureOptions{
			HealthzPath: *healthz, AgentURL: *agentURL, Insecure: *insecure,
			AcceptedPath: *accepted, Only: *only, Apply: *apply,
		}); err != nil {
			return err
		}
	} else {
		fmt.Fprintln(os.Stdout, "\n── ③ capture ── skipped (no --healthz/--agent-url; supply observations to capture)")
	}
	fmt.Fprintln(os.Stdout, "\n── ④ validate ─────────────────────────────────────────")
	_, res, err := l.Validate(onboard.ValidateOptions{
		HealthzPath: *healthz, AgentURL: *agentURL, Insecure: *insecure, AcceptedPath: *accepted,
	})
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, "\n── ⑤ cutover ──────────────────────────────────────────")
	if res.Green {
		fmt.Fprintln(os.Stdout, "VALIDATE is green — run `onboard cutover --descriptor "+*descriptor+"` to print the checklist.")
	} else {
		fmt.Fprintln(os.Stdout, "VALIDATE is RED — cutover is gated shut until every count index is confirmed.")
	}
	return nil
}
