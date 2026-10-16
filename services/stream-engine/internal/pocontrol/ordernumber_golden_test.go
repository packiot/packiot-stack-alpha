//go:build golden

// ADR-0062 step 2 — the 30805 create-PO upsert and the lifecycle natural-key
// lookup, run against a REAL Postgres carrying the REAL step-1 migration
// (db/migrations/t-adr0062-p1-po-number-expand/01-up.sql, read from the repo
// and re-homed from schema core → po62 so the test never touches a real core).
// It proves, end-to-end through Handler.Execute: ON CONFLICT (id_enterprise,
// id_order_text) is a valid arbiter and upserts in place on a re-send; id_order
// sent NULL is filled by the trigger (the number itself when a free int4, a
// NEGATIVE internal value otherwise); the text is stored exactly as given
// ("08396260", "834.058"); a JSON number behaves as before (218300 → id_order
// 218300); the lifecycle lookup resolves by text, with the integer shim.
//
//	Run: DATABASE_URL=postgres://user:pass@host/db go test -tags golden \
//	       ./internal/pocontrol -run Golden -v
package pocontrol

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// Pre-ADR-0062 shape of the tables the 30805 chain touches (columns it writes
// + the old integer natural key), as the migration found them.
const po62Base = `
DROP SCHEMA IF EXISTS po62 CASCADE;
CREATE SCHEMA po62;
CREATE TABLE po62.product_families (
    id_product_family serial PRIMARY KEY,
    nm_product_family varchar NOT NULL,
    id_enterprise int NOT NULL,
    UNIQUE (id_enterprise, nm_product_family)
);
CREATE TABLE po62.products (
    id_product serial PRIMARY KEY,
    nm_product varchar, id_product_family int, txt_product varchar,
    id_enterprise int NOT NULL, cd_product varchar
);
CREATE TABLE po62.clients (
    id_client serial PRIMARY KEY,
    nm_client varchar NOT NULL, id_enterprise int NOT NULL,
    UNIQUE (nm_client, id_enterprise)
);
CREATE TABLE po62.production_orders (
    id_production_order bigserial PRIMARY KEY,
    id_enterprise int NOT NULL, id_site int, id_area int, id_equipment int NOT NULL,
    id_product int, id_client int,
    status int NOT NULL,
    production_programmed double precision, production_ordered double precision,
    id_order int NOT NULL,
    ts_creation timestamptz NOT NULL DEFAULT now(),
    txt_production_order_description varchar,
    conversion_factor double precision,
    id_order_text varchar(255),
    custom_field jsonb,
    UNIQUE (id_enterprise, id_order)
);`

func po62Connect(t *testing.T) (context.Context, *pgxpool.Pool) {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	t.Cleanup(cancel)
	pc, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	// Same exec mode as the service pool (internal/db/pool.go): the 30805
	// product insert relies on simple-protocol parameter interpolation.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(ctx, po62Base); err != nil {
		t.Fatalf("base schema: %v", err)
	}
	// The real step-1 migration, re-homed core → po62; psql meta-commands dropped.
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..",
		"db", "migrations", "t-adr0062-p1-po-number-expand", "01-up.sql"))
	if err != nil {
		t.Fatalf("read migration: %v", err)
	}
	mig := regexp.MustCompile(`(?m)^\\.*$`).ReplaceAllString(string(raw), "")
	mig = regexp.MustCompile(`\bcore\.`).ReplaceAllString(mig, "po62.")
	if _, err := pool.Exec(ctx, mig); err != nil {
		t.Fatalf("ADR-0062 P1 migration: %v", err)
	}
	return ctx, pool
}

const po62Topic = "ENT/SITE/AREA/LINE1"

func po62Handler(eq int) *Handler {
	r := sparkplug.NewResolver(nil, time.Hour, time.Hour)
	q := 100
	r.SeedForTest(po62Topic, &sparkplug.EquipmentInfo{IDEnterprise: 1, IDSite: 2, IDArea: 3, IDEquipment: eq, SignalQuality: &q})
	return NewHandler(r, slog.Default())
}

