package caggsplit

import (
	"bytes"
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Pass is a split statement in executable form.
//
// Two ways to run it:
//
//   - SQL(): one multi-statement string — DROP; CREATE TEMP TABLE … ON COMMIT
//     DROP AS <Read>; <Apply>. Self-contained: psql scripts (the history
//     renderer) and the parity/golden accessors run this form.
//   - Run(): the engine form. Same result, but the snapshot table lives for the
//     whole SESSION (ON COMMIT DELETE ROWS), filled by a binary COPY round trip
//     (see Snapshot) instead of being created and dropped every transaction.
//
// WHY THE ENGINE FORM (ADR-0063 A3, 2026-10-14). pg_stat_statements on PG15
// jumbles a DML statement's relations by OID. A temp table created per
// transaction gets a NEW OID every tick, so every statement that reads it got a
// new queryid every tick: on staging 6,245 of the ~9,500 entries were
// stream_engine statements with calls = 1, pg_stat_statements was full (10,000)
// and had deallocated 2,782 times, evicting everything else and making the stats
// useless (totals even went DOWN between snapshots). Utility statements (CREATE
// TABLE AS, COPY, CREATE INDEX, ANALYZE) are hashed by their TEXT instead, so they
// were fine. A session temp table keeps its OID for the backend's life, so the
// statements that read it keep their queryid; the jobs that use it run on a
// dedicated long-lived pool (db.NewDedicated) to keep meeting the same backend.
// It also ends the per-tick CREATE/DROP of ~20 temp tables (pg_class/
// pg_attribute/pg_type inserts and deletes every minute).
type Pass struct {
	Table string // snapshot temp table
	Read  string // the statement's CTE chain + the tail SELECT
	Apply string // the DML with its feeds re-pointed at Table; "" = snapshot only
}

// Map applies f to every SQL text (format verbs, window widening).
func (p Pass) Map(f func(string) string) Pass {
	q := Pass{Table: p.Table, Read: f(p.Read)}
	if p.Apply != "" {
		q.Apply = f(p.Apply)
	}
	return q
}

// SQL renders the self-contained multi-statement form.
func (p Pass) SQL() string {
	out := "\n\tDROP TABLE IF EXISTS pg_temp." + p.Table + ";" +
		"\n\tCREATE TEMP TABLE " + p.Table + " ON COMMIT DROP AS\n\t" + p.Read
	if p.Apply != "" {
		out += ";\n\t" + p.Apply
	}
	return out
}

// Run executes the pass on tx in the engine form and returns the apply's tag.
func (p Pass) Run(ctx context.Context, tx pgx.Tx) (pgconn.CommandTag, error) {
	if err := Snapshot(ctx, tx, p.Table, p.Read); err != nil {
		return pgconn.CommandTag{}, err
	}
	if p.Apply == "" {
		return pgconn.CommandTag{}, nil
	}
	tag, err := tx.Exec(ctx, p.Apply)
	if err != nil {
		return tag, fmt.Errorf("apply %s: %w", p.Table, err)
	}
	return tag, nil
}

// ensureSQL creates the session temp table with read's columns and exact types,
// once per session (WITH NO DATA: nothing is executed; IF NOT EXISTS: a no-op
// with a NOTICE afterwards).
func ensureSQL(table, sel string) string {
	return "CREATE TEMP TABLE IF NOT EXISTS " + table + " ON COMMIT DELETE ROWS AS\n\t" + sel + "\n\tWITH NO DATA"
}

// Snapshot (re)fills the session temp table `table` with the rows of read.
//
// The rows travel as COPY (read) TO STDOUT (FORMAT binary) → COPY table FROM
// STDIN (FORMAT binary). COPY's query is planned as a SELECT — so TimescaleDB
// constifies a real-time cagg's watermark exactly as it does for CREATE TABLE AS
// (verified on TS 2.27, and by the golden tests) — whereas INSERT … SELECT is DML
// and would bring the watermark trap back. Binary format into a table created
// from the same query copies every value bit for bit (float8 included). read must
// carry no bind parameters (COPY takes none; see InlineIntArrays).
func Snapshot(ctx context.Context, tx pgx.Tx, table, read string) error {
	if !ident.MatchString(table) {
		return fmt.Errorf("snapshot: table %q is not a plain identifier", table)
	}
	if _, err := tx.Exec(ctx, ensureSQL(table, read)); err != nil {
		return fmt.Errorf("snapshot %s: create: %w", table, err)
	}
	// Normally empty (ON COMMIT DELETE ROWS); a second run in one transaction
	// must not see the first run's rows.
	if _, err := tx.Exec(ctx, "DELETE FROM "+table); err != nil {
		return fmt.Errorf("snapshot %s: clear: %w", table, err)
	}
	var buf bytes.Buffer
	pc := tx.Conn().PgConn()
	if _, err := pc.CopyTo(ctx, &buf, "COPY (\n\t"+read+"\n\t) TO STDOUT (FORMAT binary)"); err != nil {
		return fmt.Errorf("snapshot %s: read: %w", table, err)
	}
	if _, err := pc.CopyFrom(ctx, &buf, "COPY "+table+" FROM STDIN (FORMAT binary)"); err != nil {
		return fmt.Errorf("snapshot %s: load: %w", table, err)
	}
	return nil
}

// Fill (re)fills the session temp table `table` with the rows of sel by INSERT …
// SELECT — for sets that read no real-time cagg (the eligible sets). It returns
// the number of rows. args bind sel's parameters (simple protocol).
func Fill(ctx context.Context, tx pgx.Tx, table, sel string, args ...any) (int64, error) {
	if !ident.MatchString(table) {
		return 0, fmt.Errorf("fill: table %q is not a plain identifier", table)
	}
	if _, err := tx.Exec(ctx, ensureSQL(table, sel), args...); err != nil {
		return 0, fmt.Errorf("fill %s: create: %w", table, err)
	}
	if _, err := tx.Exec(ctx, "DELETE FROM "+table); err != nil {
		return 0, fmt.Errorf("fill %s: clear: %w", table, err)
	}
	tag, err := tx.Exec(ctx, "INSERT INTO "+table+"\n\t"+sel, args...)
	if err != nil {
		return 0, fmt.Errorf("fill %s: %w", table, err)
	}
	return tag.RowsAffected(), nil
}

// CTASSelect returns the SELECT of a `CREATE TEMP TABLE <table> ON COMMIT DROP AS
// <select>` statement (the eligible-set templates), for Fill.
func CTASSelect(stmt, table string) (string, error) {
	prefix := "CREATE TEMP TABLE " + table + " ON COMMIT DROP AS"
	t := strings.TrimSpace(stmt)
	if !strings.HasPrefix(t, prefix) {
		return "", fmt.Errorf("caggsplit: %q does not start with %q", t[:min(len(t), 60)], prefix)
	}
	return strings.TrimSpace(strings.TrimPrefix(t, prefix)), nil
}

// MustCTASPass turns a `CREATE TEMP TABLE <table> ON COMMIT DROP AS <select>`
// template into a snapshot-only Pass.
func MustCTASPass(stmt, table string) Pass {
	sel, err := CTASSelect(stmt, table)
	if err != nil {
		panic(err)
	}
	return Pass{Table: table, Read: sel}
}

var bindParam = regexp.MustCompile(`\$([0-9]+)\b`)

// InlineIntArrays replaces $1..$n in sql with '{…}'::int[] literals (COPY takes no
// bind parameters). The values are ints, so the literal needs no escaping.
func InlineIntArrays(sql string, arrays ...[]int) (string, error) {
	var err error
	out := bindParam.ReplaceAllStringFunc(sql, func(m string) string {
		n, _ := strconv.Atoi(m[1:])
		if n < 1 || n > len(arrays) {
			err = fmt.Errorf("caggsplit: bind %s has no array (got %d)", m, len(arrays))
			return m
		}
		parts := make([]string, len(arrays[n-1]))
		for i, v := range arrays[n-1] {
			parts[i] = strconv.Itoa(v)
		}
		return "'{" + strings.Join(parts, ",") + "}'::int[]"
	})
	return out, err
}
