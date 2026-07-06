package reports

import (
	"context"
	_ "embed"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// Sap13 ports prod's upsert_sap_report_data_sync_customer_13() — the
// last ADR-0012 Wave 2 family (port #3, sequenced LAST per the
// execution plan). The 580-line body is a single INSERT…WITH…ON
// CONFLICT statement, verbatim-embedded (sync06 archetype): Go owns
// scheduling/config/observability, the set-based SQL stays SQL.
//
// Three transforms only (see sap13_body.sql header): pool write
// target, customer_id injection, pool conflict key
// (customer_id, linie, tag, shicht, auftrag_key).
//
// COORDINATION CONTRACT (issue #223): back4-api's neopac
// data-sync.controller.js co-writes this dataset and must target the
// pool key at cutover. Until that lands, this job ships DISABLED
// (SAP13_REPORT_ENABLED=false) — flipping it on is the back4-api
// owner's call, not a deploy side effect.
//
//go:embed sap13_body.sql
var sap13Body string

// RunSap13 executes one upsert pass. Returns rows upserted.
func RunSap13(ctx context.Context, pool *pgxpool.Pool, customerID int) (int64, error) {
	sql := strings.ReplaceAll(sap13Body, "__CUSTOMER_ID__", strconv.Itoa(customerID))
	ct, err := pool.Exec(ctx, sql)
	if err != nil {
		return 0, err
	}
	return ct.RowsAffected(), nil
}

// LoopSap13 runs the writer on a fixed cadence until ctx cancels.
// Prod cadence is unreadable (cron.job denied to awslambda); the
// body's own 5-day upsert window makes any minutes-scale interval
// safe. 15 minutes mirrors shift06's staging default.
func LoopSap13(ctx context.Context, pool *pgxpool.Pool, customerID int, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("sap13 report writer started (Wave 2 port #3 — gated on #223)")
	jobs.Loop(ctx, jobs.Job{Name: "sap13", Every: every, Run: func(ctx context.Context) error {
		_, err := RunSap13(ctx, pool, customerID)
		return err
	}}, logger, obs)
}
