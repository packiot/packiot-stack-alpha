package onboard

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/capture"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
)

// Loop is the onboarding orchestrator bound to one tenant's descriptor. Every
// stage method loads the persisted manifest, does its work via the P1/P2
// packages, records the outcome, and saves the manifest — so the flow is
// resumable and self-describing across invocations.
type Loop struct {
	DescriptorPath string
	ManifestPath   string    // derived from the descriptor if empty
	OutDir         string    // per-client artifact dir; default gen/<tenant>/
	Out            io.Writer // human-facing messages; default os.Stdout
}

// out returns the message sink (defaulting to stdout).
func (l *Loop) out() io.Writer {
	if l.Out != nil {
		return l.Out
	}
	return os.Stdout
}

// loadManifest resolves the manifest path (deriving it from the descriptor's
// tenant when unset) and reads it, creating a fresh one if absent.
func (l *Loop) loadManifest(tenant string) (*Manifest, string, error) {
	path := l.ManifestPath
	if path == "" {
		path = DefaultManifestPath(l.DescriptorPath, tenant)
	}
	m, err := LoadManifest(path, tenant, l.DescriptorPath)
	if err != nil {
		return nil, "", err
	}
	return m, path, nil
}

// ── ① DESCRIBE ────────────────────────────────────────────────────────────────

// DescribeOptions drives the DESCRIBE stage.
type DescribeOptions struct {
	// Scaffold, when set, writes a starter descriptor (from the template) if the
	// descriptor file does not yet exist. Tenant/EnterpriseID/Prefix seed it.
	Scaffold     bool
	Tenant       string
	EnterpriseID int
	Prefix       string
}

// Describe scaffolds a new descriptor (if requested + absent) and then validates
// it via the P1 loader. Validation IS the stage's gate: a descriptor that does
// not load cannot advance. On success it records the tenant + inferred count.
func (l *Loop) Describe(opts DescribeOptions) (*Manifest, error) {
	if opts.Scaffold {
		if _, err := os.Stat(l.DescriptorPath); os.IsNotExist(err) {
			if strings.TrimSpace(opts.Tenant) == "" {
				return nil, fmt.Errorf("describe --init: --tenant is required to scaffold a descriptor")
			}
			if dir := filepath.Dir(l.DescriptorPath); dir != "" {
				if err := os.MkdirAll(dir, 0o755); err != nil {
					return nil, fmt.Errorf("onboard: create descriptor dir: %w", err)
				}
			}
			body := scaffoldDescriptor(opts.Tenant, opts.EnterpriseID, opts.Prefix)
			if err := os.WriteFile(l.DescriptorPath, []byte(body), 0o644); err != nil {
				return nil, fmt.Errorf("onboard: write scaffold: %w", err)
			}
			fmt.Fprintf(l.out(), "describe: scaffolded %s — fill the equipment: block, then re-run describe.\n", l.DescriptorPath)
			// A scaffold is intentionally incomplete (empty equipment) → it will
			// fail Load below and land the stage as pending, which is correct.
		}
	}

	// The tenant for the manifest path: prefer the scaffold tenant, else read it
	// from the (possibly just-written) descriptor via a tolerant peek so the
	// manifest lands even if full validation later fails.
	tenant := opts.Tenant
	if tenant == "" {
		tenant = peekTenant(l.DescriptorPath)
	}
	m, mpath, err := l.loadManifest(tenant)
	if err != nil {
		return nil, err
	}

	d, loadErr := clientdescriptor.Load(l.DescriptorPath)
	if loadErr != nil {
		m.set(StageDescribe, StatusPending, "descriptor not yet valid: "+truncate(loadErr.Error(), 90))
		_ = m.Save(mpath)
		fmt.Fprintf(l.out(), "describe: %s is not yet a valid descriptor:\n  %v\n", l.DescriptorPath, loadErr)
		return m, loadErr
	}

	m.Tenant = d.Tenant
	m.EnterpriseID = d.EnterpriseID
	m.DescriptorPath = l.DescriptorPath
	inferred := d.InferredMembers()
	m.InferredCount = len(inferred)
	detail := fmt.Sprintf("%d equipment, %d member(s) inferred", len(d.Equipment), len(inferred))
	m.set(StageDescribe, StatusDone, detail)
	if err := m.Save(mpath); err != nil {
		return nil, err
	}
	fmt.Fprintf(l.out(), "describe: OK — tenant=%s enterprise=%d, %s.\n", d.Tenant, d.EnterpriseID, detail)
	if len(inferred) > 0 {
		fmt.Fprintf(l.out(), "  %d count index(es) still inferred — a CAPTURE will be required before cutover.\n", len(inferred))
	}
	fmt.Fprintf(l.out(), "next: onboard generate\n")
	return m, nil
}

