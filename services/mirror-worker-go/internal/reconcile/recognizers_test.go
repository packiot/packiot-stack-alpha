// recognizers_test.go — unit tests for the edge-api error-message
// recognizers the reconciler uses to detect "intent already satisfied"
// shapes on create/start. Same shape as the replay package's
// httputil_test.go but covers the reconciler's local copies.
package reconcile

import (
	"os"
	"strings"
	"testing"
)

func TestIsAlreadyExists(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{
			name: "exact JSON match without bang",
			body: `{"statusCode":400,"message":"Production order already exists"}`,
			want: true,
		},
		{
			name: "exact JSON match with bang",
			body: `{"statusCode":400,"message":"Production order already exists!"}`,
			want: true,
		},
		{
			name: "plain-text body without bang",
			body: `Production order already exists`,
			want: true,
		},
		{
			name: "plain-text body with bang",
			body: `Production order already exists!`,
			want: true,
		},
		{
			name: "plain-text with trailing newline",
			body: "Production order already exists\n",
			want: true,
		},
		{
			name: "substring inside other text is NOT a match",
			body: `{"statusCode":400,"message":"validation: Production order already exists in another scope"}`,
			want: false,
		},
		{
			name: "different error message is NOT a match",
			body: `{"statusCode":400,"message":"Equipment does not exist"}`,
			want: false,
		},
		{
			name: "empty body",
			body: ``,
			want: false,
		},
		{
			name: "garbage HTML page is rejected by length cap",
			body: string(make([]byte, 300)),
			want: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := isAlreadyExists([]byte(c.body)); got != c.want {
				t.Errorf("isAlreadyExists(%q) = %v, want %v", c.body, got, c.want)
			}
		})
	}
}

func TestIsAlreadyRunning(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{
			name: "exact JSON match",
			body: `{"statusCode":400,"message":"Production order already running"}`,
			want: true,
		},
		{
			name: "plain-text body",
			body: `Production order already running`,
			want: true,
		},
		{
			name: "plain-text with trailing newline",
			body: "Production order already running\n",
			want: true,
		},
		{
			name: "different exclamation variant is NOT a match (literal-only)",
			body: `{"statusCode":400,"message":"Production order already running!"}`,
			want: false,
		},
		{
			name: "substring inside validation message is NOT a match",
			body: `{"statusCode":400,"message":"validation: Production order already running on a different equipment"}`,
			want: false,
		},
		{
			name: "already-exists message does NOT match running",
			body: `{"statusCode":400,"message":"Production order already exists"}`,
			want: false,
		},
		{
			name: "empty body",
			body: ``,
			want: false,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := isAlreadyRunning([]byte(c.body)); got != c.want {
				t.Errorf("isAlreadyRunning(%q) = %v, want %v", c.body, got, c.want)
			}
		})
	}
}

// TestReviveExistingStagingPO_SourceInvariants pins the load-bearing
// behavior of reviveExistingStagingPO at the source level — same shape
// as the SQL invariant guards on the translator and reanimator. If a
// future refactor accidentally removes one of these properties, the
// reconciler would silently revert to the pre-fix WARN-loop behavior
// when prod runs an active PO whose staging mirror has finished.
//
// Pinned: (a) recognizer is wired on create error, (b) revive helper is
// called when recognizer matches, (c) /start already-running response
// is swallowed inside the revive path. Implementation lives in
// reconciler.go reviveExistingStagingPO + the ensureOnePO branch.
func TestReviveExistingStagingPO_SourceInvariants(t *testing.T) {
	src, err := os.ReadFile("reconciler.go")
	if err != nil {
		t.Fatalf("read reconciler.go: %v", err)
	}
	body := string(src)

	wantSubs := []struct {
		needle string
		why    string
	}{
		{
			"isAlreadyExists(body)",
			"ensureOnePO must call isAlreadyExists on the create-error body so the revive branch fires; without this the reconciler reverts to the pre-fix WARN-loop on every tick when a prod active PO has a finished staging mirror at the same id_order",
		},
		{
			"r.reviveExistingStagingPO(ctx",
			"ensureOnePO must call reviveExistingStagingPO when isAlreadyExists matches — the recognizer alone doesn't fix anything; the recovery is the whole point",
		},
		{
			"isAlreadyRunning(body)",
			"reviveExistingStagingPO must call isAlreadyRunning on the start-error body so a /start to an already-active PO doesn't fail the whole revive (race surface: value-sync flipped status to 2 between our lookup and the start POST)",
		},
		{
			"LookupStagingPOByIDOrder",
			"reviveExistingStagingPO must look up the existing staging PO by id_order — that's how we discover the row to revive without already having its id from the diff loop",
		},
	}
	for _, w := range wantSubs {
		if !strings.Contains(body, w.needle) {
			t.Errorf("reconciler.go missing revive invariant %q — %s", w.needle, w.why)
		}
	}
}
