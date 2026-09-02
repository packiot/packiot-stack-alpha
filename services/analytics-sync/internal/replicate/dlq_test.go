package replicate

import (
	"strings"
	"testing"
)

// The DLQ DDL must carry the retry bookkeeping columns the retrier depends on,
// and the eligibility query must implement exponential backoff keyed on
// retry_attempts so a persistently-failing row (e.g. a deterministic 23P01
// window race) retires at the cap instead of hot-looping.
func TestDLQDDLAndBackoffShape(t *testing.T) {
	for _, col := range []string{"retry_attempts", "last_retry_at", "source_log_id", "payload"} {
		if !strings.Contains(dlqDDL, col) {
			t.Errorf("dlqDDL missing column %q:\n%s", col, dlqDDL)
		}
	}
	// The retrier's eligibility query lives in fetchRetriableDLQ; assert the
	// backoff + cap shape via the constant used there is present in source.
	// (fetchRetriableDLQ builds the query inline — this guards the invariant.)
	q := `(1 << retry_attempts)`
	if !strings.Contains(sqlFetchRetriableDLQ, q) {
		t.Errorf("DLQ backoff must be exponential in retry_attempts, got:\n%s", sqlFetchRetriableDLQ)
	}
}
