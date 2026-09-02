// config_test.go — guards the reconciler-split rollback contract: the new
// scheduler knobs MUST default to the pre-split behavior so RECONCILE_MODE
// unset is a byte-for-byte-behavior no-op, and an unrecognized mode falls
// back to poll rather than silently dropping the finisher / busy-looping.
package config

import "testing"

// withEnv sets envs for one test and restores them after. Kept local so the
// test file needs no external helper and stays hermetic under `go test`.
func withEnv(t *testing.T, kv map[string]string) {
	t.Helper()
	for k, v := range kv {
		t.Setenv(k, v)
	}
}

func TestReconcileScheduler_DefaultsMatchPreSplit(t *testing.T) {
	// PROD/STAGING enterprise ids are required by Load's sanity checks; set
	// them so we can exercise the reconciler knobs in isolation.
	withEnv(t, map[string]string{
		"PROD_ENTERPRISE_ID":    "1",
		"STAGING_ENTERPRISE_ID": "3",
	})
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.ReconcileMode != ReconcileModePoll {
		t.Errorf("default mode = %q, want %q (pre-split behavior)", cfg.ReconcileMode, ReconcileModePoll)
	}
	if cfg.ReconcileCreateIntervalSec != 3 {
		t.Errorf("default create interval = %d, want 3", cfg.ReconcileCreateIntervalSec)
	}
	if cfg.ReconcileFinisherIntervalSec != 300 {
		t.Errorf("default finisher interval = %d, want 300", cfg.ReconcileFinisherIntervalSec)
	}
	if cfg.ReconcileIntervalSec != 300 {
		t.Errorf("default combined interval = %d, want 300", cfg.ReconcileIntervalSec)
	}
}

func TestReconcileScheduler_TailModeOverrides(t *testing.T) {
	withEnv(t, map[string]string{
		"PROD_ENTERPRISE_ID":              "1",
		"STAGING_ENTERPRISE_ID":           "3",
		"RECONCILE_MODE":                  "tail",
		"RECONCILE_CREATE_INTERVAL_SEC":   "3",
		"RECONCILE_FINISHER_INTERVAL_SEC": "300",
	})
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.ReconcileMode != ReconcileModeTail {
		t.Errorf("mode = %q, want %q", cfg.ReconcileMode, ReconcileModeTail)
	}
}

func TestReconcileScheduler_UnknownModeFallsBackToPoll(t *testing.T) {
	withEnv(t, map[string]string{
		"PROD_ENTERPRISE_ID":    "1",
		"STAGING_ENTERPRISE_ID": "3",
		"RECONCILE_MODE":        "streaming", // typo / unsupported
	})
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.ReconcileMode != ReconcileModePoll {
		t.Errorf("unknown mode should fall back to %q, got %q", ReconcileModePoll, cfg.ReconcileMode)
	}
}

func TestReconcileScheduler_ZeroIntervalsGuarded(t *testing.T) {
	withEnv(t, map[string]string{
		"PROD_ENTERPRISE_ID":              "1",
		"STAGING_ENTERPRISE_ID":           "3",
		"RECONCILE_CREATE_INTERVAL_SEC":   "0",
		"RECONCILE_FINISHER_INTERVAL_SEC": "0",
	})
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.ReconcileCreateIntervalSec < 1 {
		t.Errorf("create interval must be guarded >=1, got %d", cfg.ReconcileCreateIntervalSec)
	}
	if cfg.ReconcileFinisherIntervalSec < 1 {
		t.Errorf("finisher interval must be guarded >=1, got %d", cfg.ReconcileFinisherIntervalSec)
	}
}
