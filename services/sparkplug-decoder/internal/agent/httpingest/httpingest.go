// Package httpingest is the sparkplug-agent's HTTP raw-tag front-door
// (ADR-0042 P1, Mode-A "direct-to-ingest"): a single authenticated,
// tenant-scoped `POST /v1/tags` endpoint that accepts the Tier-1 rawtag JSON
// envelope over HTTPS and feeds it into the SAME resolver→tagstore→session→
// uplink pipeline the internal MQTT subscriber uses.
//
// Why it exists: the full ADR-0042 architecture is
//
//	connectivity Node-RED ──MQTT(loopback)──▶ agent ──SparkPlug──▶ cloud
//
// For the FIRST staging proof we skip standing up a per-tenant connectivity
// Node-RED container and let CPACK's real Node-RED POST its raw tags straight
// at the agent (fewer moving parts). This endpoint is that tee front-door. It
// is strictly ADDITIVE — the MQTT subscriber path (rawmqtt) stays wired for
// Mode-B / the full architecture; an agent can run one, the other, or both.
//
// Auth model (mirrors services/ingest-shim/internal/httpserver, ADR-0004
// Layer-2): a shared `X-Ingest-Key` header, constant-time compared so a timing
// side-channel can't guess the key byte-by-byte. The key is supplied by
// reference (env from .env / Secrets Manager), NEVER inlined in compose. A
// missing/wrong key → 401. A body whose declared tenant `group` doesn't match
// the agent's configured scope → 403. A well-formed, in-scope envelope → 202.
//
// The handler NEVER logs the key or the tag values — only the derived counts
// and byte size. Leaking either defeats the point of an internal broker.
package httpingest

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/numeric"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

// DefaultMaxBodyBytes caps one POST body. A rawtag scan for a whole tenant is
// small (tens of tags); 1 MiB is generous headroom and bounds memory per
// request (MaxBytesReader fails the read past the cap, never buffering more).
const DefaultMaxBodyBytes int64 = 1 << 20

// Sink consumes one decoded envelope's tags. It returns (accepted, total):
// `accepted` is how many tags resolved to a mapped metric and were applied to
// the tagstore; the remainder were dropped-with-metric as unmapped by the sink
// itself. main wires this to the SAME resolver→tagstore closure the internal
// MQTT subscriber uses, so the HTTP and MQTT front-doors share one pipeline.
type Sink func(tags []rawtag.RawTag) (accepted, total int)

// Config controls the front-door.
type Config struct {
	// APIKey is the expected X-Ingest-Key value. REQUIRED — an empty key
	// would disable auth, so New treats "" as a programming error (main
	// refuses to start the server without a key).
	APIKey string

	// ScopeGroup is the tenant this agent serves (e.g. "CPACK"). When set, a
	// request whose envelope declares a different `group` is refused 403.
	// Empty disables the scope check (single-tenant by construction — the
	// tag_map already drops foreign metrics).
	ScopeGroup string

	// MaxBodyBytes caps the request body; <=0 → DefaultMaxBodyBytes.
	MaxBodyBytes int64

	// Numeric, when non-nil, mounts the STACK-SIDE numeric-count-index
	// translation front-door POST /v1/counters (ADR-0045 §2.3 Option-B): it
	// accepts the legacy `counterData[{id,value}]` shape, translates each
	// numeric id → a canonical rawtag via the tenant's count-index table, and
	// feeds the SAME sink as /v1/tags. Nil ⇒ the endpoint is not mounted (a
	// non-numeric tenant), so the surface stays off unless a tenant needs it.
	Numeric *numeric.Translator

	// NumericUnmapped, when non-nil, counts legacy count ids seen on
	// /v1/counters that resolved to no canonical metric — the onboarding DQ
	// signal (ADR-0045 §2.4a "reject-don't-drop"). Optional.
	NumericUnmapped prometheus.Counter
}

// Outcome label values for the ingest counter (mirrors ingest-shim/metrics so
// dashboards read the same vocabulary).
const (
	OutcomeReceived      = "received"
	OutcomeAccepted      = "accepted"
	OutcomeRejectedAuth  = "rejected_auth"  // missing/wrong X-Ingest-Key → 401
	OutcomeRejectedScope = "rejected_scope" // out-of-scope group → 403
	OutcomeRejectedBad   = "rejected_bad"   // unreadable/too-large/undecodable → 400
)

