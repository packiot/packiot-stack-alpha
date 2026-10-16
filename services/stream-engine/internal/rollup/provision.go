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
// Cadence: prod gates these behind minute>58 (hourly); the jobs runner
// uses RUNTIME_PROVISION_INTERVAL_HOURS from process start, i.e. an
// arbitrary minute. NOT the same effect for the legacy hourly function,
// whose day label depended on the run minute — hence provisionHourlySQL.
//
// HOURLY IS ENGINE-OWNED (2026-10-13, invariant K7): the hourly grain is
// no longer provisioned by the legacy piot_create_equipment_oee_hourly but by
// provisionHourlySQL below — see its comment for the production-day label bug
// that made the legacy function unsafe to run at an arbitrary minute.
//
// GUARDRAIL STATEMENT: INSERT ... ON CONFLICT DO NOTHING bucket rows
// only (plus the hourly target-preserving / label upsert) — no PO tables.
package rollup

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// The provision matrix, prod order (equipment → area → site).
//
// #224 (analytics clean-schema P4/P5): these call the canonical *_oee_* provision
// procs directly. The transitional PERFORM-new() shims under the old *_runtime_*
// names (created by the P4-step2 rename) are being contracted away — repointing the
// sole live caller here is the prerequisite for dropping those shims. The proc
// bodies are unchanged; only the name each entry resolves to moved runtime_->oee_.
//
// The hourly grain is NOT in this list: it runs first, as the engine-owned
// provisionHourlySQL (RunProvision), in place of piot_create_equipment_oee_hourly.
var provisionFns = []string{
	"piot_create_equipment_oee_daily",
	"piot_create_equipment_oee_weekly",
	"piot_create_equipment_oee_monthly",
	"piot_create_equipment_oee_shift",
	"piot_create_equipment_oee_shift_weekly",
	"piot_create_equipment_oee_shift_monthly",
	// #186: area/site 1hour/1week/1month provisioning removed with the retired
	// dead grains; only day + shift (+ all equipment grains) are provisioned now.
	"piot_create_area_oee_daily",
	"piot_create_area_oee_shift",
	// #263: piot_create_site_oee_daily removed — site_oee_daily dropped (unread). Site SHIFT kept.
	"piot_create_site_oee_shift",
}

// provisionHourlySQL — engine-owned replacement for the legacy
// public.piot_create_equipment_oee_hourly(): one set-based upsert of the next
// 723 hourly buckets (current hour + 722, the legacy horizon) for every
// equipment of an active enterprise with an area and a site.
//
// THE BUG IT FIXES (invariant K7, 2026-10-13). The legacy function computed the
// bucket's production day from `now() + i hours` WITHOUT truncating it to the
// hour (the bucket key itself WAS truncated), and its ON CONFLICT re-wrote
// ts_value_production on every run. For a tenant whose production day starts off
// the hour (CPACK/twin/Incoplast/119/120: day_begin = -3000 s → 23:10 local) the
// bucket that holds the day boundary ([23:00, 00:00) local) therefore got the
// label of whichever day the run's MINUTE fell in: before :10 → the old day,
// after → the new one. Legacy prod only ran it at minute > 58, so it was always
// the new day; the engine runs it every RUNTIME_PROVISION_INTERVAL_HOURS from
// process start — an arbitrary minute — so since ~09-01 production days carried
// 23 or 25 hour rows and up to an hour of production/availability moved between
// adjacent days. It also wrote a timestamptz into the date column (correct only
// because the session TimeZone is UTC).
//
// THE RULE (legacy semantics made explicit — the "minute-59 rule"): a bucket
// belongs to the production day that contains bucket_start + 59 minutes, i.e.
// the day that owns the bucket's last minute. For the 23:10 boundary that is the
// new day (50 of the bucket's 60 minutes); for a day that begins on the hour
// every minute of the bucket is in one day, so nothing changes there. The label
// is the date piot_get_day_begin_by_equipment returns (the same day-boundary
// function the day rollup, the day provisioner and the hour→day cascade use),
// so it is a pure function of the bucket: re-runs are idempotent and the run
// minute no longer matters.
//
// Upsert semantics: target is preserved exactly as legacy (refresh from
// production_targets unless operator-customized). The DO UPDATE ... WHERE skips
// rows where nothing changes — legacy rewrote all ~200k rows every run.
//
// $1 = the run's anchor instant; NULL = now(). Only tests pass a value (to
// simulate a run at a given minute).
const provisionHourlySQL = `
	INSERT INTO %[4]s.equipment_oee_hourly AS h (id_equipment, ts_value, target, ts_value_production)
	SELECT e.id_equipment, b.ts_value,
	       COALESCE((SELECT COALESCE(pt.vl_hour, pt.vl_day / 24) FROM %[6]s.production_targets pt
	                  WHERE pt.id_equipment = e.id_equipment), 0),
	       (SELECT db.ts_value_production
	          FROM piot_get_day_begin_by_equipment(e.id_equipment, b.ts_value + interval '59 minutes') db LIMIT 1)
	  FROM %[2]s.equipments e
	  JOIN %[2]s.enterprises et ON et.id_enterprise = e.id_enterprise AND et.active
	  JOIN %[2]s.sites s ON s.id_site = e.id_site
	 CROSS JOIN generate_series(date_trunc('hour', COALESCE($1::timestamptz, now())),
	                            date_trunc('hour', COALESCE($1::timestamptz, now())) + interval '722 hours',
	                            interval '1 hour') AS b(ts_value)
	 WHERE e.id_area IS NOT NULL AND e.id_site IS NOT NULL
	ON CONFLICT (id_equipment, ts_value) DO UPDATE SET
	       target = CASE WHEN h.target_customized = false AND (h.target <> EXCLUDED.target OR h.target IS NULL)
	                     THEN EXCLUDED.target ELSE h.target END,
	       ts_value_production = EXCLUDED.ts_value_production
	 WHERE (h.target_customized = false AND (h.target <> EXCLUDED.target OR h.target IS NULL))
	    OR h.ts_value_production IS DISTINCT FROM EXCLUDED.ts_value_production`

