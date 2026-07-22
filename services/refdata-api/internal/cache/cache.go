// Package cache is the fail-open, tenant-fenced cache-aside layer for the
// refdata-api read plane (ADR-0035).
//
// WHY IT EXISTS
// ─────────────
// front4 dashboards POLL the /v1/query dataset endpoints on a refresh tick, so
// many browser clients of the SAME tenant repeatedly issue the SAME dataset
// read between two cagg refreshes. Those reads all hit the same h_piot_* SQL
// functions on the analytics DB. A short-TTL cache-aside in front of the query
// dispatch collapses that fan-in to one DB hit per (tenant, dataset, params)
// per TTL window — the DB load drops, the poll latency drops, and — crucially —
// the freshness the operator sees is bounded by the TTL, which is chosen per
// dataset to match the underlying data's own update cadence (datasets.go).
//
// THREE INVARIANTS (all non-negotiable, all tested):
//
//  1. TENANT-KEY ISOLATION. The cache key embeds the SERVER-RESOLVED
//     id_enterprise as an explicit segment (DatasetKey). A key collision across
//     tenants would be a cross-tenant data leak — the worst failure this layer
//     could have — so the enterprise is a literal prefix, not merely folded into
//     the argument hash. Two tenants can never alias even under a hash collision.
//
//  2. FAIL-OPEN. Every cache operation degrades to "cache absent" on ANY error
//     (Redis down, timeout, network). A read is NEVER failed because the cache
//     is unavailable — the DB is always the source of truth and the fallback.
//
//  3. ADDITIVE / FLAG-GATED. Disabled (REDIS_CACHE_ENABLED=false) or a
//     per-dataset TTL of 0 ⇒ the layer is a transparent pass-through to the
//     loader. Nothing about the served bytes changes; only where they came from.
package cache

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"
)

// Cache is a thin cache-aside wrapper over a Redis backend. It is safe for
// concurrent use (the backend is; the Cache itself holds only immutable config).
type Cache struct {
	be        backend
	enabled   bool
	opTimeout time.Duration          // per-op ceiling: a hung Redis degrades to a miss within this budget
	reqs      *prometheus.CounterVec // refdata_cache_requests_total{result}
}

// Config is the cache-aside configuration, plumbed from env in main.go.
type Config struct {
	URL       string        // REDIS_URL, e.g. "redis://app-redis:6379/0"
	Enabled   bool          // REDIS_CACHE_ENABLED
	OpTimeout time.Duration // per-op ceiling; <=0 ⇒ default (150ms)
}

// backend is the minimal Redis surface Cache needs. Decoupling it from
// *redis.Client lets tests inject an in-memory / fault-injecting fake without
// standing up a real Redis, and keeps go-redis types out of the Cache logic.
type backend interface {
	get(ctx context.Context, key string) (val []byte, found bool, err error)
	set(ctx context.Context, key string, val []byte, ttl time.Duration) error
	ping(ctx context.Context) error
	close() error
}

// New builds a Cache. When cfg.Enabled is false it returns a valid, disabled
// Cache (every op is a bypass) and never dials Redis. Registering the metric is
// tolerant of a duplicate registration so the constructor is safe to call more
// than once against the same registry (tests, hot reload).
func New(cfg Config, reg prometheus.Registerer) (*Cache, error) {
	reqs := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "refdata_cache_requests_total",
		Help: "refdata cache-aside outcomes by result (hit|miss|error|bypass)",
	}, []string{"result"})
	if reg != nil {
		if err := reg.Register(reqs); err != nil {
			var are prometheus.AlreadyRegisteredError
			if errors.As(err, &are) {
				reqs = are.ExistingCollector.(*prometheus.CounterVec)
			} else {
				return nil, fmt.Errorf("register cache metric: %w", err)
			}
		}
	}
	// Touch every label up front so the series exist at 0 (Prometheus best
	// practice: a rate() over a never-incremented counter should read 0, not gap).
	for _, r := range []string{"hit", "miss", "error", "bypass"} {
		reqs.WithLabelValues(r).Add(0)
	}

	c := &Cache{enabled: cfg.Enabled, opTimeout: cfg.OpTimeout, reqs: reqs}
	if c.opTimeout <= 0 {
		c.opTimeout = 150 * time.Millisecond
	}
	if !cfg.Enabled {
		return c, nil // disabled: no client, every op is a bypass
	}
	opts, err := redis.ParseURL(cfg.URL)
	if err != nil {
		return nil, fmt.Errorf("parse REDIS_URL: %w", err)
	}
	c.be = &goRedisBackend{rdb: redis.NewClient(opts)}
	return c, nil
}

// Enabled reports whether the cache is on AND wired to a backend. Nil-safe: a
// nil *Cache (never constructed) reports disabled, so callers can hold a nil
// cache and every op transparently bypasses.
func (c *Cache) Enabled() bool { return c != nil && c.enabled && c.be != nil }

