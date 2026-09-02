// Package onboard is the ADR-0045 P3 CLIENT-ONBOARDING ORCHESTRATOR — the
// guided, self-service flow that wraps the P1 generator (clientdescriptor) and
// the P2 capture reconciler (capture) into ONE tool a Customer Success engineer
// drives end-to-end, without hand-editing any of the four downstream artifacts.
//
// The five stages (ADR-0045 §2.5)
// -------------------------------
//
//	① DESCRIBE   scaffold a client descriptor from a template (or validate one)
//	② GENERATE   run P1 → emit the four artifacts to a per-client output dir
//	③ CAPTURE    run P2 against a live agent's /healthz → reconcile indices →
//	             rewrite the descriptor's inferred count indices to confirmed
//	④ VALIDATE   the readiness gate: "all confirmed, no inferred" + a cutover-
//	             ready config that builds + (when observations are supplied) the
//	             Mode-A capture parity check
//	⑤ CUT OVER   PRINT the exact cutover checklist — never executes; hard-gated
//	             on VALIDATE being green
//
// Why an orchestrator and not five separate CLIs
// ----------------------------------------------
// P1 (cmd/onboard-gen) and P2 (cmd/onboard-capture) each do one stage well, but
// a CS engineer running an onboarding has to remember the ORDER, carry the
// confirmed-vs-inferred state between steps in their head, and know which gate
// blocks a cutover. This package makes that state a PERSISTED MANIFEST and the
// order a state machine: every stage records where the tenant is, prints the
// next step, and refuses to skip a gate. The load-bearing invariant of the whole
// ADR — "no tenant cuts over on inferred data" (§2.4b) — is enforced here in code
// at the VALIDATE→CUT OVER seam, not left to discipline.
//
// It duplicates NO logic: DESCRIBE/GENERATE call clientdescriptor, CAPTURE calls
// capture, and the cutover gate reuses clientdescriptor.InferredMembers() +
// Generate(Cutover:true). The orchestrator is glue + state, not a reimplementation.
package onboard

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// Stage is one step of the onboarding flow.
type Stage string

const (
	StageDescribe Stage = "describe"
	StageGenerate Stage = "generate"
	StageCapture  Stage = "capture"
	StageValidate Stage = "validate"
	StageCutover  Stage = "cutover"
)

// Stages is the canonical order (ADR-0045 §2.5). Rendering + progress logic
// iterate this so the flow is presented consistently everywhere.
var Stages = []Stage{StageDescribe, StageGenerate, StageCapture, StageValidate, StageCutover}

// Status is a stage's recorded outcome.
type Status string

const (
	// StatusPending — the stage has not run (or a prior run left it incomplete).
	StatusPending Status = "pending"
	// StatusDone — the stage completed and its gate (if any) is green.
	StatusDone Status = "done"
	// StatusBlocked — the stage ran but a gate failed (e.g. inferred indices
	// remain). The flow cannot advance past a blocked stage.
	StatusBlocked Status = "blocked"
)

// StageRecord is one stage's persisted state.
type StageRecord struct {
	Stage  Stage     `json:"stage"`
	Status Status    `json:"status"`
	At     time.Time `json:"at,omitempty"`
	Detail string    `json:"detail,omitempty"`
}

