package clientdescriptor

import (
	"strings"
	"testing"
)

// fnNode builds a Node-RED function node with the given body.
func fnNode(id, code string) map[string]any {
	return map[string]any{"id": id, "type": "function", "func": code}
}

// TestCustomizationBounds is the ADR-0058 P2.3 governance proof: the descriptor
// authoring path enforces the ADR-0009 bounds on a Node-RED function node's body.
func TestCustomizationBounds(t *testing.T) {
	cases := []struct {
		name    string
		nodes   []map[string]any
		wantErr string // "" = must pass
	}{
		{
			name:  "small function passes",
			nodes: []map[string]any{fnNode("f1", "msg.payload = msg.payload * 2;\nreturn msg;")},
		},
		{
			name:  "non-function node is exempt from body bounds",
			nodes: []map[string]any{{"id": "h1", "type": "http request", "method": "GET"}},
		},
		{
			name:    "oversized function body is rejected",
			nodes:   []map[string]any{fnNode("big", strings.Repeat("x=1;\n", maxFunctionLines+5))},
			wantErr: "over the",
		},
		{
			name:    "inline fetch() is rejected",
			nodes:   []map[string]any{fnNode("net1", "const r = await fetch('http://x'); return msg;")},
			wantErr: "INLINE network",
		},
		{
			name:    "require('https') is rejected",
			nodes:   []map[string]any{fnNode("net2", "const https = require('https'); return msg;")},
			wantErr: "INLINE network",
		},
		{
			name:    "https.get is rejected",
			nodes:   []map[string]any{fnNode("net3", "https.get('http://x', cb); return msg;")},
			wantErr: "INLINE network",
		},
		{
			name:    "eval is rejected",
			nodes:   []map[string]any{fnNode("ev", "eval(msg.code); return msg;")},
			wantErr: "eval",
		},
		{
			name:    "new Function is rejected",
			nodes:   []map[string]any{fnNode("nf", "const f = new Function('return 1'); return msg;")},
			wantErr: "eval",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateCustomizations(tc.nodes)
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("want pass, got: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("want error containing %q, got nil", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.wantErr)
			}
		})
	}
}
