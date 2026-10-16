// sync06.go — ADR-0014 P4: the enterprise-6 production data sync. The
// body is a 9-condition transaction-status state machine (trans_status
// N/D, to_delete, numbered `logics` audit column) embedded as one
// multi-statement command — Postgres runs it in one implicit
// transaction, matching the PL/pgSQL function's single-tx semantics
// exactly. Go owns only scheduling + observability (the ADR-0014 rule:
// set-based SQL stays SQL).
//
// t244 (enterprise-06/13 parameterization redesign, Phase 4). Two
// changes kill the last per-enterprise debt in this writer:
//
//  1. READ side — the state machine now sources from the GENERIC
//     serving.data_sync(p_id_enterprise, p_numdays) function instead of
//     the per-enterprise-cloned get_data_sync_enterprsie_06b(21). This
//     DELETES the string-templating anti-pattern (the old code did
//     ReplaceAll("...enterprsie_06b(21)", "...enterprsie_%02db(21)") to
//     presume a cloned _09b/_33b function existed per tenant). The
//     enterprise is now a REAL function argument.
//
//  2. WRITE side — the target is the multi-tenant pool
//     customer_reports.production_data_sync (customer_id discriminator),
//     mirroring the speed/shift/sap pool pattern, instead of the
//     per-enterprise-named production_data_sync_enterprise_06. Every
//     read/update of the pool is fenced by customer_id, and every
//     INSERT stamps customer_id, so tenants share one table safely.
//
// PARAMETER DELIVERY: this is a MULTI-statement command, so pool.Exec
// runs it under the SIMPLE protocol — pgx cannot bind $N placeholders
// across multiple statements (extended-protocol Bind is single-statement
// only). So the enterprise id is injected as an integer literal via the
// __ENTERPRISE__ token — the SAME convention the sibling sap13 writer
// uses (__CUSTOMER_ID__). It is an int, never user input, so injection
// is safe. The anti-pattern that mattered — cloning the FUNCTION NAME
// per tenant — is gone; serving.data_sync serves every tenant.
package reports

import (
	"context"
	_ "embed"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

//go:embed sync06_body.sql
var sync06BodyRaw string

// sync06Body renders the state machine for a tenant by substituting the
// enterprise id for the __ENTERPRISE__ token (serving.data_sync arg,
// customer_id fences, and the production_orders/equipments id_enterprise
// joins). See the file header for why literal injection (not a bound $N)
// is required for this multi-statement command.
func sync06Body(enterpriseID int) string {
	return strings.ReplaceAll(sync06BodyRaw, "__ENTERPRISE__", strconv.Itoa(enterpriseID))
}

// RunSync06 executes one full state-machine pass. The multi-statement
// string runs under the simple protocol as ONE implicit transaction.
func RunSync06(ctx context.Context, pool *pgxpool.Pool, enterpriseID int) error {
	if _, err := pool.Exec(ctx, sync06Body(enterpriseID)); err != nil {
		return fmt.Errorf("sync06 pass: %w", err)
	}
	return nil
}

// LoopSync06 schedules the pass (main flow only — the compute reads via
// serving.data_sync; the pool write target is customer_reports.production_data_sync).
func LoopSync06(ctx context.Context, pool *pgxpool.Pool, enterpriseID int, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("sync06 writer started (t244 — serving.data_sync + customer_reports.production_data_sync pool)")
	jobs.Loop(ctx, jobs.Job{Name: "sync06", Every: every, Run: func(ctx context.Context) error {
		return RunSync06(ctx, pool, enterpriseID)
	}}, logger, obs)
}
