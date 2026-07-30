// Package refdataresolver is the DB-backed birthbind.DeviceResolver (ADR-0046
// #19a). It resolves a producer-asserted device_key → id_equipment by asking
// refdata-api's internal endpoint (GET /internal/resolve-device), so the
// edge-transformer keeps its pgx-free default — the packml_register lookup (the
// identity SSoT, ADR-0009) stays behind refdata's pool, reached over HTTP.
//
// It satisfies birthbind.DeviceResolver structurally (Resolve(string)(int,bool))
// — no import of birthbind, so the seam stays decoupled and this package is
// trivially unit-testable against an httptest server.
//
// Caching. Birth is infrequent, but a device with many counter metrics triggers
// one Resolve per alias at each birth, and a rebirth storm (ADR-0042) can repeat
// them. So successful lookups are cached for a good while (positive TTL) and
// misses/errors only briefly (negative TTL) — long enough to spare refdata a
// burst, short enough that a freshly-registered device is picked up soon. The
// cache is keyed by device_key alone (the enterprise is fixed per resolver).
//
// Fail-closed. ANY non-happy outcome — 404, non-200, transport error, malformed
// body — returns ok=false, so the caller (birthbind.ApplyBirth) leaves the alias
// unbound and its later DDATA drops into a rebirth. An unresolved key is never
// guessed.
package refdataresolver

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"sync"
	"time"
)

// Config is the resolver's construction input. All fields come from config.go.
type Config struct {
	BaseURL      string        // refdata-api base, e.g. http://refdata-api:9104
	EnterpriseID int           // tenant scope for every lookup (?enterprise=)
	InternalKey  string        // shared secret → X-Internal-Key header
	PositiveTTL  time.Duration // cache lifetime for a resolved key
	NegativeTTL  time.Duration // cache lifetime for a miss/error
	HTTPTimeout  time.Duration // per-request timeout (0 ⇒ default 5s)
	Client       *http.Client  // optional; nil ⇒ one built from HTTPTimeout
	Logger       *slog.Logger  // optional; nil ⇒ slog.Default()
}

// Resolver is a caching HTTP DeviceResolver.
type Resolver struct {
	baseURL      string
	enterpriseID int
	internalKey  string
	posTTL       time.Duration
	negTTL       time.Duration
	client       *http.Client
	logger       *slog.Logger

	mu    sync.Mutex
	cache map[string]entry
}

// entry is one cached resolution: the id (valid only when ok), whether it
// resolved, and when the cache line expires.
type entry struct {
	id      int
	ok      bool
	expires time.Time
}

// New builds a Resolver. It never fails — a misconfiguration surfaces as
// fail-closed Resolve calls (ok=false), never a boot crash, because a resolver
// must not take the transformer down.
func New(cfg Config) *Resolver {
	timeout := cfg.HTTPTimeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	client := cfg.Client
	if client == nil {
		client = &http.Client{Timeout: timeout}
	}
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	posTTL := cfg.PositiveTTL
	if posTTL <= 0 {
		posTTL = 10 * time.Minute
	}
	negTTL := cfg.NegativeTTL
	if negTTL <= 0 {
		negTTL = 30 * time.Second
	}
	return &Resolver{
		baseURL:      cfg.BaseURL,
		enterpriseID: cfg.EnterpriseID,
		internalKey:  cfg.InternalKey,
		posTTL:       posTTL,
		negTTL:       negTTL,
		client:       client,
		logger:       logger,
		cache:        make(map[string]entry),
	}
}

// resolveResponse is the /internal/resolve-device 200 body.
type resolveResponse struct {
	IDEquipment int `json:"id_equipment"`
}

// Resolve implements birthbind.DeviceResolver: device_key → (id_equipment, ok).
// Cache-first; on a miss it calls refdata and caches the outcome (positive or
// negative). Fail-closed on every error path.
func (r *Resolver) Resolve(deviceKey string) (int, bool) {
	if deviceKey == "" {
		return 0, false
	}
	if id, ok, hit := r.fromCache(deviceKey); hit {
		return id, ok
	}
	id, ok := r.fetch(deviceKey)
	r.store(deviceKey, id, ok)
	return id, ok
}

