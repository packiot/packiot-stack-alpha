package onboard

import (
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/capture"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/clientdescriptor"
)

// peekTenant reads ONLY the tenant field from a descriptor without running the
// full validator — used to resolve the manifest path even for a not-yet-valid
// (scaffolded, half-filled) descriptor. Returns "" if unreadable; callers use it
// only to name the manifest file.
func peekTenant(path string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var head struct {
		Tenant string `yaml:"tenant"`
	}
	if err := yaml.Unmarshal(raw, &head); err != nil {
		return ""
	}
	return strings.TrimSpace(head.Tenant)
}

// fetchHealthz does a read-only GET of <base>/healthz (the live CAPTURE source).
// It mirrors cmd/onboard-capture's fetcher: a non-200 body is still parsed (the
// agent returns 503 when any component is degraded; unmapped tags never degrade
// health but another component might).
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

// cutoverChecklist renders the exact, ordered cutover runbook for a validated
// tenant. It is PRINTED, never executed — cutover is a deliberate, reviewed,
// reversible human action (a gated PR flipping flags), per ADR-0045 §2.5 ⑤ and
// the standing "no auto-cutover" rule. The generated artifacts in outDir are the
// inputs to these steps.
func cutoverChecklist(d *clientdescriptor.Descriptor, outDir string) string {
	if outDir == "" {
		outDir = "gen/" + strings.ToLower(d.Tenant)
	}
	low := strings.ToLower(d.Tenant)
	var b strings.Builder
	fmt.Fprintf(&b, "\n")
	fmt.Fprintf(&b, "═══ ADR-0045 ⑤ CUT OVER — %s (enterprise %d) ═══════════════════════════\n", d.Tenant, d.EnterpriseID)
	fmt.Fprintf(&b, "VALIDATE is GREEN: every count index confirmed, cutover config builds.\n")
	fmt.Fprintf(&b, "This is a CHECKLIST. It executes NOTHING. Cutover is a reviewed, reversible\n")
	fmt.Fprintf(&b, "PR that flips flags — flag back OFF restores static behaviour byte-for-byte.\n\n")

	fmt.Fprintf(&b, "Artifacts (generated, in %s):\n", outDir)
	fmt.Fprintf(&b, "  1. %s-profile.yaml    — tenant conversion profile\n", low)
	fmt.Fprintf(&b, "  2. %s-register.sql    — packml_register rows (topic ↔ id_equipment)\n", low)
	fmt.Fprintf(&b, "  3. %s-agent.yaml      — sparkplug-agent client.yaml (register-derived tag map)\n", low)
	fmt.Fprintf(&b, "  4. %s-tee-node.json   — Node-RED Tier-1 raw forwarder\n\n", low)

	fmt.Fprintf(&b, "Steps (each gated, reversible):\n")
	fmt.Fprintf(&b, "  [ ] a. Apply %s-register.sql to the DB (PR-reviewed; idempotent ON CONFLICT).\n", low)
	fmt.Fprintf(&b, "  [ ] b. Deploy sparkplug-agent-%s with %s-profile.yaml + %s-agent.yaml.\n", low, low, low)
	fmt.Fprintf(&b, "  [ ] c. Import %s-tee-node.json into the client's Node-RED; set env %s (ingest key).\n", low, ingestKeyEnv(d))
	fmt.Fprintf(&b, "  [ ] d. Confirm the tee is live: /healthz unmapped_suffixes is empty for expected equipment.\n")
	fmt.Fprintf(&b, "  [ ] e. Flip AGENT_TAGMAP_FROM_REGISTER=true (+ AGENT_PARAM_DECOMPOSITION=true if used) on the agent.\n")
	fmt.Fprintf(&b, "  [ ] f. Run the Mode-A parity bake (F3-from-agent == F3-from-prod) — the cutover gate.\n")
	fmt.Fprintf(&b, "  [ ] g. On parity green, announce cutover. To ROLL BACK: flip the flags OFF.\n\n")
	fmt.Fprintf(&b, "Do NOT proceed past a step whose gate is red. Re-run `onboard validate` after any\n")
	fmt.Fprintf(&b, "descriptor change; a change re-opens the inferred gate.\n")
	return b.String()
}

// ingestKeyEnv resolves the tee's ingest-key env var name the same way the P1
// generator does (descriptor value, else <TENANT>_INGEST_KEY).
func ingestKeyEnv(d *clientdescriptor.Descriptor) string {
	if d.Tee.IngestKeyEnv != "" {
		return d.Tee.IngestKeyEnv
	}
	return strings.ToUpper(d.Tenant) + "_INGEST_KEY"
}
