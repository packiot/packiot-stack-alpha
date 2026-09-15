// Package derivesim is the shared "run a customization against sample data" core
// behind ADR-0058's simulate capability (P2.2 CLI + the /v1/onboard/simulate
// endpoint). It answers "what tags would this tenant's derive/expr rules produce
// for these inputs?" WITHOUT a live box — the engine a CS engineer's
// simulate-before-deploy preview sits on.
//
// It is deliberately tiny + pure (no I/O): build a deriver from a resolved
// profile, feed each sample through in arrival order (so cross-envelope latching
// behaves as in production), and collect every synthesized tag. Keeping this in
// one place means the CLI (cmd/derive-replay) and the HTTP endpoint can never
// drift in how they simulate.
package derivesim

import (
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/deriver"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// Emitted is one synthesized tag the deriver produced, tagged with the input
// whose arrival triggered it (so a preview can show cause → effect).
type Emitted struct {
	Metric     string `json:"metric"`
	Value      any    `json:"value"`
	TsMillis   int64  `json:"ts_millis"`
	AfterInput string `json:"after_input"`
}

// Run feeds samples (in order) through a deriver built from profile and returns
// every synthesized tag in emission order. A sample is processed as its own
// one-tag envelope, matching how a tee delivers a metric — so a sum/expr rule
// re-emits once every input it latches has been seen. A nil/empty-rule profile
// yields no output (the deriver is a no-op).
func Run(profile *tenantprofile.Profile, samples []rawtag.RawTag) []Emitted {
	d := deriver.New(profile)
	var out []Emitted
	for _, s := range samples {
		synth, _ := d.Process([]rawtag.RawTag{s})
		for _, e := range synth {
			out = append(out, Emitted{
				Metric:     e.Metric,
				Value:      e.Value,
				TsMillis:   e.TsMillis,
				AfterInput: s.Metric,
			})
		}
	}
	return out
}