// Ping verifies the backend is reachable. Used once at startup for a log line;
// a failure is NON-fatal (fail-open) — the caller logs and carries on.
func (c *Cache) Ping(ctx context.Context) error {
	if !c.Enabled() {
		return nil
	}
	pctx, cancel := context.WithTimeout(ctx, c.opTimeout)
	defer cancel()
	return c.be.ping(pctx)
}

// Close releases the backend connection pool. Nil-safe (a nil/disabled cache
// holds no backend), so `defer cache.Close()` is always valid.
func (c *Cache) Close() error {
	if c == nil || c.be == nil {
		return nil
	}
	return c.be.close()
}

// GetOrLoad is the cache-aside primitive: return the cached bytes for key, or
// run loader (the DB query), cache its result under ttl, and return it.
//
//   - ttl <= 0, or the cache disabled ⇒ BYPASS: loader runs, nothing is cached.
//   - cache GET hit ⇒ return cached bytes; loader is NOT run.
//   - cache GET miss OR cache error ⇒ FAIL-OPEN: loader runs. A loader error is
//     the real DB error and is propagated (and never cached). A loader success
//     is cached best-effort (a SET error is swallowed) and returned.
//
// The loader receives the caller's ctx (its own DB timeout applies); the cache
// GET/SET each run under a short opTimeout so a slow Redis can never dominate
// the request.
func (c *Cache) GetOrLoad(ctx context.Context, key string, ttl time.Duration, loader func(context.Context) ([]byte, error)) ([]byte, error) {
	if !c.Enabled() || ttl <= 0 {
		c.mark("bypass")
		return loader(ctx)
	}
	gctx, cancel := context.WithTimeout(ctx, c.opTimeout)
	val, found, err := c.be.get(gctx, key)
	cancel()
	switch {
	case err == nil && found:
		c.mark("hit")
		return val, nil
	case err != nil:
		c.mark("error") // fail-open: fall through to the loader
	default:
		c.mark("miss")
	}

	val, lerr := loader(ctx)
	if lerr != nil {
		return nil, lerr // real source-of-truth error: propagate, do not cache
	}
	sctx, cancel2 := context.WithTimeout(ctx, c.opTimeout)
	_ = c.be.set(sctx, key, val, ttl) // best-effort; a write failure never fails the read
	cancel2()
	return val, nil
}

func (c *Cache) mark(result string) {
	if c == nil || c.reqs == nil {
		return
	}
	c.reqs.WithLabelValues(result).Inc()
}

// DatasetKey builds the cache key for a compiled dataset query. It is the
// load-bearing tenant fence (invariant #1):
//
//	refdata:ds:v1:<flow>:e<enterprise>:<dataset>:<argfingerprint>
//
// enterprise appears as an EXPLICIT segment — a hash collision in the fingerprint
// can therefore never serve one tenant's rows to another, because the prefix
// differs. flow (f1/f3) is included because the two flows read different DBs and
// may return different data for the same dataset+args; a Redis shared across
// flow deployments must not alias them. The fingerprint is a SHA-256 over the
// domain-separated (sql, args) — args carry the real per-request variation
// (window bounds, filters, the server-derived role/equipment), and folding sql
// in means a dataset whose SQL changes across a deploy self-busts its old keys.
//
// enterprise is the SERVER-RESOLVED id (customerIDFromContext), never a
// client-supplied value — the caller passes the same id it binds to $1.
func DatasetKey(enterprise int, flow, dataset, sql string, args []any) string {
	h := sha256.New()
	// Domain-separate each field with a NUL so concatenation can't alias
	// (e.g. dataset "a"+sql "bc" vs dataset "ab"+sql "c").
	fmt.Fprintf(h, "flow=%s\x00ds=%s\x00sql=%s\x00args=", flow, dataset, sql)
	// json.Marshal is deterministic for our arg types (int, string, bool,
	// time.Time→RFC3339, and pg array literals which are plain strings); errors
	// are impossible for those, but on the off chance one occurs we fall back to
	// a %v render so the key stays defined (and still fingerprints the args).
	if enc, err := json.Marshal(args); err == nil {
		h.Write(enc)
	} else {
		fmt.Fprintf(h, "%v", args)
	}
	sum := hex.EncodeToString(h.Sum(nil))[:32]
	return "refdata:ds:v1:" + flow + ":e" + strconv.Itoa(enterprise) + ":" + dataset + ":" + sum
}

// ── go-redis backend ─────────────────────────────────────────────────────────

type goRedisBackend struct{ rdb *redis.Client }

func (g *goRedisBackend) get(ctx context.Context, key string) ([]byte, bool, error) {
	b, err := g.rdb.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, false, nil // key absent — a clean miss, not an error
	}
	if err != nil {
		return nil, false, err
	}
	return b, true, nil
}

func (g *goRedisBackend) set(ctx context.Context, key string, val []byte, ttl time.Duration) error {
	return g.rdb.Set(ctx, key, val, ttl).Err()
}

func (g *goRedisBackend) ping(ctx context.Context) error { return g.rdb.Ping(ctx).Err() }
func (g *goRedisBackend) close() error                   { return g.rdb.Close() }