// Manifest is the per-client onboarding state — the single source of truth for
// "where is this tenant in the flow?". It lives next to the descriptor as
// <tenant>.onboard.json and is rewritten after every stage.
type Manifest struct {
	Tenant         string        `json:"tenant"`
	EnterpriseID   int           `json:"enterprise_id"`
	DescriptorPath string        `json:"descriptor_path"`
	OutputDir      string        `json:"output_dir,omitempty"`
	Stages         []StageRecord `json:"stages"`
	// InferredCount is the count of still-inferred members at the last run — the
	// headline "how far from cutover" number.
	InferredCount int       `json:"inferred_count"`
	CutoverReady  bool      `json:"cutover_ready"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// nowFunc is the clock; overridable in tests for deterministic manifests.
var nowFunc = time.Now

// NewManifest seeds a manifest with every stage pending.
func NewManifest(tenant string, descriptorPath string) *Manifest {
	m := &Manifest{Tenant: tenant, DescriptorPath: descriptorPath}
	for _, s := range Stages {
		m.Stages = append(m.Stages, StageRecord{Stage: s, Status: StatusPending})
	}
	return m
}

// LoadManifest reads a manifest from disk, or returns a fresh one (all-pending)
// if the file does not exist — so the first stage of a new tenant just works.
func LoadManifest(path, tenant, descriptorPath string) (*Manifest, error) {
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return NewManifest(tenant, descriptorPath), nil
	}
	if err != nil {
		return nil, fmt.Errorf("onboard: read manifest %s: %w", path, err)
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("onboard: parse manifest %s: %w", path, err)
	}
	// Backfill any stage the on-disk manifest predates (forward-compat).
	m.ensureStages()
	return &m, nil
}

// ensureStages guarantees every canonical stage has a record, preserving order.
func (m *Manifest) ensureStages() {
	have := map[Stage]bool{}
	for _, r := range m.Stages {
		have[r.Stage] = true
	}
	ordered := make([]StageRecord, 0, len(Stages))
	byStage := map[Stage]StageRecord{}
	for _, r := range m.Stages {
		byStage[r.Stage] = r
	}
	for _, s := range Stages {
		if r, ok := byStage[s]; ok {
			ordered = append(ordered, r)
		} else {
			ordered = append(ordered, StageRecord{Stage: s, Status: StatusPending})
		}
	}
	m.Stages = ordered
}

// Save writes the manifest to disk (pretty JSON, trailing newline).
func (m *Manifest) Save(path string) error {
	m.UpdatedAt = nowFunc().UTC()
	out, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("onboard: marshal manifest: %w", err)
	}
	if err := os.WriteFile(path, append(out, '\n'), 0o644); err != nil {
		return fmt.Errorf("onboard: write manifest %s: %w", path, err)
	}
	return nil
}

// set records a stage's outcome (idempotent per stage; last write wins).
func (m *Manifest) set(stage Stage, status Status, detail string) {
	for i := range m.Stages {
		if m.Stages[i].Stage == stage {
			m.Stages[i].Status = status
			m.Stages[i].At = nowFunc().UTC()
			m.Stages[i].Detail = detail
			return
		}
	}
	m.Stages = append(m.Stages, StageRecord{Stage: stage, Status: status, At: nowFunc().UTC(), Detail: detail})
}

// Get returns a stage's record (StatusPending if somehow absent).
func (m *Manifest) Get(stage Stage) StageRecord {
	for _, r := range m.Stages {
		if r.Stage == stage {
			return r
		}
	}
	return StageRecord{Stage: stage, Status: StatusPending}
}

// NextStage returns the first stage that is not Done — i.e. what the CS engineer
// should run next. Returns "" when the whole flow is complete.
func (m *Manifest) NextStage() Stage {
	for _, s := range Stages {
		if m.Get(s).Status != StatusDone {
			return s
		}
	}
	return ""
}

// Render draws the human-readable status table (the `onboard status` output).
func (m *Manifest) Render() string {
	var b strings.Builder
	fmt.Fprintf(&b, "ADR-0045 onboarding — tenant=%s enterprise=%d\n", m.Tenant, m.EnterpriseID)
	fmt.Fprintf(&b, "descriptor: %s\n", m.DescriptorPath)
	if m.OutputDir != "" {
		fmt.Fprintf(&b, "artifacts:  %s\n", m.OutputDir)
	}
	fmt.Fprintf(&b, "\n%-4s %-10s %-9s  %s\n", "#", "stage", "status", "detail")
	fmt.Fprintf(&b, "%s\n", strings.Repeat("-", 72))
	for i, s := range Stages {
		r := m.Get(s)
		fmt.Fprintf(&b, "%-4s %-10s %-9s  %s\n",
			fmt.Sprintf("%d%s", i+1, stageGlyph(r.Status)), s, r.Status, r.Detail)
	}
	if next := m.NextStage(); next != "" {
		fmt.Fprintf(&b, "\nnext: %s\n", next)
	} else {
		fmt.Fprintf(&b, "\nflow complete — cutover checklist available (onboard cutover).\n")
	}
	return b.String()
}

// stageGlyph is a one-char status marker in the status table's index column.
func stageGlyph(s Status) string {
	switch s {
	case StatusDone:
		return "."
	case StatusBlocked:
		return "!"
	default:
		return " "
	}
}

// DefaultManifestPath derives the manifest path from the descriptor path: same
// directory, <tenant>.onboard.json. Keeping state next to the descriptor means a
// tenant's workspace is self-describing.
func DefaultManifestPath(descriptorPath, tenant string) string {
	dir := ""
	if i := strings.LastIndex(descriptorPath, "/"); i >= 0 {
		dir = descriptorPath[:i+1]
	}
	return dir + strings.ToLower(tenant) + ".onboard.json"
}

// sortedTopics is a small helper for stable detail strings.
func sortedTopics(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}