// fromCache returns a live cache line, if any. hit=false ⇒ caller must fetch.
func (r *Resolver) fromCache(deviceKey string) (id int, ok, hit bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, present := r.cache[deviceKey]
	if !present || time.Now().After(e.expires) {
		return 0, false, false
	}
	return e.id, e.ok, true
}

// store caches an outcome with the TTL appropriate to its polarity.
func (r *Resolver) store(deviceKey string, id int, ok bool) {
	ttl := r.negTTL
	if ok {
		ttl = r.posTTL
	}
	r.mu.Lock()
	r.cache[deviceKey] = entry{id: id, ok: ok, expires: time.Now().Add(ttl)}
	r.mu.Unlock()
}

// fetch performs the actual HTTP GET. Any non-200-with-id outcome ⇒ ok=false.
func (r *Resolver) fetch(deviceKey string) (int, bool) {
	if r.baseURL == "" {
		r.logger.Warn("refdataresolver: no REFDATA_URL — cannot resolve", slog.String("device_key", deviceKey))
		return 0, false
	}
	// ADR-0046 resolve-by-device_key: device_key is globally unique (tenant-
	// prefixed), so a multi-tenant edge-transformer resolves ANY tenant's key
	// without an enterprise. enterpriseID>0 is only sent by a per-tenant caller
	// as a belt-and-suspenders filter.
	reqURL := fmt.Sprintf("%s/internal/resolve-device?device_key=%s",
		trimSlash(r.baseURL), url.QueryEscape(deviceKey))
	if r.enterpriseID > 0 {
		reqURL += fmt.Sprintf("&enterprise=%d", r.enterpriseID)
	}

	ctx, cancel := context.WithTimeout(context.Background(), r.client.Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		r.logger.Warn("refdataresolver: build request failed", slog.String("device_key", deviceKey), slog.String("err", err.Error()))
		return 0, false
	}
	if r.internalKey != "" {
		req.Header.Set("X-Internal-Key", r.internalKey)
	}

	resp, err := r.client.Do(req)
	if err != nil {
		r.logger.Warn("refdataresolver: request failed (fail-closed)", slog.String("device_key", deviceKey), slog.String("err", err.Error()))
		return 0, false
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))

	switch resp.StatusCode {
	case http.StatusOK:
		var out resolveResponse
		if err := json.Unmarshal(body, &out); err != nil || out.IDEquipment <= 0 {
			r.logger.Warn("refdataresolver: 200 with unusable body (fail-closed)",
				slog.String("device_key", deviceKey), slog.String("body", string(body)))
			return 0, false
		}
		r.logger.Debug("refdataresolver: resolved",
			slog.String("device_key", deviceKey), slog.Int("id_equipment", out.IDEquipment))
		return out.IDEquipment, true
	case http.StatusNotFound:
		// Expected miss: no active mapping. Negative-cached briefly.
		r.logger.Info("refdataresolver: device_key not mapped (rebirth on DDATA)",
			slog.String("device_key", deviceKey), slog.Int("enterprise", r.enterpriseID))
		return 0, false
	case http.StatusUnauthorized:
		r.logger.Warn("refdataresolver: 401 from refdata — check REFDATA_INTERNAL_KEY", slog.String("device_key", deviceKey))
		return 0, false
	default:
		r.logger.Warn("refdataresolver: unexpected status (fail-closed)",
			slog.String("device_key", deviceKey), slog.Int("status", resp.StatusCode))
		return 0, false
	}
}

// trimSlash drops a single trailing slash so baseURL + path never doubles it.
func trimSlash(s string) string {
	if len(s) > 0 && s[len(s)-1] == '/' {
		return s[:len(s)-1]
	}
	return s
}
