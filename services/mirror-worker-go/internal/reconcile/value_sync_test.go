package reconcile

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
)

func fp(v float64) *float64 { return &v }

func TestComputeDelta_BothNonNull(t *testing.T) {
	prod := db.ProdRuntimeValues{NetProduction: fp(1781), GrossProduction: fp(1810)}
	staging := db.MappedActivePO{StagingNetProduction: fp(916), StagingGrossProduction: fp(920)}
	net, gross := computeDelta(prod, staging)
	if net != 865 {
		t.Errorf("net delta = %f, want 865", net)
	}
	if gross != 890 {
		t.Errorf("gross delta = %f, want 890", gross)
	}
}

func TestComputeDelta_StagingNULL_FirstSync(t *testing.T) {
	// Just after reconciler creates a PO, staging runtime hasn't been
	// touched yet — both NULL. Treat as 0, so first sync injects full
	// prod value.
	prod := db.ProdRuntimeValues{NetProduction: fp(2000), GrossProduction: fp(2010)}
	staging := db.MappedActivePO{StagingNetProduction: nil, StagingGrossProduction: nil}
	net, gross := computeDelta(prod, staging)
	if net != 2000 || gross != 2010 {
		t.Errorf("first-sync delta = (%f, %f), want (2000, 2010)", net, gross)
	}
}

func TestComputeDelta_ProdNULL_NoOp(t *testing.T) {
	// Edge case: prod runtime row exists but cron hasn't computed
	// net/gross yet (NULL). Returning 0 means we'll INSERT zero delta,
	// which the caller's "skip if both zero" branch elides — clean no-op.
	prod := db.ProdRuntimeValues{NetProduction: nil, GrossProduction: nil}
	staging := db.MappedActivePO{StagingNetProduction: fp(100), StagingGrossProduction: fp(100)}
	net, gross := computeDelta(prod, staging)
	if net != -100 || gross != -100 {
		t.Errorf("prod-null delta = (%f, %f), want (-100, -100)", net, gross)
	}
}

func TestComputeDelta_InSync_ZeroDelta(t *testing.T) {
	prod := db.ProdRuntimeValues{NetProduction: fp(500), GrossProduction: fp(505)}
	staging := db.MappedActivePO{StagingNetProduction: fp(500), StagingGrossProduction: fp(505)}
	net, gross := computeDelta(prod, staging)
	if net != 0 || gross != 0 {
		t.Errorf("in-sync delta = (%f, %f), want (0, 0)", net, gross)
	}
}

func TestComputeDelta_NegativeAllowed(t *testing.T) {
	// Prod operator can decrement via /api/production-orders/recalc; we
	// must forward the negative delta so cron's SUM corrects downward.
	prod := db.ProdRuntimeValues{NetProduction: fp(800)}
	staging := db.MappedActivePO{StagingNetProduction: fp(1000)}
	net, _ := computeDelta(prod, staging)
	if net != -200 {
		t.Errorf("negative delta = %f, want -200", net)
	}
}

func TestDerefOr(t *testing.T) {
	if derefOr(nil, 42) != 42 {
		t.Error("nil should return fallback")
	}
	v := 7.0
	if derefOr(&v, 42) != 7 {
		t.Error("non-nil should return value")
	}
}
