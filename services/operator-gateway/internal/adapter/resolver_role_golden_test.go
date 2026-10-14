//go:build golden

// Proof that the operator_gateway DB role (db/migrations/t-operator-gateway-role/01-up.sql) covers the
// service's WHOLE DB call path — pool connect, /healthz Ping and the topic resolver — and nothing more.
//
// It builds a small fixture with the production shape of the four resolver tables (including FORCE ROW
// LEVEL SECURITY on core.topic_routing + core.equipments and the public.current_tenant()/is_all_tenant()
// helpers from db/superset/02-tenant-rls.sql), applies the REAL migration file, sets a password, and
// then drives the real code (db.New pool + PGResolver) logged in as operator_gateway.
//
// Runs in CI's "golden fixtures" job (go-services.yml) against an ephemeral PostgreSQL 15 + TimescaleDB:
//
//	DATABASE_URL='postgres://postgres:pw@127.0.0.1:5432/scratch?sslmode=disable' \
//	    go test -tags golden -count=1 -v ./internal/adapter/
//
// DATABASE_URL must be a superuser on a THROWAWAY database: the fixture owns schema `core` there (it
// refuses to touch a `core` schema it did not create) and creates the cluster-wide role.
package adapter

import (
	"context"
	"errors"
	"io"
	"log/slog"
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

	"github.com/packiot/packiot-stack-alpha/services/operator-gateway/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/operator-gateway/internal/secrets"
)

const fixtureMarker = "operator-gateway golden fixture (safe to drop)"

// The tenant the instance serves (the fixture also holds tenant 5, which must never resolve).
const (
	goldenTenant = 4
	rolePassword = "golden-operator-gateway"
)

