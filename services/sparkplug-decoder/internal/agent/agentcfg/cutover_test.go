package agentcfg

import (
	"errors"
	"testing"
)

// TestSelectTagMapSource is the ADR-0045 Phase-2a cutover-flip policy proof: the
// per-tenant tag-map source must follow "global env override > per-tenant
// client_descriptors.status", and every non-cutover / error path must fail
// SAFE to the static YAML map (UseRegister=false) — a flip only ever happens on
// a definite signal, and a broken descriptor read never flips or crashes.
func TestSelectTagMapSource(t *testing.T) {
	readErr := errors.New("relation \"client_descriptors\" does not exist")

	tests := []struct {
		name        string
		envOverride bool
		status      string
		statusErr   error
		wantUse     bool
		wantReason  string
	}{
		{
			name:        "env override wins — register-driven regardless of status",
			envOverride: true,
			status:      "draft", // ignored — override short-circuits
			wantUse:     true,
			wantReason:  ReasonEnvOverride,
		},
		{
			name:        "env override wins even over a descriptor read error",
			envOverride: true,
			statusErr:   readErr,
			wantUse:     true,
			wantReason:  ReasonEnvOverride,
		},
		{
			name:       "status=cutover → register-driven",
			status:     StatusCutover,
			wantUse:    true,
			wantReason: ReasonDescriptorCutover,
		},
		{
			name:       "status=draft → static fallback (pre-cutover lifecycle)",
			status:     "draft",
			wantUse:    false,
			wantReason: "descriptor_status_draft",
		},
		{
			name:       "status=validated → static fallback (validated but not flipped)",
			status:     "validated",
			wantUse:    false,
			wantReason: "descriptor_status_validated",
		},
		{
			name:       "no descriptor row → static fallback",
			status:     "",
			wantUse:    false,
			wantReason: ReasonDescriptorAbsent,
		},
		{
			name:       "read error → SAFE static fallback (never a flip)",
			statusErr:  readErr,
			wantUse:    false,
			wantReason: ReasonDescriptorError,
		},
		{
			name:       "read error beats a stale non-empty status (checked before the switch)",
			status:     StatusCutover, // must NOT flip: the read errored
			statusErr:  readErr,
			wantUse:    false,
			wantReason: ReasonDescriptorError,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := SelectTagMapSource(tc.envOverride, tc.status, tc.statusErr)
			if got.UseRegister != tc.wantUse {
				t.Errorf("UseRegister = %v, want %v", got.UseRegister, tc.wantUse)
			}
			if got.Reason != tc.wantReason {
				t.Errorf("Reason = %q, want %q", got.Reason, tc.wantReason)
			}
		})
	}
}
