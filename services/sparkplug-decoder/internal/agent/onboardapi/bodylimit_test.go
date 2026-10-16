package onboardapi

import (
	"bytes"
	"net/http"
	"strings"
	"testing"
)

// A body over MaxBodyBytes is 413 (not 400) on both routes, with the usual
// {"error":"payload too large"} body.
func TestOversizedBody413(t *testing.T) {
	s := New(Config{APIKey: testKey, MaxBodyBytes: 64}, nil, nil)
	big := bytes.Repeat([]byte("a"), 200)
	for _, path := range []string{"/v1/onboard/generate", "/v1/onboard/simulate"} {
		rec := postJSON(t, s, path, testKey, big)
		if rec.Code != http.StatusRequestEntityTooLarge {
			t.Errorf("%s: status %d, want 413 (body %q)", path, rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), "payload too large") {
			t.Errorf("%s: body %q, want payload too large", path, rec.Body.String())
		}
	}
}
