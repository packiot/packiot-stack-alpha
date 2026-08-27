// onboard-gen — the ADR-0045 P1 client-onboarding generator.
//
// It reads ONE client descriptor (the CS-Admin SSoT) and emits the downstream
// onboarding artifacts, so onboarding a factory is "fill a descriptor +
// regenerate", not "hand-edit files and keep them in sync":
//
//  1. <tenant>-profile.yaml            — the tenant conversion profile (tenantprofile)
//  2. <tenant>-register.sql            — packml_register INSERT (topic ↔ id_equipment)
//     2b. <tenant>-equipment-position.sql — equipments.position line flow order (ADR-0045 Bronze)
//  3. <tenant>-agent.yaml              — the sparkplug-agent descriptor (agentcfg)
//  4. <tenant>-tee-node.json           — the Node-RED Tier-1 raw-forwarder flow
//
// Usage:
//
//	onboard-gen --descriptor docs/clients/cpack.descriptor.yaml            # print all to stdout
//	onboard-gen --descriptor cpack.descriptor.yaml --out gen/              # write four files
//	onboard-gen --descriptor cpack.descriptor.yaml --cutover               # refuse if any index inferred
//
// The --cutover flag enforces the ADR-0045 §2.4b rule: no tenant cuts over on
// inferred count indices. Without it, generation is draft/observe (everything
// emitted; not cutover-eligible). Runs once and exits.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/clientdescriptor"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "onboard-gen:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		descriptorPath = flag.String("descriptor", "", "path to the client descriptor YAML (required)")
		outDir         = flag.String("out", "", "output directory; if empty, print all artifacts to stdout")
		cutover        = flag.Bool("cutover", false, "emit CUTOVER-ready config: refuse if any count index is still inferred")
	)
	flag.Parse()

	if strings.TrimSpace(*descriptorPath) == "" {
		flag.Usage()
		return fmt.Errorf("--descriptor is required")
	}

	d, err := clientdescriptor.Load(*descriptorPath)
	if err != nil {
		return err
	}

	// Always surface the inferred-index picture — the reviewer needs to know the
	// cutover-readiness state whether or not --cutover was passed.
	if inferred := d.InferredMembers(); len(inferred) > 0 {
		fmt.Fprintf(os.Stderr, "onboard-gen: %d count index(es) still INFERRED (capture on a live tee before cutover):\n", len(inferred))
		for _, topic := range inferred {
			fmt.Fprintf(os.Stderr, "  - %s\n", topic)
		}
	} else {
		fmt.Fprintln(os.Stderr, "onboard-gen: all count indices CONFIRMED — cutover-eligible.")
	}

	art, err := d.Generate(clientdescriptor.GenerateOptions{Cutover: *cutover})
	if err != nil {
		return err
	}

	tenant := strings.ToLower(d.Tenant)
	files := []struct {
		name string
		data []byte
	}{
		{tenant + "-profile.yaml", art.ProfileYAML},
		{tenant + "-register.sql", []byte(art.RegisterSQL)},
		{tenant + "-equipment-position.sql", []byte(art.PositionSQL)},
		{tenant + "-agent.yaml", art.AgentYAML},
		{tenant + "-tee-node.json", art.TeeSnippet},
	}

	if *outDir == "" {
		for _, f := range files {
			fmt.Printf("# ==================== %s ====================\n", f.name)
			os.Stdout.Write(f.data)
			fmt.Println()
		}
		return nil
	}

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		return fmt.Errorf("create out dir: %w", err)
	}
	for _, f := range files {
		p := filepath.Join(*outDir, f.name)
		if err := os.WriteFile(p, f.data, 0o644); err != nil {
			return fmt.Errorf("write %s: %w", p, err)
		}
		fmt.Fprintf(os.Stderr, "onboard-gen: wrote %s\n", p)
	}
	return nil
}
