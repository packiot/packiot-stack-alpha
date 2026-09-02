// sync06.go — ADR-0014 P4: the enterprise-6 production data sync,
// ported with MAXIMUM fidelity: the captured prod function body
// (update_piot_table_production_data_sync_enterprise_06, 2026-07-03)
// is embedded VERBATIM and executed as one multi-statement command —
// Postgres runs it in one implicit transaction, matching the PL/pgSQL
// function's single-tx semantics exactly. Go owns only scheduling +
// observability (the ADR-0014 rule: set-based SQL stays SQL).
//
// The body is a 9-condition transaction-status state machine
// (trans_status N/D, to_delete, numbered `logics` audit column) fed
// by get_data_sync_enterprsie_06b(21) — call-time-verified on prod
// (1,194 rows) before this port, per the dead-generation rule.
//
// POOL DECISION (recorded): the target keeps its legacy name —
// pool-ization is deferred to the wave step shared with sap_13, since
// both sync tables face the same external-consumer contract question.
// Behavior today is 1:1 with prod.
package reports

import (
	"context"
	_ "embed"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

//go:embed sync06_body.sql
var sync06BodyRaw string

// sync06Body renders the captured body for a tenant. At the default
// (enterprise 6, legacy target) the output is BIT-IDENTICAL to the
// verbatim capture — substitution only diverges when config diverges
// (the no-hardcoded-enterprise-ids directive).
func sync06Body(enterpriseID int, target string) string {
	b := sync06BodyRaw
	if enterpriseID != 6 {
		b = strings.ReplaceAll(b, "id_enterprise = 6", fmt.Sprintf("id_enterprise = %d", enterpriseID))
		b = strings.ReplaceAll(b, "get_data_sync_enterprsie_06b(21)", fmt.Sprintf("get_data_sync_enterprsie_%02db(21)", enterpriseID))
	}
	if target != "" && target != "production_data_sync_enterprise_06" {
		b = strings.ReplaceAll(b, "production_data_sync_enterprise_06", target)
	}
	return b
}

// RunSync06 executes one full state-machine pass. The multi-statement
// string runs under the simple protocol as ONE implicit transaction.
func RunSync06(ctx context.Context, pool *pgxpool.Pool, enterpriseID int, target string) error {
	if _, err := pool.Exec(ctx, sync06Body(enterpriseID, target)); err != nil {
		return fmt.Errorf("sync06 pass: %w", err)
	}
	return nil
}

// LoopSync06 schedules the pass (main flow only — the compute reads
// public base tables; shadow-flow pooling arrives with the sap_13
// wave step).
func LoopSync06(ctx context.Context, pool *pgxpool.Pool, enterpriseID int, target string, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("sync06 writer started (ADR-0014 P4 — verbatim-embedded state machine)")
	jobs.Loop(ctx, jobs.Job{Name: "sync06", Every: every, Run: func(ctx context.Context) error {
		return RunSync06(ctx, pool, enterpriseID, target)
	}}, logger, obs)
}
