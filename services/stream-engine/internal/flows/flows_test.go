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

// #252: the F1/F2/F3 shadow-comparison model is retired — Standard returns
// exactly ONE dest. With an analytics pool (staging) it is the medallion flow on
// packiot_analytics; without one (single-flow prod) it is the public flow on the
// main pool. No shadow_go_port dest exists any more.
func TestStandard_SingleLiveFlow(t *testing.T) {
	pool := nonNilPool()

	t.Run("analytics pool (staging) → packiot_analytics medallion flow only", func(t *testing.T) {
		shadow := nonNilPool()
		dests := Standard(pool, shadow)
		if len(dests) != 1 {
			t.Fatalf("want 1 dest (packiot_analytics only), got %d: %+v", len(dests), dests)
		}
		ps, ok := destByName(dests, "packiot_analytics")
		if !ok {
			t.Fatalf("packiot_analytics dest missing: %+v", dests)
		}
		if ps.Pool != shadow || ps.RefSchema != "core" || ps.SilverSchema != "silver" ||
			ps.GoldSchema != "gold" || ps.GrainSchema != "silver" || ps.ConfigSchema != "config" {
			t.Fatalf("packiot_analytics medallion schemas wrong: %+v", ps)
		}
		if _, ok := destByName(dests, "shadow_go_port"); ok {
			t.Fatalf("shadow_go_port dest must not exist (retired): %+v", dests)
		}
	})

	t.Run("no analytics pool (single-flow prod) → public flow on the main pool", func(t *testing.T) {
		dests := Standard(pool, nil)
		if len(dests) != 1 {
			t.Fatalf("want 1 dest (public), got %d: %+v", len(dests), dests)
		}
		pub, ok := destByName(dests, "public")
		if !ok {
			t.Fatalf("single-flow public main-pool dest missing: %+v", dests)
		}
		if pub.Pool != pool || pub.EvSchema != "public" || pub.RefSchema != "public" {
			t.Fatalf("public dest wrong: %+v", pub)
		}
		if _, ok := destByName(dests, "shadow_go_port"); ok {
			t.Fatalf("shadow_go_port dest must not exist (retired): %+v", dests)
		}
	})
}
