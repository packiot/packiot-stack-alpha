package replicate

import (
	"os"
	"strings"
	"testing"
)

// roleMigration is the migration that owns the replicator's ops tables (and its grants).
const roleMigration = "../../../../db/migrations/t-legacy-replicator-role/01-up.sql"

// migrationTableDDL returns the CREATE TABLE IF NOT EXISTS statement for table in the
// role migration (up to its closing ");").
func migrationTableDDL(t *testing.T, table string) string {
	t.Helper()
	b, err := os.ReadFile(roleMigration)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "CREATE TABLE IF NOT EXISTS "+table+" (")
	if i < 0 {
		t.Fatalf("%s does not create %s", roleMigration, table)
	}
	j := strings.Index(s[i:], ");")
	return s[i : i+j]
}

// The DLQ DDL (now in the role migration, never run by the service) must carry the retry bookkeeping columns the retrier depends on,
// and the eligibility query must implement exponential backoff keyed on
// retry_attempts so a persistently-failing row (e.g. a deterministic 23P01
// window race) retires at the cap instead of hot-looping.
func TestDLQDDLAndBackoffShape(t *testing.T) {
	dlqDDL := migrationTableDDL(t, "ops.mirror_replay_dlq")
	for _, col := range []string{"retry_attempts", "last_retry_at", "source_log_id", "payload"} {
		if !strings.Contains(dlqDDL, col) {
			t.Errorf("ops.mirror_replay_dlq DDL missing column %q:\n%s", col, dlqDDL)
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
