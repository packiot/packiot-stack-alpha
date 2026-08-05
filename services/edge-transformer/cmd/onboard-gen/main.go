// onboard-gen — the ADR-0045 P1 client-onboarding generator.
//
// It reads ONE client descriptor (the CS-Admin SSoT) and emits the four
// downstream onboarding artifacts, so onboarding a factory is "fill a
// descriptor + regenerate", not "hand-edit four files and keep them in sync":
//
//  1. <tenant>-profile.yaml    — the tenant conversion profile (tenantprofile)
//  2. <tenant>-register.sql     — packml_register INSERT (topic ↔ id_equipment)
//  3. <tenant>-agent.yaml       — the sparkplug-agent descriptor (agentcfg)
//  4. <tenant>-tee-node.json    — the Node-RED Tier-1 raw-forwarder flow
//  5. <tenant>-client.yaml      — the Go PLC readers' config (clientconfig),
//     emitted ONLY when the descriptor has a plc block
//  6. <tenant>-reader-flow.json — the Node-RED own-reader flow (S7/OPC-UA/Modbus
//     → normalize → POST raw tags to the local sparkplug-agent) + a per-client
//     customizations tab, emitted ONLY when the descriptor has a plc block (the
//     autonomous-edge deployable, generated from the SAME block as artifact 5)
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
//
// GREENFIELD scaffolding (a NEW client with no legacy flow to import):
//
//	onboard-gen scaffold --tenant acme --site sp --lines 3 --protocols s7,modbus
//	onboard-gen scaffold --tenant acme --site sp --lines 2 --out gen/
//
// The scaffold subcommand emits a VALID starter descriptor (round-trips through
// Parse) so the CS engineer edits fill-in-the-blanks values instead of authoring
// against a blank file. A multi-protocol scaffold shows the multi-source pattern
// (two endpoints → one equipment) in its commented tag-map guidance.
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
	// Git-style subcommand dispatch: `onboard-gen scaffold …` is the greenfield
	// path; the bare form (flags only) is the generate-from-descriptor path.
	if len(os.Args) > 1 && os.Args[1] == "scaffold" {
		if err := runScaffold(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "onboard-gen scaffold:", err)
			os.Exit(1)
		}
		return
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "onboard-gen:", err)
		os.Exit(1)
	}
}

// runScaffold implements `onboard-gen scaffold` — the greenfield starter-descriptor
// generator. It emits ONE file (<tenant>.descriptor.yaml) to --out, or to stdout
// when --out is empty. Pure core (clientdescriptor.ScaffoldYAML) + thin CLI.
func runScaffold(args []string) error {
	fs := flag.NewFlagSet("scaffold", flag.ContinueOnError)
	var (
		tenant    = fs.String("tenant", "", "tenant slug / group_id, e.g. acme (required)")
		site      = fs.String("site", "", "site short-name, e.g. sp (required)")
		lines     = fs.Int("lines", 1, "number of production lines to stub (>= 1)")
		protocols = fs.String("protocols", "s7", "comma list of PLC protocols: s7,modbus,opcua")
		outDir    = fs.String("out", "", "output directory; if empty, print the descriptor to stdout")
	)
	if err := fs.Parse(args); err != nil {
		return err
	}

	var protos []string
	for _, p := range strings.Split(*protocols, ",") {
		if p = strings.TrimSpace(p); p != "" {
			protos = append(protos, p)
		}
	}

	opts := clientdescriptor.ScaffoldOptions{
		Tenant:    *tenant,
		Site:      *site,
		Lines:     *lines,
		Protocols: protos,
	}
	out, err := clientdescriptor.ScaffoldYAML(opts)
	if err != nil {
		return err
	}

	if strings.TrimSpace(*outDir) == "" {
		os.Stdout.Write(out)
		return nil
	}
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		return fmt.Errorf("create out dir: %w", err)
	}
	name := strings.ToLower(strings.TrimSpace(*tenant)) + ".descriptor.yaml"
	p := filepath.Join(*outDir, name)
	if err := os.WriteFile(p, out, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", p, err)
	}
	fmt.Fprintf(os.Stderr, "onboard-gen scaffold: wrote %s\n", p)
	return nil
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
		{tenant + "-agent.yaml", art.AgentYAML},
		{tenant + "-tee-node.json", art.TeeSnippet},
	}
	// Artifact 5: the Go PLC readers' client.yaml, emitted only when the
	// descriptor declares a plc block (art.ClientYAML is nil otherwise).
	if art.ClientYAML != nil {
		files = append(files, struct {
			name string
			data []byte
		}{tenant + "-client.yaml", art.ClientYAML})
	}
	// Artifact 6: the Node-RED own-reader flow, emitted (like artifact 5) only when
	// the descriptor carries a plc block (art.ReaderFlow is nil otherwise) — the
	// autonomous-edge deployable + per-client customization surface.
	if art.ReaderFlow != nil {
		files = append(files, struct {
			name string
			data []byte
		}{tenant + "-reader-flow.json", art.ReaderFlow})
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
