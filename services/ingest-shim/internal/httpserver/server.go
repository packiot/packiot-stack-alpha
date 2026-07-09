// Package httpserver holds the shim's HTTP surface: the authenticated,
// scope-guarded /ingest/sparkplug endpoint and the /healthz probe.
//
// The handler NEVER logs the API key or the full payload — only the derived
// topic/group and the byte size. Leaking either would defeat the whole
// point of keeping the broker internal.
package httpserver

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/ingest-shim/internal/metrics"
)

// Publisher is the subset of the AMQP publisher the handler depends on.
// An interface so tests can inject a fake with deterministic confirm/nack
// behaviour without touching a broker.
type Publisher interface {
	Publish(ctx context.Context, body []byte) error
	Healthy() bool
}

// Deps are the handler's collaborators.
type Deps struct {
	APIKey       string
	MaxBodyBytes int64
	ScopeGroup   string
	Publisher    Publisher
	Metrics      *metrics.Metrics
	Logger       *slog.Logger
}

// New wires the routes and returns the http.Handler.
func New(d Deps) http.Handler {
	s := &server{d: d, apiKey: []byte(d.APIKey), scopeGroup: strings.ToUpper(d.ScopeGroup)}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /ingest/sparkplug", s.handleIngest)
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	return mux
}

type server struct {
	d          Deps
	apiKey     []byte
	scopeGroup string
}

func (s *server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	if s.d.Publisher.Healthy() {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"status":"ok"}`)
		return
	}
	w.WriteHeader(http.StatusServiceUnavailable)
	_, _ = io.WriteString(w, `{"status":"amqp_down"}`)
}

func (s *server) handleIngest(w http.ResponseWriter, r *http.Request) {
	s.d.Metrics.Inc(metrics.OutcomeReceived)

	// 1. Auth — constant-time compare so a timing side-channel can't be used
	//    to guess the key byte-by-byte. Missing header hashes to a
	//    zero-length slice which never matches a non-empty key.
	got := []byte(r.Header.Get("X-Ingest-Key"))
	if subtle.ConstantTimeCompare(got, s.apiKey) != 1 {
		s.reject(w, r, http.StatusUnauthorized, metrics.OutcomeRejectedAuth, "unauthorized", "", 0)
		return
	}

	// 2. Read the body under a hard cap. MaxBytesReader makes the read fail
	//    once the limit is exceeded, so we never buffer an unbounded body.
	r.Body = http.MaxBytesReader(w, r.Body, s.d.MaxBodyBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			s.reject(w, r, http.StatusBadRequest, metrics.OutcomeRejectedBad, "payload too large", "", int64(len(body)))
			return
		}
		s.reject(w, r, http.StatusBadRequest, metrics.OutcomeRejectedBad, "cannot read body", "", int64(len(body)))
		return
	}
	if len(body) == 0 {
		s.reject(w, r, http.StatusBadRequest, metrics.OutcomeRejectedBad, "empty body", "", 0)
		return
	}

	// 3. Scope guard — parse just enough JSON to read the topic/group first
	//    segment. Anything that isn't INCOPLAST (case-insensitive) is
	//    refused: the shim only admits Incoplast data.
	group, ok := extractGroup(body)
	if !ok {
		// Unparseable JSON or no topic/group anywhere → we cannot confirm
		// scope, so it's a bad payload, not a scope decision.
		s.reject(w, r, http.StatusBadRequest, metrics.OutcomeRejectedBad, "unparseable or topicless payload", "", int64(len(body)))
		return
	}
	if !strings.EqualFold(group, s.scopeGroup) {
		s.reject(w, r, http.StatusForbidden, metrics.OutcomeRejectedScope, "out-of-scope group", group, int64(len(body)))
		return
	}

	// 4. Publish VERBATIM with publisher confirms.
	if err := s.d.Publisher.Publish(r.Context(), body); err != nil {
		s.d.Metrics.Inc(metrics.OutcomePublishFailed)
		s.d.Logger.Error("publish failed",
			slog.String("group", group),
			slog.Int("bytes", len(body)),
			slog.String("err", err.Error()))
		writeJSON(w, http.StatusServiceUnavailable, `{"error":"publish failed"}`)
		return
	}

	s.d.Metrics.Inc(metrics.OutcomePublished)
	s.d.Logger.Info("published",
		slog.String("group", group),
		slog.Int("bytes", len(body)))
	writeJSON(w, http.StatusAccepted, `{"status":"accepted"}`)
}

// reject centralises the metric bump + structured log + JSON response for a
// rejected request. topic/bytes are logged when known; the API key and full
// payload are NEVER logged.
func (s *server) reject(w http.ResponseWriter, _ *http.Request, status int, outcome, msg, group string, bytes int64) {
	s.d.Metrics.Inc(outcome)
	s.d.Logger.Warn("request rejected",
		slog.String("outcome", outcome),
		slog.Int("status", status),
		slog.String("group", group),
		slog.Int64("bytes", bytes))
	writeJSON(w, status, `{"error":`+quote(msg)+`}`)
}

func writeJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}

func quote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// scopeProbe is a lenient view of the payload used only to find the
// topic/group. Fields are tried in order: an explicit top-level topic/group,
// then the first segment of the first metric name (SparkPlug topics look
// like "INCOPLAST/Site/Area/Machine/Status/StateCurrent").
type scopeProbe struct {
	Topic   string `json:"topic"`
	Group   string `json:"group"`
	GroupID string `json:"group_id"`
	Metrics []struct {
		Name string `json:"name"`
	} `json:"metrics"`
}

// extractGroup returns the group/topic first segment and whether one could
// be determined. Returns ok=false on invalid JSON or when no candidate
// field carries a segment.
func extractGroup(body []byte) (string, bool) {
	var p scopeProbe
	if err := json.Unmarshal(body, &p); err != nil {
		return "", false
	}
	for _, cand := range []string{p.Topic, p.Group, p.GroupID} {
		if seg := firstSegment(cand); seg != "" {
			return seg, true
		}
	}
	for _, m := range p.Metrics {
		if seg := firstSegment(m.Name); seg != "" {
			return seg, true
		}
	}
	return "", false
}

// firstSegment returns the part before the first '/', trimmed. Empty in →
// empty out.
func firstSegment(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if i := strings.IndexByte(s, '/'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}