var fixtureDDL = `
DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA core;
COMMENT ON SCHEMA core IS '` + fixtureMarker + `';

CREATE OR REPLACE FUNCTION public.current_tenant() RETURNS int LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::int $$;
CREATE OR REPLACE FUNCTION public.is_all_tenant() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT public.current_tenant() = -1 $$;

CREATE TABLE core.sites (id_site int PRIMARY KEY, id_enterprise int NOT NULL, nm_site text);
CREATE TABLE core.areas (id_area int PRIMARY KEY, id_site int NOT NULL REFERENCES core.sites, nm_area text);
CREATE TABLE core.equipments (
  id_equipment int PRIMARY KEY, id_enterprise int NOT NULL, id_area int REFERENCES core.areas,
  cd_equipment varchar(255), nm_equipment text);
CREATE TABLE core.topic_routing (
  id_topic_route serial PRIMARY KEY, packml_topic varchar(255), id_equipment int REFERENCES core.equipments,
  id_enterprise int, active boolean NOT NULL, sparkplug_json jsonb, device_key text);

ALTER TABLE core.equipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.equipments FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.equipments
  USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));
ALTER TABLE core.topic_routing ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.topic_routing FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.topic_routing
  USING ((SELECT public.is_all_tenant()) OR id_enterprise = (SELECT public.current_tenant()));

INSERT INTO core.sites VALUES (11, 4, 'site4'), (21, 5, 'site5');
INSERT INTO core.areas VALUES (12, 11, 'area4'), (22, 21, 'area5');
INSERT INTO core.equipments VALUES
  (120, 4, 12, 'LINHA_D', 'line D'), (121, 4, 12, NULL, 'no code'), (122, 4, 12, 'X1', 'x1'),
  (123, 4, 12, 'X2', 'x2'), (220, 5, 22, 'OTHER', 'tenant 5');
INSERT INTO core.topic_routing (packml_topic, id_equipment, id_enterprise, active, device_key) VALUES
  ('T4/LINE_D',   120, 4, true,  'dk_secret_1'),
  ('T4/NO_CODE',  121, 4, true,  NULL),
  ('T4/INACTIVE', 120, 4, false, NULL),
  ('T4/DUP',      122, 4, true,  NULL),
  ('T4/DUP',      123, 4, true,  NULL),
  ('T5/OTHER',    220, 5, true,  NULL);
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
	// Multi-statement fixture + migration bodies go through the simple protocol.
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool, u
}

// migrationSQL returns a migration file of t-operator-gateway-role without its psql meta-commands.
func migrationSQL(t *testing.T, name string) string {
	t.Helper()
	_, here, _, _ := runtime.Caller(0)
	p := filepath.Join(filepath.Dir(here), "../../../../db/migrations/t-operator-gateway-role", name)
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read migration: %v", err)
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(strings.TrimSpace(l), `\`) {
			continue
		}
		out = append(out, l)
	}
	return strings.Join(out, "\n")
}

func setupRole(t *testing.T, admin *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	var comment *string
	if err := admin.QueryRow(ctx,
		`SELECT obj_description(oid, 'pg_namespace') FROM pg_namespace WHERE nspname = 'core'`).Scan(&comment); err != nil &&
		!errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("inspect core: %v", err)
	} else if err == nil && (comment == nil || *comment != fixtureMarker) {
		t.Fatalf("schema core exists and is not this fixture's — point DATABASE_URL at a throwaway database")
	}
	// Start from no role (rollback.sql is idempotent and drops it if a previous run left it).
	if _, err := admin.Exec(ctx, `DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='operator_gateway') THEN
	   DROP OWNED BY operator_gateway; END IF; END $$`); err != nil {
		t.Fatalf("pre-clean: %v", err)
	}
	if _, err := admin.Exec(ctx, `DROP ROLE IF EXISTS operator_gateway`); err != nil {
		t.Fatalf("pre-clean role: %v", err)
	}
	if _, err := admin.Exec(ctx, fixtureDDL); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	up := migrationSQL(t, "01-up.sql")
	for i := 0; i < 2; i++ { // twice: the migration must be idempotent
		if _, err := admin.Exec(ctx, up); err != nil {
			t.Fatalf("01-up.sql (run %d): %v", i+1, err)
		}
	}
	if _, err := admin.Exec(ctx, `ALTER ROLE operator_gateway PASSWORD '`+rolePassword+`'`); err != nil {
		t.Fatalf("set password: %v", err)
	}
}

// rolePool opens the service's real pool (db.New: simple protocol, otelpgx, Ping) as operator_gateway.
func rolePool(t *testing.T, u *url.URL) *pgxpool.Pool {
	t.Helper()
	port := 5432
	if p := u.Port(); p != "" {
		port, _ = strconv.Atoi(p)
	}
	creds := &secrets.DBCreds{Host: u.Hostname(), Port: port, User: "operator_gateway", Password: rolePassword,
		Database: strings.TrimPrefix(u.Path, "/")}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := db.New(ctx, creds, "operator-gateway-golden", slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatalf("db.New as operator_gateway: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func TestGoldenOperatorGatewayRoleCoversResolver(t *testing.T) {
	admin, u := goldenAdmin(t)
	setupRole(t, admin)
	pool := rolePool(t, u)
	ctx := context.Background()

	// The cache is per resolver; build a fresh one per check so every case hits the DB.
	resolve := func(p *pgxpool.Pool, topic string) (Resolved, error) {
		return NewPGResolver(p, goldenTenant, time.Minute, time.Minute).ResolveTopic(ctx, topic)
	}

	t.Run("healthz ping", func(t *testing.T) {
		if err := NewPGResolver(pool, goldenTenant, time.Minute, time.Minute).Ping(ctx); err != nil {
			t.Fatalf("Ping as operator_gateway: %v", err)
		}
	})

	t.Run("resolves an active topic of its tenant", func(t *testing.T) {
		got, err := resolve(pool, "T4/LINE_D")
		if err != nil {
			t.Fatalf("resolve: %v", err)
		}
		want := Resolved{IDEquipment: 120, CDMachine: "LINHA_D", IDArea: 12, IDSite: 11}
		if got != want {
			t.Fatalf("got %+v, want %+v", got, want)
		}
		got, err = resolve(pool, "T4/NO_CODE")
		if err != nil || got.IDEquipment != 121 || got.CDMachine != "" {
			t.Fatalf("NULL cd_equipment: got %+v, %v", got, err)
		}
	})

	for _, tc := range []struct{ name, topic string }{
		{"inactive", "T4/INACTIVE"},
		{"other tenant", "T5/OTHER"},
		{"ambiguous", "T4/DUP"},
		{"unknown", "NOPE"},
	} {
		t.Run("unresolved: "+tc.name, func(t *testing.T) {
			if _, err := resolve(pool, tc.topic); !errors.Is(err, ErrUnresolved) {
				t.Fatalf("want ErrUnresolved, got %v", err)
			}
		})
	}

	t.Run("superuser login resolves the same (stamp is a no-op there)", func(t *testing.T) {
		got, err := resolve(admin, "T4/LINE_D")
		if err != nil || got.IDEquipment != 120 {
			t.Fatalf("got %+v, %v", got, err)
		}
	})

	// What the role must NOT be able to do.
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
	t.Run("ungranted column denied", func(t *testing.T) {
		denied(t, `SELECT device_key FROM core.topic_routing`, "42501")
	})
	t.Run("ungranted table column denied", func(t *testing.T) {
		denied(t, `SELECT nm_equipment FROM core.equipments`, "42501")
	})
	t.Run("writes denied", func(t *testing.T) {
		// 25006 = read-only transaction (the role's default), 42501 = no privilege
		denied(t, `UPDATE core.sites SET nm_site = 'x'`, "25006", "42501")
		denied(t, `INSERT INTO core.topic_routing (packml_topic, active) VALUES ('x', true)`, "25006", "42501")
		denied(t, `CREATE TABLE public.opgw_should_not_exist (x int)`, "25006", "42501")
	})

	t.Run("RLS fail-closed without the tenant stamp", func(t *testing.T) {
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM core.topic_routing`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Fatalf("unstamped session saw %d route rows; RLS must return 0", n)
		}
	})

	t.Run("role attributes", func(t *testing.T) {
		var super, bypass, createrole, createdb bool
		if err := admin.QueryRow(ctx, `SELECT rolsuper, rolbypassrls, rolcreaterole, rolcreatedb
		    FROM pg_roles WHERE rolname = 'operator_gateway'`).Scan(&super, &bypass, &createrole, &createdb); err != nil {
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
		if err := admin.QueryRow(ctx, `SELECT count(*) FROM pg_roles WHERE rolname = 'operator_gateway'`).Scan(&n); err != nil || n != 0 {
			t.Fatalf("role still present (%d, %v)", n, err)
		}
	})
}
