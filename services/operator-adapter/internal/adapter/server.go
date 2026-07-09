package adapter

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"
)

// edgePoster is the seam the tests mock — the real implementation is
// *edgeClient, but unit tests inject a fake to exercise 2xx/4xx/5xx/unreachable
// without a live edge-api.
type edgePoster interface {
	post(ctx context.Context, call *edgeCall) (*edgeResult, error)
}

// Config carries the runtime wiring. All values come from env at startup
// (see cmd/operator-adapter/main.go).
type Config struct {
	// OperatorAPIKey is the shared secret the tee node presents as
	// X-Ingest-Key. Compared in constant time.
	OperatorAPIKey string

	// EnterpriseID scopes the adapter to a single tenant (Incoplast). Sourced
	// from env INCOPLAST_ENTERPRISE_ID — never a literal in code (org rule:
	// no hardcoded enterprise ids).
	EnterpriseID int

	// TopicPrefix, if set, is the packml_topic root that identifies the tenant
	// (e.g. "GRANADO"). Used as a second scope gate and as the fallback when
	// the action body omits `enterprise`.
	TopicPrefix string
}

// Server is the adapter's HTTP surface.
type Server struct {
	cfg      Config
	edge     edgePoster
	resolver topicResolver
	metrics  *Metrics
	logger   *slog.Logger

	served atomic.Uint64
	failed atomic.Uint64
}

// NewServer wires a Server. Passing edge + resolver + metrics explicitly keeps
// the type test-friendly (fakes in, no globals).
func NewServer(cfg Config, edge edgePoster, resolver topicResolver, metrics *Metrics, logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	return &Server{cfg: cfg, edge: edge, resolver: resolver, metrics: metrics, logger: logger}
}

// Handler builds the routing mux. /metrics is attached by the caller (main)
// so the promhttp handler binds to the same registry the metrics were
// registered on.
func (s *Server) Handler() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/operator/downtime", s.handleDowntime)
	mux.HandleFunc("/operator/po", s.handlePO)
	mux.HandleFunc("/healthz", s.handleHealth)
	return mux
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	// Healthy only when the resolver's DB pool is reachable — the adapter
	// cannot map topics → ids without it, so a dead pool must fail the probe
	// (in addition to the process merely being up).
	if s.resolver != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := s.resolver.Ping(ctx); err != nil {
			s.logger.Warn("healthz: resolver DB pool unreachable", slog.String("err", err.Error()))
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"healthy": false, "db": false})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"healthy": true, "db": true})
}

// authOK compares the presented X-Ingest-Key against the configured secret in
// constant time. An empty configured key means "no key set" → always deny
// (fail closed: never run wide open by accident).
func (s *Server) authOK(r *http.Request) bool {
	if s.cfg.OperatorAPIKey == "" {
		return false
	}
	presented := r.Header.Get("X-Ingest-Key")
	if presented == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(presented), []byte(s.cfg.OperatorAPIKey)) == 1
}

// scopeOK enforces the tenant scope. Fails closed: if the action carries an
// enterprise id it must match; if it carries a topic and a prefix is
// configured, the topic must sit under it; and if neither can be positively
// confirmed, we reject.
func (s *Server) scopeOK(enterprise *int, topic string) bool {
	if enterprise != nil && *enterprise != s.cfg.EnterpriseID {
		return false
	}
	if s.cfg.TopicPrefix != "" && topic != "" && !strings.HasPrefix(topic, s.cfg.TopicPrefix) {
		return false
	}
	// Positive confirmation required.
	if enterprise != nil && *enterprise == s.cfg.EnterpriseID {
		return true
	}
	if s.cfg.TopicPrefix != "" && strings.HasPrefix(topic, s.cfg.TopicPrefix) {
		return true
	}
	return false
}

