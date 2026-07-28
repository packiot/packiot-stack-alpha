// Package onboardapi is the ADR-0045 P1 config-as-data CONTROL-PLANE front-door:
// a single authenticated `POST /v1/onboard/generate` endpoint that turns one
// client descriptor (the CS-Admin SSoT) into the four downstream onboarding
// artifacts over the wire, so edge-api (and later the CS-Admin UI) can generate a
// tenant's config from a descriptor without a shell on the box.
//
// Single generation path
// -----------------------
// The handler does NOT reimplement generation. It parses the descriptor through
// clientdescriptor.Parse (the same core Load uses for a file) and calls
// Descriptor.Generate — the EXACT function the `onboard-gen` CLI calls. The CLI
// and this endpoint therefore emit byte-identical artifacts from the same
// descriptor (ADR-0045 §2.2 "generate, never hand-edit"; a single source of truth
// can't drift between two callers).
//
// Auth model (mirrors httpingest / ingest-shim, ADR-0004 Layer-2)
// ---------------------------------------------------------------
// This is an INTERNAL control-plane endpoint (edge-api calls it server-to-server),
// never world-open. It is gated by a shared bearer token:
//
//	Authorization: Bearer <ONBOARD_API_KEY>
//
// compared in constant time so a timing side-channel can't guess the key
// byte-by-byte. The key is supplied by reference (env from .env / Secrets
// Manager), never inlined. A missing/wrong token → 401. The whole endpoint is
// dark by default — main only mounts it when ONBOARD_API_ENABLED=true AND a key
// is present (enabled-but-keyless fails closed; auth is never optional).
//
// A malformed descriptor → 400 with the validation error (never a 500): the
// caller has authored a bad descriptor and needs to see why, not an opaque crash.
package onboardapi

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/clientdescriptor"
)

// DefaultMaxBodyBytes caps one descriptor POST body. A whole-tenant descriptor is
// small (hundreds of equipment rows at most); 4 MiB is generous headroom and
// bounds memory per request (MaxBytesReader fails the read past the cap).
const DefaultMaxBodyBytes int64 = 4 << 20

// Outcome label values for the request counter (mirrors httpingest's vocabulary
// so dashboards read the same words across the agent's HTTP surfaces).
const (
	OutcomeReceived     = "received"
	OutcomeGenerated    = "generated"     // descriptor generated OK → 200
	OutcomeRejectedAuth = "rejected_auth" // missing/wrong bearer token → 401
	OutcomeRejectedBad  = "rejected_bad"  // unreadable/too-large/malformed → 400
	OutcomeError        = "error"         // post-validate generation failure → 500
)

// Config controls the onboard front-door.
type Config struct {
	// APIKey is the expected bearer token. REQUIRED — an empty key would disable
	// auth, so New treats "" as a programming error (main refuses to serve
	// without a key).
	APIKey string

	// MaxBodyBytes caps the request body; <=0 → DefaultMaxBodyBytes.
	MaxBodyBytes int64
}

// Server is the HTTP control-plane front-door. It is an http.Handler; main mounts
// it on its own listener (separate from the tenant ingest port and /healthz).
type Server struct {
	apiKey   []byte
	maxBody  int64
	outcomes *prometheus.CounterVec
	logger   *slog.Logger
}

// New builds the handler. outcomes is a CounterVec with a single "outcome" label,
// registered by the caller; pass a throwaway vec (or nil) in tests. A blank
// APIKey panics — auth must never be optional.
func New(cfg Config, outcomes *prometheus.CounterVec, logger *slog.Logger) *Server {
	if cfg.APIKey == "" {
		panic("onboardapi: APIKey is required (refusing to serve with auth disabled)")
	}
	maxBody := cfg.MaxBodyBytes
	if maxBody <= 0 {
		maxBody = DefaultMaxBodyBytes
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Server{
		apiKey:   []byte(cfg.APIKey),
		maxBody:  maxBody,
		outcomes: outcomes,
		logger:   logger,
	}
}

// Handler returns the routed mux (POST /v1/onboard/generate only).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/onboard/generate", s.handleGenerate)
	return mux
}

// ── response contract (Phase-1b consumes this) ───────────────────────────────

// GenerateResponse is the endpoint's success body. Artifacts are returned as
// STRINGS (the caller stores/applies them verbatim — profile YAML, register SQL,
// agent YAML, tee-node JSON); Validation reports cutover-readiness.
type GenerateResponse struct {
	Tenant     string     `json:"tenant"`
	Artifacts  Artifacts  `json:"artifacts"`
	Validation Validation `json:"validation"`
}

// Artifacts holds the four generated onboarding artifacts as strings.
type Artifacts struct {
	ProfileYAML string `json:"profile_yaml"`
	RegisterSQL string `json:"register_sql"`
	AgentYAML   string `json:"agent_yaml"`
	TeeNodeJSON string `json:"tee_node_json"`
}

// InferredIndex is one member whose count index is still inferred (not confirmed
// on a live tee): its canonical topic and the unconfirmed index value.
type InferredIndex struct {
	Topic string `json:"topic"`
	Index int    `json:"index"`
}