// Server is the HTTP front-door. It is an http.Handler; main mounts it on the
// ingest listener (a separate port from /healthz).
type Server struct {
	apiKey          []byte
	scopeGroup      string
	maxBody         int64
	sink            Sink
	outcomes        *prometheus.CounterVec
	numeric         *numeric.Translator
	numericUnmapped prometheus.Counter
	logger          *slog.Logger
}

// New builds the handler. outcomes is a CounterVec with a single "outcome"
// label, registered by the caller (so the agent owns its registry); pass a
// throwaway vec in tests. A blank APIKey panics — auth must never be optional.
func New(cfg Config, sink Sink, outcomes *prometheus.CounterVec, logger *slog.Logger) *Server {
	if cfg.APIKey == "" {
		panic("httpingest: APIKey is required (refusing to serve with auth disabled)")
	}
	if sink == nil {
		panic("httpingest: Sink is required")
	}
	maxBody := cfg.MaxBodyBytes
	if maxBody <= 0 {
		maxBody = DefaultMaxBodyBytes
	}
	return &Server{
		apiKey:          []byte(cfg.APIKey),
		scopeGroup:      strings.ToUpper(strings.TrimSpace(cfg.ScopeGroup)),
		maxBody:         maxBody,
		sink:            sink,
		outcomes:        outcomes,
		numeric:         cfg.Numeric,
		numericUnmapped: cfg.NumericUnmapped,
		logger:          logger,
	}
}

// Handler returns the routed mux (POST /v1/tags always; POST /v1/counters only
// when a numeric translator is configured). /healthz stays on the agent's
// health server.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/tags", s.handleTags)
	if s.numeric != nil {
		mux.HandleFunc("POST /v1/counters", s.handleCounters)
	}
	return mux
}

func (s *Server) inc(outcome string) {
	if s.outcomes != nil {
		s.outcomes.WithLabelValues(outcome).Inc()
	}
}

func (s *Server) handleTags(w http.ResponseWriter, r *http.Request) {
	s.inc(OutcomeReceived)

	// 1. Auth — constant-time compare. A missing header hashes to a
	//    zero-length slice which never matches a non-empty key.
	got := []byte(r.Header.Get("X-Ingest-Key"))
	if subtle.ConstantTimeCompare(got, s.apiKey) != 1 {
		s.reject(w, http.StatusUnauthorized, OutcomeRejectedAuth, "unauthorized", "", 0)
		return
	}

	// 2. Read under a hard cap. MaxBytesReader fails the read once the limit
	//    is exceeded, so we never buffer an unbounded body.
	r.Body = http.MaxBytesReader(w, r.Body, s.maxBody)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "payload too large", "", int64(len(body)))
			return
		}
		s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "cannot read body", "", int64(len(body)))
		return
	}
	if len(body) == 0 {
		s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "empty body", "", 0)
		return
	}

	// 3. Scope guard — a lenient probe reads the optional top-level `group`
	//    (a superset of the rawtag envelope; rawtag ignores unknown fields).
	//    A declared group that isn't ours → 403. Absent group is accepted:
	//    the agent is physically single-tenant and the tag_map drops foreign
	//    metrics, but the tee SHOULD send group for defense-in-depth.
	if s.scopeGroup != "" {
		if g, ok := probeGroup(body); ok && !strings.EqualFold(g, s.scopeGroup) {
			s.reject(w, http.StatusForbidden, OutcomeRejectedScope, "out-of-scope group", g, int64(len(body)))
			return
		}
	}

	// 4. Decode the Tier-1 envelope.
	tags, err := rawtag.Decode(body)
	if err != nil {
		s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "undecodable envelope", "", int64(len(body)))
		return
	}

	// 5. Feed the shared pipeline. accepted<total means some tags were
	//    unmapped (dropped-with-metric inside the sink) — not an error; a
	//    connectivity plane may legitimately carry tags this agent ignores.
	accepted, total := s.sink(tags)
	s.inc(OutcomeAccepted)
	s.logger.Info("tags accepted",
		slog.Int("accepted", accepted),
		slog.Int("total", total),
		slog.Int("bytes", len(body)))
	writeJSON(w, http.StatusAccepted, `{"status":"accepted","accepted":`+itoa(accepted)+`,"total":`+itoa(total)+`}`)
}

