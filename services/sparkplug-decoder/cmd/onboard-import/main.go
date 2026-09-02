// onboard-import — lift a legacy Node-RED flow's PLC addressing into the
// descriptor `plc:` block (ADR-0045 Phase-2 schema).
//
// A client migrating off hand-wired Node-RED already has every PLC endpoint
// (host, rack, slot) and every S7/Modbus/OPC-UA address expressed in their flow.
// This tool transcribes that mechanically so the onboarding engineer does not
// hand-author addresses (and cannot fat-finger a DB offset). It emits the `plc:`
// subtree ready to splice into the descriptor, and prints a provisioning table of
// endpoint → real host so the operator can create the referenced secrets.
//
// It never invents what the flow cannot supply: a bare-number S7 count-index that
// the descriptor cannot resolve, and a Modbus block read's per-register map, are
// emitted as commented skeletons with WARNINGs — never silently dropped, never
// guessed.
//
// Usage:
//
//	onboard-import --flow flow.json --descriptor cpack.descriptor.yaml --out plc-block.yaml
//	onboard-import --flow flow.json --descriptor cpack.descriptor.yaml --tenant cpack --env staging
//
// Runs once and exits. Pure: same inputs → same output.
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/flowimport"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "onboard-import:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		flowPath       = flag.String("flow", "", "path to the legacy Node-RED flow JSON (required)")
		descriptorPath = flag.String("descriptor", "", "path to the existing client descriptor YAML (required — supplies canonical.prefix + count-index map)")
		tenant         = flag.String("tenant", "", "tenant slug for the generated secret refs (default: descriptor.tenant lowercased)")
		env            = flag.String("env", "staging", "environment for the generated secret refs (staging|production)")
		outPath        = flag.String("out", "", "output file for the plc: block; empty prints to stdout")
	)
	flag.Parse()

	if strings.TrimSpace(*flowPath) == "" || strings.TrimSpace(*descriptorPath) == "" {
		flag.Usage()
		return fmt.Errorf("--flow and --descriptor are required")
	}

	d, err := clientdescriptor.Load(*descriptorPath)
	if err != nil {
		return err
	}
	flowJSON, err := os.ReadFile(*flowPath)
	if err != nil {
		return fmt.Errorf("read flow %s: %w", *flowPath, err)
	}

	res, err := flowimport.Import(flowJSON, flowimport.Options{
		Descriptor: d,
		Tenant:     *tenant,
		Env:        *env,
	})
	if err != nil {
		return err
	}

	// The plc: block → stdout or file.
	if strings.TrimSpace(*outPath) == "" {
		os.Stdout.WriteString(res.YAML)
	} else {
		if err := os.WriteFile(*outPath, []byte(res.YAML), 0o644); err != nil {
			return fmt.Errorf("write %s: %w", *outPath, err)
		}
		fmt.Fprintf(os.Stderr, "onboard-import: wrote %s\n", *outPath)
	}

	// The host provisioning table (secret VALUES) → stderr only, never the YAML.
	if len(res.HostRefs) > 0 {
		fmt.Fprintln(os.Stderr, "\n── secret provisioning table (create each ref with its host as the value) ──")
		for _, h := range res.HostRefs {
			fmt.Fprintf(os.Stderr, "  %-40s → %s\n", h.Ref, h.Host)
		}
	}
	for _, n := range res.Notes {
		fmt.Fprintln(os.Stderr, "note:", n)
	}
	for _, w := range res.Warnings {
		fmt.Fprintln(os.Stderr, "WARN:", w)
	}
	fmt.Fprintf(os.Stderr, "\nonboard-import: %d endpoint(s), %d tag(s) mapped, %d unresolved (count-index), %d skeleton (modbus/unparseable)\n",
		res.NumEndpoints, res.NumTagsMapped, res.NumUnresolved, res.NumSkeleton)
	return nil
}
