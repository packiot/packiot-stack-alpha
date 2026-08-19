package flows

import (
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// nonNilPool returns a non-nil *pgxpool.Pool WITHOUT connecting — the flows
// builder only stores the pointer and inspects nil-ness, so a bare zero-value
// pool is sufficient for these table-driven assertions.
func nonNilPool() *pgxpool.Pool { return &pgxpool.Pool{} }

// destByName finds a dest by Name (empty Dest + false when absent).
func destByName(dests []Dest, name string) (Dest, bool) {
	for _, d := range dests {
		if d.Name == name {
			return d, true
		}
	}
	return Dest{}, false
}

func TestStandardFiltered_ShadowGoPortEnabled(t *testing.T) {
	pool := nonNilPool()

	t.Run("flag ON, no shadow pool → shadow_go_port only", func(t *testing.T) {
		dests := StandardFiltered(pool, nil, true)
		if len(dests) != 1 {
			t.Fatalf("want 1 dest, got %d: %+v", len(dests), dests)
		}
		sgp, ok := destByName(dests, "shadow_go_port")
		if !ok {
			t.Fatalf("shadow_go_port dest missing: %+v", dests)
		}
		if sgp.EvSchema != "shadow_go_port" || sgp.RefSchema != "public" {
			t.Fatalf("shadow_go_port dest schemas wrong: %+v", sgp)
		}
		if _, ok := destByName(dests, "public"); ok {
			t.Fatalf("did not expect a public main-pool dest when flag ON: %+v", dests)
		}
	})

	// With a dedicated F3 shadow pool (staging), the build is F3-ONLY regardless
	// of the flag — the main-pool dest is a dead comparator artifact (F2 retired,
	// bake off) and rolling it up only errors against its incomplete schema.
	t.Run("with shadow pool, flag ON → F3-only (main dest omitted)", func(t *testing.T) {
		shadow := nonNilPool()
		dests := StandardFiltered(pool, shadow, true)
		if len(dests) != 1 {
			t.Fatalf("want 1 dest (packiot_shadow only), got %d: %+v", len(dests), dests)
		}
		if _, ok := destByName(dests, "shadow_go_port"); ok {
			t.Fatalf("shadow_go_port main dest must be omitted when a shadow pool exists: %+v", dests)
		}
		ps, ok := destByName(dests, "packiot_shadow")
		if !ok {
			t.Fatalf("packiot_shadow dest missing: %+v", dests)
		}
		if ps.Pool != shadow || ps.EvSchema != "public" || ps.RefSchema != "public" {
			t.Fatalf("packiot_shadow dest wrong: %+v", ps)
		}
	})

	t.Run("flag OFF, no shadow pool → shadow_go_port EXCLUDED, single public flow", func(t *testing.T) {
		dests := StandardFiltered(pool, nil, false)
		if _, ok := destByName(dests, "shadow_go_port"); ok {
			t.Fatalf("shadow_go_port must be excluded when flag OFF: %+v", dests)
		}
		if len(dests) != 1 {
			t.Fatalf("want 1 dest (public), got %d: %+v", len(dests), dests)
		}
		pub, ok := destByName(dests, "public")
		if !ok {
			t.Fatalf("single-flow public main-pool dest missing: %+v", dests)
		}
		// Single-flow F3-native: main pool, public flow tables + public refs —
		// exactly where the ingest nil-shadow fallback writes.
		if pub.Pool != pool || pub.EvSchema != "public" || pub.RefSchema != "public" {
			t.Fatalf("public dest wrong: %+v", pub)
		}
	})

	t.Run("with shadow pool, flag OFF → F3-only (public main dest also omitted)", func(t *testing.T) {
		shadow := nonNilPool()
		dests := StandardFiltered(pool, shadow, false)
		if len(dests) != 1 {
			t.Fatalf("want 1 dest (packiot_shadow only), got %d: %+v", len(dests), dests)
		}
		if _, ok := destByName(dests, "shadow_go_port"); ok {
			t.Fatalf("shadow_go_port must be omitted: %+v", dests)
		}
		if _, ok := destByName(dests, "public"); ok {
			t.Fatalf("legacy public main dest must be omitted when a shadow pool exists (F3 is the live flow): %+v", dests)
		}
		if _, ok := destByName(dests, "packiot_shadow"); !ok {
			t.Fatalf("packiot_shadow dest must be present: %+v", dests)
		}
	})
}

// TestStandard_MatchesFilteredTrue guards the back-compat wrapper: Standard
// must stay byte-identical to StandardFiltered(..., true) so the staging
// comparator layout is unchanged by the G3 flag work.
func TestStandard_MatchesFilteredTrue(t *testing.T) {
	pool := nonNilPool()
	shadow := nonNilPool()

	for _, sp := range []*pgxpool.Pool{nil, shadow} {
		got := Standard(pool, sp)
		want := StandardFiltered(pool, sp, true)
		if len(got) != len(want) {
			t.Fatalf("len mismatch: Standard=%d StandardFiltered(true)=%d", len(got), len(want))
		}
		for i := range got {
			if got[i] != want[i] {
				t.Fatalf("dest[%d] mismatch: %+v vs %+v", i, got[i], want[i])
			}
		}
	}
}
