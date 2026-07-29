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

// ADR-0039 R5 CONTRACT Step 1 (task #12): dual-read of the NEOPAC downtime-reason
// category vocabulary. sap13_reasons_jsonb.sql is the EXACT byte copy of the CTE
// chain in sap13_body.sql (top_level -> category_level -> downtime_codes) that
// reads equipments.downtime_reasons jsonb; sap13_reasons_dim.sql is the normalized
// forward-path replacement that reads the R5 dimension (downtime_reason) + junction
// (equipment_downtime_reason). Both emit the same downtime_codes(position,
// description) contract, so every downstream CTE is untouched. The swap is applied
// at run time ONLY when reasonsFromDim is true — default false keeps the embedded
// body byte-identical (the verbatim ADR-0012 Wave-2 prod port). The jsonb column is
// NOT dropped this pass; see docs/adr/0039-reasons-dimension-contract-plan.md.
//
//go:embed sap13_reasons_jsonb.sql
var sap13ReasonsJSONB string

//go:embed sap13_reasons_dim.sql
var sap13ReasonsDim string

// RunSap13 executes one upsert pass. Returns rows upserted. When reasonsFromDim
// is true the downtime-reason vocabulary CTE is sourced from the R5 dimension +
// junction instead of the equipments.downtime_reasons jsonb (see the dual-read
// note above); false = the byte-identical jsonb path.
func RunSap13(ctx context.Context, pool *pgxpool.Pool, customerID int, reasonsFromDim bool) (int64, error) {
	sql := strings.ReplaceAll(sap13Body, "__CUSTOMER_ID__", strconv.Itoa(customerID))
	if reasonsFromDim {
		var err error
		if sql, err = swapReasonsToDim(sql); err != nil {
			return 0, err
		}
	}
	ct, err := pool.Exec(ctx, sql)
	if err != nil {
		return 0, err
	}
	return ct.RowsAffected(), nil
}

// swapReasonsToDim replaces the jsonb-sourced downtime-reason CTE chain with the
// dimension-sourced block. It FAILS LOUDLY if the expected jsonb block is absent
// (the verbatim body drifted) rather than silently running the jsonb path — a
// silent no-op here would defeat the migration and hide the drift.
func swapReasonsToDim(sql string) (string, error) {
	if !strings.Contains(sql, sap13ReasonsJSONB) {
		return "", fmt.Errorf("sap13: SAP13_REASONS_FROM_DIM set but the jsonb downtime-reason CTE block was not found in the body (sap13_body.sql drifted from sap13_reasons_jsonb.sql)")
	}
	return strings.Replace(sql, sap13ReasonsJSONB, sap13ReasonsDim, 1), nil
}

// LoopSap13 runs the writer on a fixed cadence until ctx cancels.
// Prod cadence is unreadable (cron.job denied to awslambda); the
// body's own 5-day upsert window makes any minutes-scale interval
// safe. 15 minutes mirrors shift06's staging default.
func LoopSap13(ctx context.Context, pool *pgxpool.Pool, customerID int, reasonsFromDim bool, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("sap13 report writer started (Wave 2 port #3 — gated on #223)", "reasons_from_dim", reasonsFromDim)
	jobs.Loop(ctx, jobs.Job{Name: "sap13", Every: every, Run: func(ctx context.Context) error {
		_, err := RunSap13(ctx, pool, customerID, reasonsFromDim)
		return err
	}}, logger, obs)
}
