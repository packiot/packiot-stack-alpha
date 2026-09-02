package refsync

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestSyncTable_upsert validates the core contract against two real databases:
// upsert updates existing rows, inserts missing ones, and LEAVES shadow-only
// rows in place (pure upsert, no delete — so FKs from flow tables never trip).
// Skips unless DATABASE_URL points at a Postgres the test may create DBs on.
func TestSyncTable_upsert(t *testing.T) {
	base := os.Getenv("DATABASE_URL")
	if base == "" {
		t.Skip("set DATABASE_URL to run refsync integration test")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, base)
	if err != nil {
		t.Fatalf("admin connect: %v", err)
	}
	defer admin.Close()
	for _, db := range []string{"rs_main", "rs_shadow"} {
		_, _ = admin.Exec(ctx, "DROP DATABASE IF EXISTS "+db+" WITH (FORCE)")
		if _, err := admin.Exec(ctx, "CREATE DATABASE "+db); err != nil {
			t.Fatalf("create %s: %v", db, err)
		}
		defer admin.Exec(context.Background(), "DROP DATABASE IF EXISTS "+db+" WITH (FORCE)")
	}

	urlFor := func(db string) string {
		// swap the /dbname path segment in the base URL
		i := strings.LastIndex(base, "/")
		j := strings.IndexAny(base[i:], "?")
		if j == -1 {
			return base[:i+1] + db
		}
		return base[:i+1] + db + base[i+j:]
	}
	mainPool, err := pgxpool.New(ctx, urlFor("rs_main"))
	if err != nil {
		t.Fatalf("main connect: %v", err)
	}
	defer mainPool.Close()
	analyticsPool, err := pgxpool.New(ctx, urlFor("rs_shadow"))
	if err != nil {
		t.Fatalf("shadow connect: %v", err)
	}
	defer analyticsPool.Close()

	for _, p := range []*pgxpool.Pool{mainPool, analyticsPool} {
		if _, err := p.Exec(ctx, `CREATE TABLE public.foo (id int PRIMARY KEY, val text, n int)`); err != nil {
			t.Fatalf("create table: %v", err)
		}
	}
	mainPool.Exec(ctx, `INSERT INTO public.foo VALUES (1,'a',10),(2,'b',20)`)
	analyticsPool.Exec(ctx, `INSERT INTO public.foo VALUES (1,'STALE',99),(3,'shadow-only',30)`)

	n, err := syncTable(ctx, mainPool, analyticsPool, "public", "foo")
	if err != nil {
		t.Fatalf("syncTable: %v", err)
	}
	if n != 2 {
		t.Errorf("copied rows: got %d want 2", n)
	}

	got := map[int]string{}
	rows, _ := analyticsPool.Query(ctx, `SELECT id, val||':'||n FROM public.foo`)
	for rows.Next() {
		var id int
		var v string
		rows.Scan(&id, &v)
		got[id] = v
	}
	// id=1 updated to main's value, id=2 inserted, id=3 (shadow-only) untouched.
	want := map[int]string{1: "a:10", 2: "b:20", 3: "shadow-only:30"}
	for id, w := range want {
		if got[id] != w {
			t.Errorf("id=%d: got %q want %q", id, got[id], w)
		}
	}
	if len(got) != 3 {
		t.Errorf("row count: got %d want 3 (%v)", len(got), got)
	}
}
