//go:build golden

// Proof that the barcode_service DB role (db/migrations/t-barcode-service-role/01-up.sql) covers the
// service's WHOLE DB call path — pool connect, /healthz Ping and POST /v1/scans' transaction (advisory
// lock, tenant stamp, replay lookup, tenant fence, gapless counter, insert + counter upsert) — and
// nothing more.
//
// It builds a fixture with the production shape of the five tables (FKs, the identity column, the
// no-mutate trigger, FORCE ROW LEVEL SECURITY on core.production_orders + core.equipments and the
// public.current_tenant()/is_all_tenant() helpers), applies the REAL migration file twice, sets a
// password, and drives the real code (newPool + pgScanStore.RecordScan) logged in as barcode_service.
//
// Runs in CI's "golden fixtures" job (go-services.yml) against an ephemeral PostgreSQL 15 + TimescaleDB:
//
//	DATABASE_URL='postgres://postgres:pw@127.0.0.1:5432/scratch?sslmode=disable' \
//	    go test -tags golden -count=1 -run Golden -v ./cmd/barcode-service/
//
// DATABASE_URL must be a superuser on a THROWAWAY database: the fixture owns schemas core, bronze and
// gold there (it refuses to touch ones it did not create) and creates the cluster-wide role.
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	goldenMarker   = "barcode-service golden fixture (safe to drop)"
	goldenPassword = "golden-barcode-service"
)

var goldenSchemas = []string{"core", "bronze", "gold"}

var goldenDDL = `
DROP SCHEMA IF EXISTS gold CASCADE;
DROP SCHEMA IF EXISTS bronze CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA core;   COMMENT ON SCHEMA core   IS '` + goldenMarker + `';
CREATE SCHEMA bronze; COMMENT ON SCHEMA bronze IS '` + goldenMarker + `';
CREATE SCHEMA gold;   COMMENT ON SCHEMA gold   IS '` + goldenMarker + `';

CREATE OR REPLACE FUNCTION public.current_tenant() RETURNS int LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::int $$;
CREATE OR REPLACE FUNCTION public.is_all_tenant() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT public.current_tenant() = -1 $$;

CREATE TABLE core.enterprises (id_enterprise int PRIMARY KEY, nm_enterprise text);
CREATE TABLE core.sites (id_site int PRIMARY KEY, id_enterprise int NOT NULL REFERENCES core.enterprises);
CREATE TABLE core.areas (id_area int PRIMARY KEY, id_site int NOT NULL REFERENCES core.sites);
CREATE TABLE core.equipments (
  id_equipment int PRIMARY KEY, id_enterprise int NOT NULL, id_site int, id_area int REFERENCES core.areas,
  nm_equipment text);
CREATE TABLE core.production_orders (
  id_production_order bigint PRIMARY KEY, id_enterprise int NOT NULL, id_order int, nm_client text);

ALTER TABLE core.equipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.equipments FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.equipments
  USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));
ALTER TABLE core.production_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.production_orders FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.production_orders
  USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));

CREATE TABLE bronze.box_scans (
  box_scan_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  box_uid uuid NOT NULL DEFAULT gen_random_uuid(),
  id_enterprise int NOT NULL REFERENCES core.enterprises,
  id_site int REFERENCES core.sites,
  id_area int REFERENCES core.areas,
  id_equipment int NOT NULL REFERENCES core.equipments,
  id_production_order bigint NOT NULL REFERENCES core.production_orders,
  id_order int,
  scan_type text NOT NULL DEFAULT 'production'
    CHECK (scan_type IN ('production','sample','void','reprint','rework')),
  label_seq bigint,
  qty int NOT NULL DEFAULT 1,
  counts_toward_total boolean NOT NULL DEFAULT true,
  raw_barcode text,
  voids_box_scan_id bigint REFERENCES bronze.box_scans,
  scan_uuid uuid NOT NULL UNIQUE,
  ts_value timestamptz NOT NULL DEFAULT now(),
  ingested_at timestamptz NOT NULL DEFAULT now(),
  source_seq bigint,
  scanned_by text);
CREATE FUNCTION bronze.box_scans_no_mutate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'box_scans is append-only'; END $$;
CREATE TRIGGER trg_box_scans_no_mutate BEFORE UPDATE OR DELETE ON bronze.box_scans
  FOR EACH ROW EXECUTE FUNCTION bronze.box_scans_no_mutate();

CREATE TABLE gold.po_box_counter (
  id_production_order bigint PRIMARY KEY REFERENCES core.production_orders,
  id_enterprise int NOT NULL REFERENCES core.enterprises,
  last_label_seq bigint NOT NULL DEFAULT 0,
  total_qty bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now());

INSERT INTO core.enterprises VALUES (4, 't4'), (5, 't5');
INSERT INTO core.sites VALUES (11, 4), (21, 5);
INSERT INTO core.areas VALUES (12, 11), (22, 21);
INSERT INTO core.equipments VALUES (120, 4, 11, 12, 'line 4'), (220, 5, 21, 22, 'line 5');
INSERT INTO core.production_orders VALUES (1001, 4, 77, 'c4'), (2001, 5, 88, 'c5');
-- a tenant-5 scan whose scan_uuid a tenant-4 caller will replay
INSERT INTO bronze.box_scans (id_enterprise, id_equipment, id_production_order, scan_type, label_seq, scan_uuid)
VALUES (5, 220, 2001, 'production', 1, '00000000-0000-0000-0000-000000000005');
`