// Validation reports the ADR-0045 §2.4b cutover gate. CutoverEligible is false if
// ANY count index is inferred (mirrors the CLI's --cutover refusal). Unmapped
// lists any descriptor topics that synthesize no canonical metric.
type Validation struct {
	InferredCountIndices []InferredIndex `json:"inferred_count_indices"`
	CutoverEligible      bool            `json:"cutover_eligible"`
	Unmapped             []string        `json:"unmapped"`
}

type errorResponse struct {
	Error string `json:"error"`
}

func (s *Server) inc(outcome string) {
	if s.outcomes != nil {
		s.outcomes.WithLabelValues(outcome).Inc()
	}
}

func (s *Server) handleGenerate(w http.ResponseWriter, r *http.Request) {
	s.inc(OutcomeReceived)

	// 1. Auth — constant-time bearer compare. A missing/short header hashes to a
	//    slice that never matches a non-empty key.
	got := []byte(bearerToken(r.Header.Get("Authorization")))
	if subtle.ConstantTimeCompare(got, s.apiKey) != 1 {
		s.reject(w, http.StatusUnauthorized, OutcomeRejectedAuth, "unauthorized", 0)
		return
	}

	// 2. Read under a hard cap. MaxBytesReader fails the read once the limit is
	//    exceeded, so we never buffer an unbounded body.
	r.Body = http.MaxBytesReader(w, r.Body, s.maxBody)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "payload too large", int64(len(body)))
			return
		}
		s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "cannot read body", int64(len(body)))
		return
	}
	if len(body) == 0 {
		s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, "empty body", 0)
		return
	}

	// 3. Parse + validate the descriptor through the SAME core the CLI uses. A
	//    malformed/invalid descriptor is the caller's error → 400 with the reason
	//    (YAML parse error or a specific validation failure), never a 500. YAML
	//    and JSON bodies both decode here (JSON is a subset of YAML).
	d, err := clientdescriptor.Parse(body)
	if err != nil {
		s.reject(w, http.StatusBadRequest, OutcomeRejectedBad, err.Error(), int64(len(body)))
		return
	}

	// 4. Generate the four artifacts. We generate in DRAFT/observe mode
	//    (Cutover:false) so everything is always emitted; cutover-readiness is
	//    reported separately in the validation block — exactly what the CLI does
	//    (print everything; report inferred indices to stderr).
	art, err := d.Generate(clientdescriptor.GenerateOptions{Cutover: false})
	if err != nil {
		// A descriptor that Validate() accepted should always Generate; a failure
		// here is an internal generator fault, not a bad request → 500.
		s.inc(OutcomeError)
		s.logger.Error("onboard generate failed after validation", slog.String("err", err.Error()))
		writeJSON(w, http.StatusInternalServerError, errorResponse{Error: "generation failed: " + err.Error()})
		return
	}

	unmapped, err := d.UnmappedTopics()
	if err != nil {
		s.inc(OutcomeError)
		s.logger.Error("onboard unmapped-topics failed", slog.String("err", err.Error()))
		writeJSON(w, http.StatusInternalServerError, errorResponse{Error: "validation failed: " + err.Error()})
		return
	}

	// Build the validation block. Non-nil empty slices so the JSON is [] not null
	// — a stable shape for the Phase-1b consumer.
	inferred := []InferredIndex{}
	for _, ii := range d.InferredIndices() {
		inferred = append(inferred, InferredIndex{Topic: ii.Topic, Index: ii.Index})
	}
	if unmapped == nil {
		unmapped = []string{}
	}

	resp := GenerateResponse{
		Tenant: d.Tenant,
		Artifacts: Artifacts{
			ProfileYAML: string(art.ProfileYAML),
			RegisterSQL: art.RegisterSQL,
			AgentYAML:   string(art.AgentYAML),
			TeeNodeJSON: string(art.TeeSnippet),
		},
		Validation: Validation{
			InferredCountIndices: inferred,
			CutoverEligible:      len(inferred) == 0,
			Unmapped:             unmapped,
		},
	}

	s.inc(OutcomeGenerated)
	s.logger.Info("onboard artifacts generated",
		slog.String("tenant", d.Tenant),
		slog.Int("equipment", len(d.Equipment)),
		slog.Int("inferred_indices", len(inferred)),
		slog.Bool("cutover_eligible", resp.Validation.CutoverEligible),
		slog.Int("bytes_in", len(body)))
	writeJSON(w, http.StatusOK, resp)
}

// reject centralises the metric bump + structured log (never the token or the
// descriptor body) + JSON error response.
func (s *Server) reject(w http.ResponseWriter, status int, outcome, msg string, bytes int64) {
	s.inc(outcome)
	s.logger.Warn("onboard request rejected",
		slog.String("outcome", outcome),
		slog.Int("status", status),
		slog.Int64("bytes", bytes))
	writeJSON(w, status, errorResponse{Error: msg})
}

// bearerToken extracts the token from an "Authorization: Bearer <token>" header.
// It is case-insensitive on the scheme and tolerant of surrounding whitespace; a
// header without the Bearer scheme yields "" (which never matches a real key).
func bearerToken(header string) string {
	header = strings.TrimSpace(header)
	const prefix = "bearer "
	if len(header) < len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(header[len(prefix):])
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