func (s *Server) handleDowntime(w http.ResponseWriter, r *http.Request) {
	const action = "downtime"
	if r.Method != http.MethodPost {
		s.reject(w, action, outcomeBadRequest, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !s.authOK(r) {
		s.reject(w, action, outcomeUnauthorized, http.StatusUnauthorized, "invalid or missing X-Ingest-Key")
		return
	}
	var req DowntimeRequest
	if err := decodeJSON(r, &req); err != nil {
		s.reject(w, action, outcomeBadRequest, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if !s.scopeOK(req.Enterprise, req.PackmlTopic) {
		s.reject(w, action, outcomeForbidden, http.StatusForbidden, "action is not scoped to the configured Incoplast enterprise")
		return
	}
	// Resolve packml_topic → staging ids (id_equipment + cd_machine). The tee
	// node only holds the topic; the adapter owns the topic→id mapping.
	resolved, ok := s.resolve(w, r.Context(), action, req.PackmlTopic)
	if !ok {
		return
	}
	req.IDEquipment = &resolved.IDEquipment
	req.CDMachine = resolved.CDMachine

	call, err := mapDowntime(&req, s.cfg.EnterpriseID)
	if err != nil {
		s.handleMapErr(w, action, err)
		return
	}
	s.forward(w, r.Context(), action, call)
}

func (s *Server) handlePO(w http.ResponseWriter, r *http.Request) {
	const action = "po"
	if r.Method != http.MethodPost {
		s.reject(w, action, outcomeBadRequest, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !s.authOK(r) {
		s.reject(w, action, outcomeUnauthorized, http.StatusUnauthorized, "invalid or missing X-Ingest-Key")
		return
	}
	var req PORequest
	if err := decodeJSON(r, &req); err != nil {
		s.reject(w, action, outcomeBadRequest, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if !s.scopeOK(req.Enterprise, req.PackmlTopic) {
		s.reject(w, action, outcomeForbidden, http.StatusForbidden, "action is not scoped to the configured Incoplast enterprise")
		return
	}
	// Resolve packml_topic → staging hierarchy ids (id_equipment/id_area/id_site).
	resolved, ok := s.resolve(w, r.Context(), action, req.PackmlTopic)
	if !ok {
		return
	}
	req.IDEquipment = &resolved.IDEquipment
	req.IDArea = &resolved.IDArea
	req.IDSite = &resolved.IDSite

	call, err := mapPO(&req, s.cfg.EnterpriseID)
	if err != nil {
		s.handleMapErr(w, action, err)
		return
	}
	s.forward(w, r.Context(), action, call)
}

// resolve maps a packml_topic to staging ids, writing the correct error
// response and returning ok=false when it cannot:
//
//	empty topic / unknown / inactive / cross-tenant / ambiguous -> 422 (ErrUnresolved)
//	DB / transport error                                        -> 503 (retryable)
//
// A 422 here means "the topic doesn't name a staging equipment for this
// tenant"; a 503 means "try again". Fail closed either way — we never guess an
// id.
func (s *Server) resolve(w http.ResponseWriter, ctx context.Context, action, packmlTopic string) (Resolved, bool) {
	if s.resolver == nil {
		s.reject(w, action, outcomeResolverError, http.StatusServiceUnavailable, "topic resolver is not configured")
		return Resolved{}, false
	}
	if strings.TrimSpace(packmlTopic) == "" {
		s.reject(w, action, outcomeUnresolved, http.StatusUnprocessableEntity, "packml_topic is required — the tee node must send the SparkPlug topic so the adapter can resolve the staging equipment")
		return Resolved{}, false
	}
	resolved, err := s.resolver.ResolveTopic(ctx, packmlTopic)
	if err == nil {
		return resolved, true
	}
	if errors.Is(err, ErrUnresolved) {
		s.reject(w, action, outcomeUnresolved, http.StatusUnprocessableEntity,
			fmt.Sprintf("topic %q did not resolve to a staging equipment (unknown, inactive, cross-tenant, or ambiguous in packml_register)", packmlTopic))
		return Resolved{}, false
	}
	// Transport/DB failure — retryable, not a permanent rejection.
	s.failed.Add(1)
	s.metrics.observe(action, outcomeResolverError)
	s.logger.Warn("topic resolution failed (DB)", slog.String("action", action), slog.String("err", err.Error()))
	writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "topic resolver unavailable"})
	return Resolved{}, false
}

func (s *Server) handleMapErr(w http.ResponseWriter, action string, err error) {
	if _, ok := err.(*unmappedError); ok {
		// 422: a required field could not be mapped. Fail closed — a wrong
		// write is worse than a rejected one.
		s.reject(w, action, outcomeUnmapped, http.StatusUnprocessableEntity, err.Error())
		return
	}
	s.reject(w, action, outcomeBadRequest, http.StatusBadRequest, err.Error())
}

// forward posts the mapped call to edge-api and translates the result:
//
//	edge-api unreachable  -> 503
//	edge 2xx              -> 202 Accepted (the write landed in user_logs)
//	edge 4xx              -> passthrough (same status + body)
//	edge 5xx              -> 502 Bad Gateway
func (s *Server) forward(w http.ResponseWriter, ctx context.Context, action string, call *edgeCall) {
	res, err := s.edge.post(ctx, call)
	if err != nil {
		s.failed.Add(1)
		s.metrics.observe(action, outcomeEdgeUnreachable)
		s.logger.Warn("edge-api unreachable", slog.String("action", action), slog.String("path", call.path))
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "edge-api unreachable"})
		return
	}

	switch {
	case res.statusCode >= 200 && res.statusCode < 300:
		s.served.Add(1)
		s.metrics.observe(action, outcomeAccepted)
		s.logger.Info("operator action forwarded",
			slog.String("action", action),
			slog.String("path", call.path),
			slog.Int("edge_status", res.statusCode))
		writeJSON(w, http.StatusAccepted, map[string]string{"status": "accepted"})

	case res.statusCode >= 400 && res.statusCode < 500:
		s.failed.Add(1)
		s.metrics.observe(action, outcomeEdge4xx)
		s.logger.Warn("edge-api rejected action",
			slog.String("action", action),
			slog.String("path", call.path),
			slog.Int("edge_status", res.statusCode))
		// Passthrough: surface edge-api's own status + body to the caller.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(res.statusCode)
		w.Write(res.body)

	default:
		s.failed.Add(1)
		s.metrics.observe(action, outcomeEdge5xx)
		s.logger.Error("edge-api server error",
			slog.String("action", action),
			slog.String("path", call.path),
			slog.Int("edge_status", res.statusCode))
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "edge-api error"})
	}
}

// reject writes an error response, records the metric, and bumps the failed
// counter. Bodies never echo request fields, so no PII leaks.
func (s *Server) reject(w http.ResponseWriter, action, outcome string, status int, msg string) {
	s.failed.Add(1)
	s.metrics.observe(action, outcome)
	writeJSON(w, status, map[string]string{"error": msg})
}

// decodeJSON decodes the request body into dst with a 1 MiB cap. Unknown
// fields are ALLOWED on purpose: operator payloads carry extra Node-RED
// metadata (socketid, SparkPlug_device, …) the adapter doesn't consume, and
// rejecting them would make the contract brittle against harmless additions.
func decodeJSON(r *http.Request, dst any) error {
	limited := http.MaxBytesReader(nil, r.Body, 1<<20)
	return json.NewDecoder(limited).Decode(dst)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