// ── ② GENERATE ──────────────────────────────────────────────────────────────

// GenerateOptions drives the GENERATE stage.
type GenerateOptions struct {
	// OutDir overrides the Loop's default per-client artifact directory.
	OutDir string
}

// Generate runs the P1 generator in DRAFT/OBSERVE posture (Cutover:false — it
// always emits, cutover-readiness is VALIDATE's job) and writes the four
// artifacts to a per-client directory. It records the output dir + the inferred
// picture so status shows what still needs capturing.
func (l *Loop) Generate(opts GenerateOptions) (*Manifest, error) {
	d, err := clientdescriptor.Load(l.DescriptorPath)
	if err != nil {
		return nil, fmt.Errorf("generate: %w", err)
	}
	m, mpath, err := l.loadManifest(d.Tenant)
	if err != nil {
		return nil, err
	}
	if m.Get(StageDescribe).Status != StatusDone {
		// Auto-satisfy DESCRIBE from a valid descriptor so a single-shot generate
		// works, but record it so status is coherent.
		m.Tenant, m.EnterpriseID = d.Tenant, d.EnterpriseID
		m.set(StageDescribe, StatusDone, fmt.Sprintf("%d equipment", len(d.Equipment)))
	}

	outDir := opts.OutDir
	if outDir == "" {
		outDir = l.OutDir
	}
	if outDir == "" {
		outDir = filepath.Join("gen", strings.ToLower(d.Tenant))
	}

	art, err := d.Generate(clientdescriptor.GenerateOptions{Cutover: false})
	if err != nil {
		return nil, fmt.Errorf("generate: %w", err)
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return nil, fmt.Errorf("generate: create out dir: %w", err)
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
	for _, f := range files {
		p := filepath.Join(outDir, f.name)
		if err := os.WriteFile(p, f.data, 0o644); err != nil {
			return nil, fmt.Errorf("generate: write %s: %w", p, err)
		}
		fmt.Fprintf(l.out(), "generate: wrote %s\n", p)
	}

	m.OutputDir = outDir
	inferred := d.InferredMembers()
	m.InferredCount = len(inferred)
	m.set(StageGenerate, StatusDone, fmt.Sprintf("4 artifacts → %s", outDir))
	if err := m.Save(mpath); err != nil {
		return nil, err
	}
	if len(inferred) > 0 {
		fmt.Fprintf(l.out(), "next: onboard capture — %d count index(es) inferred; deploy the agent (OBSERVE) + wire the tee, then capture.\n", len(inferred))
	} else {
		fmt.Fprintf(l.out(), "next: onboard validate — all indices confirmed; capture is optional (re-verify only).\n")
	}
	return m, nil
}

// ── ③ CAPTURE ─────────────────────────────────────────────────────────────────

// CaptureOptions drives the CAPTURE stage. Exactly one of HealthzPath /
// AgentURL supplies the observed unmapped set; AcceptedPath is optional positive
// evidence. Apply rewrites the descriptor's inferred indices to confirmed.
type CaptureOptions struct {
	HealthzPath  string
	AgentURL     string
	Insecure     bool
	AcceptedPath string
	Only         string
	// Apply, when true, writes the captured (confirmed) indices back into the
	// descriptor file in place — the loop-closing step. When false, the capture
	// only reports (dry-run) and prints the fragment.
	Apply bool
}

// Capture runs the P2 reconciler against a live agent's /healthz (or a fixture),
// reconciles observed-vs-expected count indices, optionally rewrites the
// descriptor's inferred rows to confirmed, and records the verdict. The stage is
// DONE only when the scope is cutover-ready; otherwise it lands BLOCKED with the
// blocking reasons in the detail, so status shows exactly what remains.
func (l *Loop) Capture(opts CaptureOptions) (*Manifest, *capture.Report, error) {
	d, err := clientdescriptor.Load(l.DescriptorPath)
	if err != nil {
		return nil, nil, fmt.Errorf("capture: %w", err)
	}
	m, mpath, err := l.loadManifest(d.Tenant)
	if err != nil {
		return nil, nil, err
	}

	health, err := loadHealthz(opts.HealthzPath, opts.AgentURL, opts.Insecure)
	if err != nil {
		return nil, nil, fmt.Errorf("capture: %w", err)
	}
	if !health.Components.UnmappedTags.Verbose {
		fmt.Fprintf(l.out(), "capture: WARNING /healthz verbose=false — run the agent with AGENT_UNMAPPED_VERBOSE=true so unmapped_suffixes are enumerated.\n")
	}
	var accepted []string
	if opts.AcceptedPath != "" {
		if accepted, err = capture.LoadAcceptedFile(opts.AcceptedPath); err != nil {
			return nil, nil, fmt.Errorf("capture: %w", err)
		}
	}

	rep, err := capture.Reconcile(d, accepted, health, capture.Options{Only: opts.Only})
	if err != nil {
		return nil, nil, fmt.Errorf("capture: %w", err)
	}
	fmt.Fprint(l.out(), rep.Text())

	var appliedNote string
	if opts.Apply {
		applied, err := applyCaptures(l.DescriptorPath, rep)
		if err != nil {
			return nil, nil, err
		}
		if len(applied) > 0 {
			appliedNote = fmt.Sprintf("; applied %d correction(s) to descriptor", len(applied))
			fmt.Fprintf(l.out(), "\ncapture: rewrote %d count index(es) in %s → confidence: confirmed:\n", len(applied), l.DescriptorPath)
			for _, t := range applied {
				fmt.Fprintf(l.out(), "  - %s\n", t)
			}
			// Re-load to refresh inferred count after the in-place edit.
			if d2, err := clientdescriptor.Load(l.DescriptorPath); err == nil {
				m.InferredCount = len(d2.InferredMembers())
			}
		} else {
			fmt.Fprintf(l.out(), "\ncapture: descriptor already matches the wire — no changes applied.\n")
		}
	} else if frag := rep.Fragment(); frag != "" {
		fmt.Fprintf(l.out(), "\n%s", frag)
		fmt.Fprintf(l.out(), "# (dry-run — re-run with --apply to write these into the descriptor)\n")
	}

	scope := "all"
	if opts.Only != "" {
		scope = opts.Only
	}
	status := StatusBlocked
	detail := fmt.Sprintf("scope=%s NOT READY: %d blocking%s", scope, len(rep.Blocking), appliedNote)
	if rep.CutoverReady {
		status = StatusDone
		detail = fmt.Sprintf("scope=%s cutover-ready (%d confirmed)%s", scope, rep.Counts[capture.StateConfirmed], appliedNote)
	}
	m.CutoverReady = rep.CutoverReady && opts.Only == "" // whole-tenant readiness only
	m.set(StageCapture, status, detail)
	if err := m.Save(mpath); err != nil {
		return nil, nil, err
	}
	if rep.CutoverReady {
		fmt.Fprintf(l.out(), "\nnext: onboard validate — scope %q is cutover-ready.\n", scope)
	} else {
		fmt.Fprintf(l.out(), "\ncapture: scope %q NOT ready — resolve the %d blocking item(s) above, then re-capture.\n", scope, len(rep.Blocking))
	}
	return m, rep, nil
}

// ── ④ VALIDATE ────────────────────────────────────────────────────────────────

// ValidateOptions drives the VALIDATE stage. When observations are supplied
// (HealthzPath/AgentURL), the Mode-A capture parity check is run as an extra
// gate: the descriptor must reconcile cutover-ready against the live wire, not
// merely be internally all-confirmed.
type ValidateOptions struct {
	HealthzPath  string
	AgentURL     string
	Insecure     bool
	AcceptedPath string
}

// ValidateResult is the machine-readable outcome of the readiness gate.
type ValidateResult struct {
	AllConfirmed  bool     // no member still inferred (the §2.4b gate)
	CutoverBuilds bool     // Generate(Cutover:true) succeeds
	ParityChecked bool     // a live/fixture reconciliation was run
	ParityReady   bool     // that reconciliation was cutover-ready
	Inferred      []string // still-inferred member topics (empty ⇒ AllConfirmed)
	Green         bool     // the overall gate
}

// Validate runs the readiness gate that stands between an onboarded tenant and a
// cutover. Gates, in order:
//  1. ALL CONFIRMED — no member's count index is still inferred (§2.4b).
//  2. CUTOVER BUILDS — clientdescriptor.Generate(Cutover:true) succeeds (the same
//     refusal the CLI enforces, exercised here so VALIDATE is the single gate).
//  3. MODE-A PARITY (only if observations supplied) — the descriptor reconciles
//     cutover-ready against the live agent's wire.
//
// It never mutates anything. Green requires (1) ∧ (2) ∧ (parity ⇒ ready).
func (l *Loop) Validate(opts ValidateOptions) (*Manifest, *ValidateResult, error) {
	d, err := clientdescriptor.Load(l.DescriptorPath)
	if err != nil {
		return nil, nil, fmt.Errorf("validate: %w", err)
	}
	m, mpath, err := l.loadManifest(d.Tenant)
	if err != nil {
		return nil, nil, err
	}

	res := &ValidateResult{}
	res.Inferred = d.InferredMembers()
	res.AllConfirmed = len(res.Inferred) == 0

	if _, err := d.Generate(clientdescriptor.GenerateOptions{Cutover: true}); err == nil {
		res.CutoverBuilds = true
	}

	res.ParityReady = true // vacuously true until a check runs
	if opts.HealthzPath != "" || opts.AgentURL != "" {
		health, err := loadHealthz(opts.HealthzPath, opts.AgentURL, opts.Insecure)
		if err != nil {
			return nil, nil, fmt.Errorf("validate: %w", err)
		}
		var accepted []string
		if opts.AcceptedPath != "" {
			if accepted, err = capture.LoadAcceptedFile(opts.AcceptedPath); err != nil {
				return nil, nil, fmt.Errorf("validate: %w", err)
			}
		}
		rep, err := capture.Reconcile(d, accepted, health, capture.Options{})
		if err != nil {
			return nil, nil, fmt.Errorf("validate: %w", err)
		}
		res.ParityChecked = true
		res.ParityReady = rep.CutoverReady
	}

	res.Green = res.AllConfirmed && res.CutoverBuilds && res.ParityReady

	// Print the gate report.
	fmt.Fprintf(l.out(), "validate: tenant=%s\n", d.Tenant)
	fmt.Fprintf(l.out(), "  [%s] all count indices confirmed (%d inferred)\n", passFail(res.AllConfirmed), len(res.Inferred))
	fmt.Fprintf(l.out(), "  [%s] cutover-ready config builds\n", passFail(res.CutoverBuilds))
	if res.ParityChecked {
		fmt.Fprintf(l.out(), "  [%s] Mode-A capture parity (reconciles cutover-ready on the wire)\n", passFail(res.ParityReady))
	} else {
		fmt.Fprintf(l.out(), "  [ - ] Mode-A capture parity — not checked (no --healthz/--agent-url supplied)\n")
	}
	for _, t := range res.Inferred {
		fmt.Fprintf(l.out(), "    still inferred: %s\n", t)
	}

	status := StatusBlocked
	detail := "gate RED"
	if res.Green {
		status = StatusDone
		detail = "gate GREEN — cutover-eligible"
	}
	// CAPTURE is only REQUIRED to confirm inferred indices. A tenant authored
	// fully-confirmed needs no live capture, so a still-pending capture stage is
	// marked satisfied here rather than dangling as "next" forever.
	if res.AllConfirmed && m.Get(StageCapture).Status == StatusPending {
		m.set(StageCapture, StatusDone, "not required — all indices confirmed at describe")
	}
	m.CutoverReady = res.Green
	m.InferredCount = len(res.Inferred)
	m.set(StageValidate, status, detail)
	if err := m.Save(mpath); err != nil {
		return nil, nil, err
	}
	if res.Green {
		fmt.Fprintf(l.out(), "\nvalidate: GREEN — next: onboard cutover (prints the checklist; does not execute).\n")
	} else {
		fmt.Fprintf(l.out(), "\nvalidate: RED — resolve the failing gate(s) above (capture inferred indices), then re-validate.\n")
	}
	return m, res, nil
}

// ── ⑤ CUT OVER ────────────────────────────────────────────────────────────────

// Cutover PRINTS the exact cutover checklist. It NEVER executes a cutover. It is
// hard-gated: it re-derives readiness live (all-confirmed ∧ cutover config
// builds) AND requires VALIDATE to have been run green — belt and braces so a
// stale manifest can never open the gate. On a non-green tenant it refuses and
// names what blocks.
func (l *Loop) Cutover() (*Manifest, error) {
	d, err := clientdescriptor.Load(l.DescriptorPath)
	if err != nil {
		return nil, fmt.Errorf("cutover: %w", err)
	}
	m, mpath, err := l.loadManifest(d.Tenant)
	if err != nil {
		return nil, err
	}

	inferred := d.InferredMembers()
	_, buildErr := d.Generate(clientdescriptor.GenerateOptions{Cutover: true})
	validateGreen := m.Get(StageValidate).Status == StatusDone

	if len(inferred) > 0 || buildErr != nil || !validateGreen {
		m.set(StageCutover, StatusBlocked, "gate not green — refused")
		_ = m.Save(mpath)
		var why []string
		if len(inferred) > 0 {
			why = append(why, fmt.Sprintf("%d count index(es) still inferred", len(inferred)))
		}
		if buildErr != nil {
			why = append(why, "cutover-ready config does not build: "+truncate(buildErr.Error(), 80))
		}
		if !validateGreen {
			why = append(why, "VALIDATE has not passed green (run: onboard validate)")
		}
		return m, fmt.Errorf("cutover REFUSED (ADR-0045 §2.4b — no cutover on inferred data): %s", strings.Join(why, "; "))
	}

	fmt.Fprint(l.out(), cutoverChecklist(d, m.OutputDir))
	m.set(StageCutover, StatusDone, "checklist printed (execution is a deliberate manual PR)")
	if err := m.Save(mpath); err != nil {
		return nil, err
	}
	return m, nil
}

// Status loads + renders the manifest (the `onboard status` command).
func (l *Loop) Status() (*Manifest, error) {
	tenant := peekTenant(l.DescriptorPath)
	m, _, err := l.loadManifest(tenant)
	if err != nil {
		return nil, err
	}
	fmt.Fprint(l.out(), m.Render())
	return m, nil
}

// ── shared helpers ────────────────────────────────────────────────────────────

// loadHealthz resolves the observed set from a fixture path or a live agent GET.
func loadHealthz(healthzPath, agentURL string, insecure bool) (*capture.Healthz, error) {
	switch {
	case healthzPath != "" && agentURL != "":
		return nil, fmt.Errorf("--healthz and --agent-url are mutually exclusive")
	case healthzPath != "":
		return capture.LoadHealthzFile(healthzPath)
	case agentURL != "":
		return fetchHealthz(agentURL, insecure)
	default:
		return nil, fmt.Errorf("one of --healthz (fixture) or --agent-url (live) is required")
	}
}

func passFail(ok bool) string {
	if ok {
		return "PASS"
	}
	return "FAIL"
}

func truncate(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}