// handleCounters is the STACK-SIDE numeric-count-index translation front-door
// (ADR-0045 §2.3 Option-B). It accepts the legacy `counterData[{id,value}]`
// shape a dumb tee forwards, translates each numeric id → a canonical rawtag via
// the tenant's count-index table, and feeds the SAME sink as /v1/tags — so a
// counters-only tenant that speaks no topic strings still lands canonical
// SparkPlug metrics at the cloud decoder (one ingest contract, ADR-0032). Auth /
// body-cap / scope guard mirror handleTags byte-for-byte.
func (s *Server) handleCounters(w http.ResponseWriter, r *http.Request) {
	s.inc(OutcomeReceived)

	got := []byte(r.Header.Get("X-Ingest-Key"))
	if subtle.ConstantTimeCompare(got, s.apiKey) != 1 {
		s.reject(w, http.StatusUnauthorized, OutcomeRejectedAuth, "unauthorized", "", 0)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, s.maxBody)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "payload too large", "", int64(len(body)))
			return
		}
		s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "cannot read body", "", int64(len(body)))
		return
	}
	if len(body) == 0 {
		s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "empty body", "", 0)
		return
	}

	if s.scopeGroup != "" {
		if g, ok := probeGroup(body); ok && !strings.EqualFold(g, s.scopeGroup) {
			s.reject(w, http.StatusForbidden, OutcomeRejectedScope, "out-of-scope group", g, int64(len(body)))
			return
		}
	}

	env, counters, err := numeric.DecodeEnvelope(body)
	if err != nil {
		s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "undecodable counter envelope", "", int64(len(body)))
		return
	}

	endpoint := env.Endpoint
	if endpoint == "" {
		endpoint = env.Gateway
	}
	tags, unmapped := s.numeric.Translate(counters, endpoint, env.EnvelopeTS())
	if s.numericUnmapped != nil && len(unmapped) > 0 {
		s.numericUnmapped.Add(float64(len(unmapped)))
	}

	// Feed the shared pipeline. accepted<len(tags) means a translated suffix was
	// still unmapped by the resolver (a raw_tag_map / translation-table skew —
	// should never happen since both derive from the same profile, but surfaced
	// not swallowed).
	accepted, total := s.sink(tags)
	s.inc(OutcomeAccepted)
	s.logger.Info("counters translated",
		slog.Int("counters", len(counters)),
		slog.Int("translated", len(tags)),
		slog.Int("accepted", accepted),
		slog.Int("resolver_total", total),
		slog.Int("unmapped_index", len(unmapped)),
		slog.Int("bytes", len(body)))
	writeJSON(w, http.StatusAccepted,
		`{"status":"accepted","counters":`+itoa(len(counters))+
			`,"translated":`+itoa(len(tags))+
			`,"accepted":`+itoa(accepted)+
			`,"unmapped_index":`+itoa(len(unmapped))+`}`)
}

// reject centralises the metric bump + structured log (never the key or tag
// values) + JSON response.
func (s *Server) reject(w http.ResponseWriter, status int, outcome, msg, group string, bytes int64) {
	s.inc(outcome)
	s.logger.Warn("request rejected",
		slog.String("outcome", outcome),
		slog.Int("status", status),
		slog.String("group", group),
		slog.Int64("bytes", bytes))
	writeJSON(w, status, `{"error":`+quote(msg)+`}`)
}

// groupProbe is a lenient view used only to read the tenant. The tee stamps a
// top-level `group` alongside the rawtag envelope fields; rawtag.Decode
// ignores it (encoding/json drops unknown keys), so the two coexist on one
// body.
type groupProbe struct {
	Group   string `json:"group"`
	GroupID string `json:"group_id"`
	Tenant  string `json:"tenant"`
}

// probeGroup returns the declared tenant and whether one was present.
func probeGroup(body []byte) (string, bool) {
	var p groupProbe
	if err := json.Unmarshal(body, &p); err != nil {
		return "", false
	}
	for _, cand := range []string{p.Group, p.GroupID, p.Tenant} {
		if s := strings.TrimSpace(cand); s != "" {
			return s, true
		}
	}
	return "", false
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

// itoa is a tiny non-negative int formatter (avoids strconv import churn for
// two counters that are always >= 0).
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
