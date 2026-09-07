// internal.go — ADR-0046 #19a: the service-to-service device_key → id_equipment
// resolver.
//
// WHY IT EXISTS
// -------------
// The edge-transformer's birth-bound routing (ADR-0046 step 1) resolves a
// producer-asserted device_key to id_equipment via packml_register — the
// identity SSoT (ADR-0009). The transformer has no DB pool of its own (and must
// not grow one — it stays pgx-free by design), so the lookup is delegated to
// refdata-api, the read plane that already owns the pool + the reference tables.
// This endpoint is the seam behind edge-transformer's birthbind.DeviceResolver:
// when BIRTH_BOUND_RESOLVER=refdata, the transformer HTTP-GETs here at birth
// (infrequent) instead of consulting an operator-supplied static map.
//
// WHY IT NAMES THE ENTERPRISE EXPLICITLY (and is auth-exempt)
// ----------------------------------------------------------
// The tenant-injection middleware (ADR-0027, auth.go) forbids a client from
// naming a tenant — it derives customer_id from a browser/operator credential.
// That model does not fit a per-tenant infra daemon that already KNOWS its own
// enterprise id (from its client.yaml) and needs to resolve keys within it. So,
// exactly like the ADR-0031 external shims, this route is classified
// routeInternal: EXEMPT from the tenant middleware and SELF-authenticating via a
// shared internal secret. Fail-closed: an unset INTERNAL_API_KEY leaves the
// endpoint inert (every request 401s); a mismatched X-Internal-Key 401s. The
// returned datum (an id_equipment) is resolver plumbing, not tenant business
// data — but it is still gated, never open.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// resolveDeviceSQL is the identity lookup — packml_register is the SSoT
// (ADR-0009). device_key is tenant-prefixed (CPACK-…, BISNAGO-…) hence GLOBALLY
// unique — the global unique index db/init/10 adds (WHERE device_key IS NOT NULL)
// guarantees ≤1 active row for `device_key` alone, so a single multi-tenant
// edge-transformer resolves any tenant's key without knowing the enterprise
// (ADR-0046: resolve-by-device_key). `enterprise` remains an OPTIONAL
// belt-and-suspenders filter for a per-tenant caller. `active` fences
// soft-deleted registrations. Simple protocol (QueryExecModeSimpleProtocol is
// set pool-wide) so binds work under pgbouncer transaction pooling.
const resolveByKeySQL = `SELECT id_equipment FROM packml_register WHERE device_key = $1 AND active`
const resolveByKeyEntSQL = `SELECT id_equipment FROM packml_register WHERE device_key = $1 AND id_enterprise = $2 AND active`

// internalResolveTotal counts resolver outcomes so ops can graph hit/miss/deny
// rates alongside the RED metrics httpmetrics already emits for the route.
var internalResolveTotal = promauto.With(prometheus.DefaultRegisterer).NewCounterVec(
	prometheus.CounterOpts{
		Name: "refdata_internal_resolve_device_total",
		Help: "device_key → id_equipment resolutions on /internal/resolve-device, by result (hit|miss|unauthorized|bad_request|error).",
	},
	[]string{"result"},
)

// internalRoutes registers the ADR-0046 #19a internal endpoint in the shared
// route manifest (auth.go) so the isolation gate classifies it and the auth
// middleware exempts it (it self-authenticates). Listed here — one place per
// route family — mirroring infraRoutes / queryAPIRoutes.
var internalRoutes = []mountedRoute{
	{"/internal/resolve-device", routeInternal},
}

// registerInternalAPI mounts the internal resolver on the mux. The internal key
// is read ONCE at boot (env, never a request field). An empty key is a valid,
// fail-closed state: the handler 401s every request, so the endpoint ships inert
// until an operator sets INTERNAL_API_KEY (additive — a default deploy is
// unchanged).
func registerInternalAPI(mux *http.ServeMux, pool *pgxpool.Pool, logger *slog.Logger) {
	key := strings.TrimSpace(os.Getenv("INTERNAL_API_KEY"))
	mux.HandleFunc("/internal/resolve-device", resolveDeviceHandler(pool, key, logger))
	if key == "" {
		logger.Warn("internal resolver: INTERNAL_API_KEY unset — /internal/resolve-device is INERT (every request 401s)")
	} else {
		logger.Info("internal resolver enabled (ADR-0046 #19a)", slog.String("path", "/internal/resolve-device"))
	}
}

// resolveDeviceHandler serves GET /internal/resolve-device?enterprise=<id>&device_key=<k>.
//
//	200 {"id_equipment": <n>}  — a single active packml_register match.
//	404 {"error": "..."}       — no active mapping for (enterprise, device_key).
//	400                        — missing/invalid enterprise or device_key.
//	401                        — missing/mismatched X-Internal-Key (or key unset).
//	405                        — non-GET.
//	500                        — DB error.
func resolveDeviceHandler(pool *pgxpool.Pool, internalKey string, logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
			return
		}
		// Self-auth. An unset internalKey denies unconditionally (an empty
		// configured key must NOT equal an empty header — otherwise the endpoint
		// would silently open). Constant-time compare avoids a timing oracle on
		// the key.
		if internalKey == "" ||
			subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Internal-Key")), []byte(internalKey)) != 1 {
			internalResolveTotal.WithLabelValues("unauthorized").Inc()
			failed.Add(1)
			http.Error(w, `{"error":"missing or invalid internal credentials"}`, http.StatusUnauthorized)
			return
		}
		deviceKey := r.URL.Query().Get("device_key")
		if deviceKey == "" {
			internalResolveTotal.WithLabelValues("bad_request").Inc()
			failed.Add(1)
			http.Error(w, `{"error":"device_key is required"}`, http.StatusBadRequest)
			return
		}
		// enterprise is OPTIONAL (ADR-0046 resolve-by-device_key). If present it
		// must be a positive int (belt-and-suspenders filter for a per-tenant
		// caller); if absent we resolve by the globally-unique device_key alone.
		entRaw := r.URL.Query().Get("enterprise")
		var ent int
		if entRaw != "" {
			var perr error
			ent, perr = strconv.Atoi(entRaw)
			if perr != nil || ent <= 0 {
				internalResolveTotal.WithLabelValues("bad_request").Inc()
				failed.Add(1)
				http.Error(w, `{"error":"enterprise, when given, must be a positive integer"}`, http.StatusBadRequest)
				return
			}
		}

		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		var idEquipment int
		var err error
		if ent > 0 {
			err = pool.QueryRow(ctx, resolveByKeyEntSQL, deviceKey, ent).Scan(&idEquipment)
		} else {
			err = pool.QueryRow(ctx, resolveByKeySQL, deviceKey).Scan(&idEquipment)
		}
		if errors.Is(err, pgx.ErrNoRows) {
			// Fail-closed on the transformer side: an unmapped key drops the
			// counter into a rebirth. A 404 is the expected, non-error miss.
			internalResolveTotal.WithLabelValues("miss").Inc()
			failed.Add(1)
			http.Error(w, `{"error":"device_key not mapped to an active id_equipment"}`, http.StatusNotFound)
			return
		}
		if err != nil {
			internalResolveTotal.WithLabelValues("error").Inc()
			failed.Add(1)
			logger.Warn("internal resolve query failed",
				slog.Int("enterprise", ent), slog.String("device_key", deviceKey),
				slog.String("err", err.Error()))
			http.Error(w, `{"error":"query failed"}`, http.StatusInternalServerError)
			return
		}
		internalResolveTotal.WithLabelValues("hit").Inc()
		served.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]int{"id_equipment": idEquipment})
	}
}
