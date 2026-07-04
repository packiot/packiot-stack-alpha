// provision.go — runtime-provision (ledger name): the future
// pre-provisioning matrix (17 piot_create_*_runtime functions:
// entity × grain bucket rows created ahead — 30 days of hourly/daily/
// weekly/monthly/shift buckets with targets and tz day-anchors).
//
// TRANSITIONAL STRATEGY (recorded in the naming ledger): the legacy
// functions are executed VERBATIM against each flow via the
// search_path mechanism the parity harness proved (PL/pgSQL resolves
// unqualified names at execution). Zero transcription risk for pure
// provisioning periphery; the rollup MATH gets real ports. The
// eventual deep-port replaces this file with a set-based matrix.
//
// Cadence: prod gates these behind minute>58 (hourly) — the jobs
// runner gets an hourly interval, same effect.
//
// GUARDRAIL STATEMENT: INSERT ... ON CONFLICT DO NOTHING bucket rows
// only (plus 1hour's target-preserving upsert) — no PO tables.
package rollup

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// The 17-function matrix, prod order (equipment → area → site).
var provisionFns = []string{
	"piot_create_equipment_runtime_1hour",
	"piot_create_equipment_runtime_1day",
	"piot_create_equipment_runtime_1week",
	"piot_create_equipment_runtime_1month",
	"piot_create_equipment_runtime_shift",
	"piot_create_equipment_runtime_shift_1week",
	"piot_create_equipment_runtime_shift_1month",
	"piot_create_area_runtime_1hour",
	"piot_create_area_runtime_1day",
	"piot_create_area_runtime_1week",
	"piot_create_area_runtime_1month",
	"piot_create_area_runtime_shift",
	"piot_create_site_runtime_1hour",
	"piot_create_site_runtime_1day",
	"piot_create_site_runtime_1week",
	"piot_create_site_runtime_1month",
	"piot_create_site_runtime_shift",
}

// RunProvision executes the matrix for one destination: one session,
// search_path = flow schema first (fail-soft per function — prod's
// dispatcher wraps each create in its own EXCEPTION block).
func RunProvision(ctx context.Context, d flows.Dest, logger *slog.Logger) error {
	conn, err := d.Pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, fmt.Sprintf(`SET search_path TO %s, public`, d.EvSchema)); err != nil {
		return fmt.Errorf("search_path: %w", err)
	}
	defer conn.Exec(context.WithoutCancel(ctx), `RESET search_path`)
	var firstErr error
	for _, fn := range provisionFns {
		if _, err := conn.Exec(ctx, `SELECT `+fn+`()`); err != nil {
			// fail-soft per function, prod-dispatcher semantics
			logger.Warn("runtime-provision fn failed",
				slog.String("dest", d.Name), slog.String("fn", fn), slog.String("err", err.Error()))
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
}

// LoopProvision schedules runtime-provision hourly.
func LoopProvision(ctx context.Context, dests []flows.Dest, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("runtime-provision started (P3b matrix, transitional search_path strategy)")
	jobs.Loop(ctx, jobs.Job{Name: "runtime-provision", Every: time.Hour, Timeout: 30 * time.Minute, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			if err := RunProvision(ctx, d, logger); err != nil && firstErr == nil {
				firstErr = err
			}
		}
		return firstErr
	}}, logger, obs)
}