func goldenAdmin(t *testing.T) (*pgxpool.Pool, *url.URL) {
	t.Helper()
	raw := os.Getenv("DATABASE_URL")
	if raw == "" {
		t.Skip("DATABASE_URL not set")
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("DATABASE_URL: %v", err)
	}
	cfg, err := pgxpool.ParseConfig(raw)
	if err != nil {
		t.Fatalf("DATABASE_URL: %v", err)
	}
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool, u
}

// migrationSQL returns a t-barcode-service-role file without its psql meta-commands.
func migrationSQL(t *testing.T, name string) string {
	t.Helper()
	_, here, _, _ := runtime.Caller(0)
	b, err := os.ReadFile(filepath.Join(filepath.Dir(here), "../../../../db/migrations/t-barcode-service-role", name))
	if err != nil {
		t.Fatalf("read migration: %v", err)
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if !strings.HasPrefix(strings.TrimSpace(l), `\`) {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}

func setupGolden(t *testing.T, admin *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	for _, s := range goldenSchemas {
		var comment *string
		err := admin.QueryRow(ctx, `SELECT obj_description(oid, 'pg_namespace') FROM pg_namespace WHERE nspname = $1`, s).
			Scan(&comment)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			t.Fatalf("inspect %s: %v", s, err)
		}
		if err == nil && (comment == nil || *comment != goldenMarker) {
			t.Fatalf("schema %s exists and is not this fixture's — point DATABASE_URL at a throwaway database", s)
		}
	}
	if _, err := admin.Exec(ctx, `DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='barcode_service') THEN
	   DROP OWNED BY barcode_service; END IF; END $$`); err != nil {
		t.Fatalf("pre-clean: %v", err)
	}
	if _, err := admin.Exec(ctx, `DROP ROLE IF EXISTS barcode_service`); err != nil {
		t.Fatalf("pre-clean role: %v", err)
	}
	if _, err := admin.Exec(ctx, goldenDDL); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	up := migrationSQL(t, "01-up.sql")
	for i := 0; i < 2; i++ { // twice: the migration must be idempotent
		if _, err := admin.Exec(ctx, up); err != nil {
			t.Fatalf("01-up.sql (run %d): %v", i+1, err)
		}
	}
	if _, err := admin.Exec(ctx, `ALTER ROLE barcode_service PASSWORD '`+goldenPassword+`'`); err != nil {
		t.Fatalf("set password: %v", err)
	}
}

// rolePool opens the service's real pool (newPool: simple protocol, max 5) as barcode_service.
func rolePool(t *testing.T, u *url.URL) *pgxpool.Pool {
	t.Helper()
	port := 5432
	if p := u.Port(); p != "" {
		port, _ = strconv.Atoi(p)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := newPool(ctx, &dbCreds{Host: u.Hostname(), Port: port, User: dbRole, Password: goldenPassword,
		Database: strings.TrimPrefix(u.Path, "/")})
	if err != nil {
		t.Fatalf("newPool as barcode_service: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func TestGoldenBarcodeServiceRoleCoversScanPath(t *testing.T) {
	admin, u := goldenAdmin(t)
	setupGolden(t, admin)
	pool := rolePool(t, u)
	store := newPgScanStore(pool)
	ctx := context.Background()

	n := 0
	scan := func(mode string, scanType string, label *int64) ScanRequest {
		n++
		return ScanRequest{ScanUUID: fmt.Sprintf("00000000-0000-0000-0000-%012d", 1000+n), IDProductionOrder: 1001,
			IDEquipment: 120, Qty: 1, ScanType: scanType, Mode: mode, LabelSeq: label}
	}
	record := func(t *testing.T, ent int, req ScanRequest) (ScanResult, *domainError) {
		t.Helper()
		res, derr, err := store.RecordScan(ctx, ent, req)
		if err != nil {
			t.Fatalf("RecordScan as barcode_service: %v", err)
		}
		return res, derr
	}

	t.Run("healthz ping", func(t *testing.T) {
		if err := pool.Ping(ctx); err != nil {
			t.Fatalf("Ping as barcode_service: %v", err)
		}
	})

	var first ScanRequest
	t.Run("assign: gapless labels, counter insert then ON CONFLICT update", func(t *testing.T) {
		first = scan(modeAssign, scanTypeProduction, nil)
		for want := int64(1); want <= 3; want++ {
			req := first
			if want > 1 {
				req = scan(modeAssign, scanTypeProduction, nil)
			}
			res, derr := record(t, 4, req)
			if derr != nil || res.LabelSeq != want || res.Total != want || res.Replayed {
				t.Fatalf("scan %d: got %+v, %+v", want, res, derr)
			}
		}
		var site, area, order int
		if err := admin.QueryRow(ctx, `SELECT id_site, id_area, id_order FROM bronze.box_scans WHERE scan_uuid = $1`,
			first.ScanUUID).Scan(&site, &area, &order); err != nil || site != 11 || area != 12 || order != 77 {
			t.Fatalf("server-side enrichment: site=%d area=%d order=%d err=%v", site, area, order, err)
		}
	})

	t.Run("replay returns the original row", func(t *testing.T) {
		res, derr := record(t, 4, first)
		if derr != nil || !res.Replayed || res.LabelSeq != 1 || res.Total != 3 {
			t.Fatalf("got %+v, %+v", res, derr)
		}
	})

	t.Run("validate: gap is a 409, next label accepted", func(t *testing.T) {
		bad, good := int64(9), int64(4)
		if _, derr := record(t, 4, scan(modeValidate, scanTypeProduction, &bad)); derr == nil ||
			derr.Code != "label_seq_gap" || derr.Expected != 4 {
			t.Fatalf("want label_seq_gap expected 4, got %+v", derr)
		}
		if res, derr := record(t, 4, scan(modeValidate, scanTypeProduction, &good)); derr != nil || res.LabelSeq != 4 {
			t.Fatalf("got %+v, %+v", res, derr)
		}
	})

	t.Run("non-production scan does not consume the sequence", func(t *testing.T) {
		res, derr := record(t, 4, scan(modeAssign, "sample", nil))
		if derr != nil || res.LabelSeq != 0 || res.Total != 4 {
			t.Fatalf("got %+v, %+v", res, derr)
		}
	})

	t.Run("another tenant's PO is a 403", func(t *testing.T) {
		req := scan(modeAssign, scanTypeProduction, nil)
		req.IDProductionOrder, req.IDEquipment = 2001, 220
		if _, derr := record(t, 4, req); derr == nil || derr.Status != http.StatusForbidden {
			t.Fatalf("want 403, got %+v", derr)
		}
	})

	t.Run("another tenant's scan_uuid is a 409 that reveals nothing", func(t *testing.T) {
		req := scan(modeAssign, scanTypeProduction, nil)
		req.ScanUUID = "00000000-0000-0000-0000-000000000005"
		if res, derr := record(t, 4, req); derr == nil || derr.Code != "scan_uuid_conflict" || res.BoxScanID != 0 {
			t.Fatalf("want scan_uuid_conflict, got %+v, %+v", res, derr)
		}
	})

	t.Run("the tenant stamp is load-bearing (RLS, NOBYPASSRLS)", func(t *testing.T) {
		// The same fence without set_config: RLS hides the tenant's own PO, so it would be a 403.
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(ctx) }()
		owns, err := (&pgScanTx{tx: tx}).tenantOwns(ctx, 4, 1001, 120)
		if err != nil || owns {
			t.Fatalf("unstamped tenantOwns = %v, %v; RLS must hide the rows", owns, err)
		}
	})

	t.Run("superuser login records the same (stamp is a no-op there)", func(t *testing.T) {
		res, derr, err := newPgScanStore(admin).RecordScan(ctx, 4, scan(modeAssign, scanTypeProduction, nil))
		if err != nil || derr != nil || res.LabelSeq != 5 {
			t.Fatalf("got %+v, %+v, %v", res, derr, err)
		}
	})

	denied := func(t *testing.T, sql string, codes ...string) {
		t.Helper()
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(ctx) }()
		_, err = tx.Exec(ctx, sql)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) {
			t.Fatalf("%q: want a denial, got %v", sql, err)
		}
		for _, c := range codes {
			if pgErr.Code == c {
				return
			}
		}
		t.Fatalf("%q: want SQLSTATE %v, got %s (%s)", sql, codes, pgErr.Code, pgErr.Message)
	}
	t.Run("ungranted columns and tables denied", func(t *testing.T) {
		denied(t, `SELECT raw_barcode FROM bronze.box_scans`, "42501")
		denied(t, `SELECT nm_equipment FROM core.equipments`, "42501")
		denied(t, `SELECT nm_client FROM core.production_orders`, "42501")
		denied(t, `SELECT nm_enterprise FROM core.enterprises`, "42501")
		denied(t, `INSERT INTO bronze.box_scans (id_enterprise, id_equipment, id_production_order, scan_uuid, scanned_by)
		           VALUES (4, 120, 1001, gen_random_uuid(), 'x')`, "42501")
	})
	t.Run("mutations beyond the scan path denied", func(t *testing.T) {
		denied(t, `UPDATE bronze.box_scans SET qty = 2`, "42501")
		denied(t, `DELETE FROM bronze.box_scans`, "42501")
		denied(t, `DELETE FROM gold.po_box_counter`, "42501")
		denied(t, `UPDATE gold.po_box_counter SET id_enterprise = 5`, "42501")
		denied(t, `TRUNCATE gold.po_box_counter`, "42501")
		denied(t, `UPDATE core.production_orders SET id_order = 1`, "42501")
		denied(t, `CREATE TABLE public.barcode_should_not_exist (x int)`, "42501")
		denied(t, `CREATE TABLE gold.barcode_should_not_exist (x int)`, "42501")
	})

	t.Run("role attributes", func(t *testing.T) {
		var super, bypass, createrole, createdb bool
		if err := admin.QueryRow(ctx, `SELECT rolsuper, rolbypassrls, rolcreaterole, rolcreatedb
		    FROM pg_roles WHERE rolname = 'barcode_service'`).Scan(&super, &bypass, &createrole, &createdb); err != nil {
			t.Fatal(err)
		}
		if super || bypass || createrole || createdb {
			t.Fatalf("super=%v bypassrls=%v createrole=%v createdb=%v; all must be false", super, bypass, createrole, createdb)
		}
	})

	t.Run("rollback removes the role", func(t *testing.T) {
		pool.Close()
		if _, err := admin.Exec(ctx, migrationSQL(t, "rollback.sql")); err != nil {
			t.Fatalf("rollback.sql: %v", err)
		}
		var n int
		if err := admin.QueryRow(ctx, `SELECT count(*) FROM pg_roles WHERE rolname = 'barcode_service'`).Scan(&n); err != nil || n != 0 {
			t.Fatalf("role still present (%d, %v)", n, err)
		}
	})
}