func createPOMetric(t *testing.T, payload string) *sparkplug.Metric {
	t.Helper()
	var m sparkplug.Metric
	raw := `{"name":"` + po62Topic + `","id":30805,"timestamp":1783000000000,"value":` + payload + `}`
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatalf("metric: %v", err)
	}
	if got := m.TopicForRegister(); got != po62Topic {
		t.Fatalf("topic for register = %q, want %q", got, po62Topic)
	}
	return &m
}

type po62Row struct {
	id      int64
	idOrder int
	text    string
	eq      int
	custom  *string
}

func po62Get(t *testing.T, ctx context.Context, pool *pgxpool.Pool, text string) (po62Row, int) {
	t.Helper()
	var r po62Row
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM po62.production_orders WHERE id_enterprise=1 AND id_order_text=$1`, text).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n == 0 {
		return r, 0
	}
	if err := pool.QueryRow(ctx, `
		SELECT id_production_order, id_order, id_order_text, id_equipment, custom_field::text
		  FROM po62.production_orders WHERE id_enterprise=1 AND id_order_text=$1`, text).
		Scan(&r.id, &r.idOrder, &r.text, &r.eq, &r.custom); err != nil {
		t.Fatal(err)
	}
	return r, n
}

func TestGoldenCreatePOTextNumber(t *testing.T) {
	ctx, pool := po62Connect(t)

	// A legacy integer-only writer (replicator) already holds 834 with the lost
	// client text "834.058" — the trigger leaves its text alone.
	if _, err := pool.Exec(ctx, `INSERT INTO po62.production_orders
		(id_enterprise, id_equipment, status, id_order, id_order_text) VALUES (1, 10, 3, 834, '834.058')`); err != nil {
		t.Fatalf("seed legacy: %v", err)
	}

	h := po62Handler(10)
	for _, pl := range []string{
		`{"id_order":"ORD-1","order_quantity":100,"nm_product":"P","cd_product":"P1","nm_client":"C","custom_field":{"a":1}}`,
		`{"id_order":"08396260","order_quantity":100,"nm_product":"P","cd_product":"P1","nm_client":"C"}`,
		`{"id_order":218300,"order_quantity":100,"nm_product":"P","cd_product":"P1","nm_client":"C"}`,
		`{"id_order":"  834.058x  ","order_quantity":5,"nm_product":"P","cd_product":"P1","nm_client":"C"}`,
		`{"id_order":834.058,"order_quantity":5,"nm_product":"P","cd_product":"P1","nm_client":"C"}`, // = legacy PO's text → upsert onto it
		`{"id_order":"","order_quantity":5,"nm_product":"P","cd_product":"P1","nm_client":"C"}`,      // rejected
		`{"order_quantity":5,"nm_product":"P","cd_product":"P1","nm_client":"C"}`,                    // rejected
	} {
		if err := h.Execute(ctx, pool, createPOMetric(t, pl), Schemas{Core: "po62", Gold: "po62", Silver: "po62", Ev: "po62", Identity: "po62"}); err != nil {
			t.Fatalf("execute: %v", err)
		}
	}
	if st := h.Stats(); st.Created != 5 || st.Dropped != 2 {
		t.Fatalf("stats: created=%d dropped=%d, want 5 / 2 (empty + absent id_order rejected)", st.Created, st.Dropped)
	}
	if legacy, n := po62Get(t, ctx, pool, "834.058"); n != 1 || legacy.idOrder != 834 || legacy.eq != 10 {
		t.Errorf("JSON number 834.058: n=%d id_order=%d — must upsert onto the legacy PO with that client text", n, legacy.idOrder)
	}
	var total int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM po62.production_orders`).Scan(&total); err != nil || total != 5 {
		t.Errorf("rows=%d err=%v, want 5 (legacy + 4 new)", total, err)
	}

	ord, n := po62Get(t, ctx, pool, "ORD-1")
	if n != 1 || ord.idOrder >= 0 || ord.eq != 10 {
		t.Errorf("ORD-1: n=%d id_order=%d eq=%d — want one row with a NEGATIVE internal id_order", n, ord.idOrder, ord.eq)
	}
	if lz, n := po62Get(t, ctx, pool, "08396260"); n != 1 || lz.idOrder != 8396260 {
		t.Errorf("08396260: n=%d id_order=%d — text kept, free int4 assigned", n, lz.idOrder)
	}
	if num, n := po62Get(t, ctx, pool, "218300"); n != 1 || num.idOrder != 218300 {
		t.Errorf("JSON number 218300: n=%d id_order=%d — backward-compatible integer", n, num.idOrder)
	}
	if x, n := po62Get(t, ctx, pool, "834.058x"); n != 1 || x.idOrder >= 0 {
		t.Errorf("834.058x (trimmed): n=%d id_order=%d", n, x.idOrder)
	}
	var uuidNull int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM po62.production_orders WHERE po_uuid IS NULL`).Scan(&uuidNull); err != nil || uuidNull != 0 {
		t.Errorf("po_uuid default not applied: nulls=%d err=%v", uuidNull, err)
	}

	// Re-send ORD-1 from another equipment with a new custom_field: the text
	// natural key upserts IN PLACE (same PO id, same internal id_order).
	h2 := po62Handler(11)
	if err := h2.Execute(ctx, pool, createPOMetric(t,
		`{"id_order":"ORD-1","order_quantity":100,"nm_product":"P","cd_product":"P1","nm_client":"C","custom_field":{"a":2}}`),
		Schemas{Core: "po62", Gold: "po62", Silver: "po62", Ev: "po62", Identity: "po62"}); err != nil {
		t.Fatal(err)
	}
	if h2.Stats().Dropped != 0 {
		t.Fatal("re-send of ORD-1 dropped — ON CONFLICT (id_enterprise, id_order_text) not valid?")
	}
	again, n := po62Get(t, ctx, pool, "ORD-1")
	if n != 1 || again.id != ord.id || again.idOrder != ord.idOrder || again.eq != 11 ||
		again.custom == nil || *again.custom != `{"a": 2}` {
		t.Errorf("upsert: n=%d %+v (custom=%v), want in-place update of PO %d on eq 11", n, again, deref(again.custom), ord.id)
	}
}

func TestGoldenLifecycleTargetByText(t *testing.T) {
	ctx, pool := po62Connect(t)
	// eq 10: an alphanumeric PO, a zero-padded one (trigger gives it 8396260),
	// and a legacy integer row whose client text was lost (834 / "834.058").
	if _, err := pool.Exec(ctx, `INSERT INTO po62.production_orders (id_enterprise, id_equipment, status, id_order, id_order_text) VALUES
		(1, 10, 1, NULL, 'ORD-1'), (1, 10, 1, NULL, '08396260'), (1, 10, 1, 834, '834.058'), (1, 11, 1, NULL, 'ORD-2')`); err != nil {
		t.Fatalf("seed: %v", err)
	}
	idOf := func(text string) int64 {
		var id int64
		if err := pool.QueryRow(ctx, `SELECT id_production_order FROM po62.production_orders WHERE id_order_text=$1`, text).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	h := NewHandler(nil, slog.Default())
	for _, c := range []struct {
		payload string
		want    int64
	}{
		{`{"id_order":"ORD-1"}`, idOf("ORD-1")},
		{`{"id_order":"08396260"}`, idOf("08396260")},
		{`{"id_order":8396260}`, idOf("08396260")}, // shim: integer still resolves the legacy PO
		{`{"id_order":834}`, idOf("834.058")},      // shim: identical to the old integer lookup
		{`{"id_order":"834.058"}`, idOf("834.058")},
		{`{"id_order":"ORD-2"}`, 0}, // other equipment
		{`{"id_order":"NOPE"}`, 0},
		{`{"note":"x"}`, 0}, // no id_order → no-op
	} {
		var p paramPayload
		if err := json.Unmarshal([]byte(c.payload), &p); err != nil {
			t.Fatalf("%s: %v", c.payload, err)
		}
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		got, err := h.resolveTargetID(ctx, tx, "po62", 10, p)
		tx.Rollback(ctx)
		if err != nil || got != c.want {
			t.Errorf("%s: got %d err=%v, want %d", c.payload, got, err, c.want)
		}
	}
}

func deref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}
