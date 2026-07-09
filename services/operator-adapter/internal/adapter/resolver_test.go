package adapter

import (
	"context"
	"errors"
	"testing"
	"time"
)

// newResolverWithQuery builds a PGResolver whose DB access is replaced by fn,
// so we can exercise the caching + unresolved/cross-tenant logic without a live
// Postgres. pool is left nil (Ping treats a nil pool as healthy).
func newResolverWithQuery(enterpriseID int, fn func(ctx context.Context, topic string, entID int) (Resolved, bool, error)) *PGResolver {
	return &PGResolver{
		enterpriseID: enterpriseID,
		ttl:          time.Minute,
		negTTL:       time.Minute,
		maxN:         maxResolverEntries,
		cache:        make(map[string]resolveEntry),
		queryFn:      fn,
	}
}

// A registered, active topic resolves to its staging ids — and a second call is
// served from cache (queryFn invoked exactly once).
func TestResolver_Resolves_AndCaches(t *testing.T) {
	calls := 0
	want := Resolved{IDEquipment: 120, CDMachine: "LINHA_D", IDArea: 22, IDSite: 11}
	r := newResolverWithQuery(4, func(_ context.Context, topic string, entID int) (Resolved, bool, error) {
		calls++
		if entID != 4 {
			t.Fatalf("resolver must forward its enterprise id to the query; got %d", entID)
		}
		return want, true, nil
	})

	got, err := r.ResolveTopic(context.Background(), "GRANADO/JAPERI/LINHA_D")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got != want {
		t.Fatalf("got %+v want %+v", got, want)
	}
	// Second call — must hit the cache, not the DB.
	if _, err := r.ResolveTopic(context.Background(), "GRANADO/JAPERI/LINHA_D"); err != nil {
		t.Fatalf("unexpected err on cached call: %v", err)
	}
	if calls != 1 {
		t.Fatalf("query should run once (then cache); ran %d times", calls)
	}
}

// An unknown topic (query returns ok=false) → ErrUnresolved, and the negative
// result is cached (no repeat DB hit).
func TestResolver_UnknownTopic_ErrUnresolved(t *testing.T) {
	calls := 0
	r := newResolverWithQuery(4, func(_ context.Context, _ string, _ int) (Resolved, bool, error) {
		calls++
		return Resolved{}, false, nil
	})

	_, err := r.ResolveTopic(context.Background(), "GRANADO/NOPE")
	if !errors.Is(err, ErrUnresolved) {
		t.Fatalf("want ErrUnresolved, got %v", err)
	}
	// Negative cache: a repeat lookup must not re-hit the DB.
	if _, err := r.ResolveTopic(context.Background(), "GRANADO/NOPE"); !errors.Is(err, ErrUnresolved) {
		t.Fatalf("want ErrUnresolved on cached miss, got %v", err)
	}
	if calls != 1 {
		t.Fatalf("negative result should be cached; query ran %d times", calls)
	}
}

// A cross-tenant topic is invisible to the query (the WHERE s.id_enterprise=$2
// guard excludes it), so the query returns no row → ErrUnresolved. This asserts
// the resolver forwards its configured enterprise so the guard can fire.
func TestResolver_CrossTenant_Rejected(t *testing.T) {
	r := newResolverWithQuery(4, func(_ context.Context, _ string, entID int) (Resolved, bool, error) {
		// Simulate the SQL guard: a topic under enterprise 7 returns no rows
		// when the resolver asks for enterprise 4.
		if entID != 4 {
			t.Fatalf("resolver forwarded wrong enterprise id: %d", entID)
		}
		return Resolved{}, false, nil // no row for this tenant → not resolved
	})

	_, err := r.ResolveTopic(context.Background(), "OTHERCO/LINE")
	if !errors.Is(err, ErrUnresolved) {
		t.Fatalf("cross-tenant topic must be rejected as ErrUnresolved, got %v", err)
	}
}

// A transport/DB error is surfaced as a plain error (NOT ErrUnresolved) so the
// handler answers 503 (retryable) rather than 422, and it is not negative-cached.
func TestResolver_DBError_NotUnresolved(t *testing.T) {
	dbErr := errors.New("dial tcp: connection refused")
	calls := 0
	r := newResolverWithQuery(4, func(_ context.Context, _ string, _ int) (Resolved, bool, error) {
		calls++
		return Resolved{}, false, dbErr
	})

	_, err := r.ResolveTopic(context.Background(), "GRANADO/L")
	if err == nil || errors.Is(err, ErrUnresolved) {
		t.Fatalf("DB error must be surfaced as a non-ErrUnresolved error, got %v", err)
	}
	// Not cached — a retry must hit the DB again.
	if _, err := r.ResolveTopic(context.Background(), "GRANADO/L"); err == nil {
		t.Fatalf("expected error on retry")
	}
	if calls != 2 {
		t.Fatalf("DB error must NOT be cached; query ran %d times (want 2)", calls)
	}
}

// An empty topic short-circuits to ErrUnresolved without touching the DB.
func TestResolver_EmptyTopic(t *testing.T) {
	r := newResolverWithQuery(4, func(_ context.Context, _ string, _ int) (Resolved, bool, error) {
		t.Fatal("query must not run for an empty topic")
		return Resolved{}, false, nil
	})
	if _, err := r.ResolveTopic(context.Background(), "   "); !errors.Is(err, ErrUnresolved) {
		t.Fatalf("empty topic must be ErrUnresolved, got %v", err)
	}
}