// provisionHourlyStmt renders provisionHourlySQL for a destination.
func provisionHourlyStmt(d flows.Dest) string {
	return fmtRD(provisionHourlySQL, d, d.ConfigSchema)
}

// RunProvision executes the matrix for one destination: one session,
// search_path = the canonical medallion path (fail-soft per function —
// prod's dispatcher wraps each create in its own EXCEPTION block).
// The piot_create_*_oee_* provision fns have no own search_path and
// reference the grain tables by BARE name (e.g. INSERT INTO
// equipment_oee_shift), so gold/silver/core MUST precede public — else
// the bare refs resolve to the public compat SHIMS (which are being
// retired) instead of the real medallion tables. This mirrors the DB
// role/database default search_path exactly.
func RunProvision(ctx context.Context, d flows.Dest, logger *slog.Logger) error {
	conn, err := d.Pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SET search_path TO gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public`); err != nil {
		return fmt.Errorf("search_path: %w", err)
	}
	// Provision is allowed to be slow (hourly cadence, 30min job
	// timeout guards the tick) — the session default statement_timeout
	// killed the 185-iteration shift create the moment first-tick
	// starvation was fixed.
	if _, err := conn.Exec(ctx, `SET statement_timeout = 0`); err != nil {
		return fmt.Errorf("statement_timeout: %w", err)
	}
	// Session-scoped advisory lock: provision and the rollup passes
	// write the same grain tables; unserialized they deadlock hourly.
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(hashtextextended($1, 0))`, d.Name+":runtime"); err != nil {
		return fmt.Errorf("advisory lock: %w", err)
	}
	defer conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock(hashtextextended($1, 0))`, d.Name+":runtime")
	defer conn.Exec(context.WithoutCancel(ctx), `RESET search_path`)
	var firstErr error
	// Hourly first (legacy matrix order), engine-owned — see provisionHourlySQL.
	if _, err := conn.Exec(ctx, provisionHourlyStmt(d), nil); err != nil {
		logger.Warn("runtime-provision fn failed",
			slog.String("dest", d.Name), slog.String("fn", "equipment_oee_hourly (engine)"), slog.String("err", err.Error()))
		firstErr = err
	}
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

// LoopProvision schedules runtime-provision on the given interval.
//
// Provision materializes a 30-DAY horizon of future shift/hour/day buckets
// (-4..+180 4-hour blocks) with ON CONFLICT DO NOTHING, so on any given run
// ~99% of the buckets already exist and are skipped. Because the horizon is 30
// days deep, running it hourly is wasteful: it re-walks the whole horizon (and,
// until the piot_get_*_begin helper functions are optimized, that walk takes
// 12-30 min while holding the shared runtime advisory lock, starving the rollup).
// The 30-day buffer means a several-hour cadence is ample — the rollup always
// finds current buckets already provisioned. `every` is configurable
// (RUNTIME_PROVISION_INTERVAL_HOURS) so the lock-hold frequency can be tuned
// down without changing which buckets get created.
func LoopProvision(ctx context.Context, dests []flows.Dest, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("runtime-provision started (P3b matrix, transitional search_path strategy)", slog.Duration("every", every))
	jobs.Loop(ctx, jobs.Job{Name: "runtime-provision", Every: every, Timeout: 30 * time.Minute, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			if err := RunProvision(ctx, d, logger); err != nil && firstErr == nil {
				firstErr = err
			}
		}
		return firstErr
	}}, logger, obs)
}
