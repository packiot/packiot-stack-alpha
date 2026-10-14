package main

// Ingest front-door credentials (per-tenant keys, 2026-10-14).
//
//	AGENT_INGEST_API_KEY             legacy shared key (any group) — deprecated
//	AGENT_INGEST_LEGACY_KEY_ALLOWED  default true; false ⇒ the legacy key is 401
//	AGENT_INGEST_KEYS_SECRET_ID      Secrets Manager id of the key map JSON
//	AGENT_INGEST_KEYS_JSON           the same JSON inline (dev/tests; hashes only)
//
// The key map is {"<sha256-hex of key>": ["GROUP", ...]}; see
// internal/agent/httpingest/keyring.go. With nothing new set the agent behaves
// exactly as before (legacy key, any group), so merging this is a no-op until
// the map is provisioned.

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/httpingest"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/secrets"
)

// fetchIngestKeyMap is the Secrets Manager read, a package var so tests can
// stub it without AWS.
var fetchIngestKeyMap = func(ctx context.Context, region, secretID string) ([]byte, error) {
	raw, err := secrets.FetchJSON(ctx, region, secretID)
	if err != nil {
		return nil, err
	}
	return json.Marshal(raw)
}

// ingestAuth is the resolved front-door auth config.
type ingestAuth struct {
	legacyKey     string
	legacyAllowed bool
	keys          *httpingest.KeyRing
	source        string // where the key map came from (log only)
}

// loadIngestAuth reads the env above. It returns an error (main exits) when no
// credential could authenticate, when both map sources are set, or when the
// map cannot be fetched/parsed — a configured-but-broken map must fail loud,
// not silently fall back to the shared key.
func loadIngestAuth(ctx context.Context) (ingestAuth, error) {
	a := ingestAuth{
		legacyKey:     os.Getenv("AGENT_INGEST_API_KEY"),
		legacyAllowed: getenvBool("AGENT_INGEST_LEGACY_KEY_ALLOWED", true),
	}
	secretID := strings.TrimSpace(os.Getenv("AGENT_INGEST_KEYS_SECRET_ID"))
	inline := strings.TrimSpace(os.Getenv("AGENT_INGEST_KEYS_JSON"))
	var raw []byte
	switch {
	case secretID != "" && inline != "":
		return a, fmt.Errorf("set only one of AGENT_INGEST_KEYS_SECRET_ID and AGENT_INGEST_KEYS_JSON")
	case secretID != "":
		region := os.Getenv("AWS_REGION")
		if region == "" {
			region = "us-east-1"
		}
		fctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		b, err := fetchIngestKeyMap(fctx, region, secretID)
		if err != nil {
			return a, fmt.Errorf("ingest key map %s: %w", secretID, err)
		}
		raw, a.source = b, "secretsmanager:"+secretID
	case inline != "":
		raw, a.source = []byte(inline), "env:AGENT_INGEST_KEYS_JSON"
	}
	if raw != nil {
		ring, err := httpingest.ParseKeyRing(raw)
		if err != nil {
			return a, err
		}
		a.keys = ring
	}
	legacyUsable := a.legacyKey != "" && a.legacyAllowed
	if !legacyUsable && a.keys.Len() == 0 {
		if !a.legacyAllowed && a.legacyKey != "" {
			return a, fmt.Errorf("AGENT_INGEST_LEGACY_KEY_ALLOWED=false but no per-tenant key map is configured — refusing to serve ingest with no usable key")
		}
		return a, fmt.Errorf("AGENT_HTTP_INGEST_ENABLED=true but no ingest key is configured (AGENT_INGEST_API_KEY or a per-tenant key map) — refusing to serve ingest with auth disabled")
	}
	return a, nil
}

// config maps the resolved auth onto the httpingest config fields.
func (a ingestAuth) apply(cfg httpingest.Config) httpingest.Config {
	cfg.APIKey = a.legacyKey
	cfg.Keys = a.keys
	cfg.LegacyKeyDisabled = !a.legacyAllowed
	return cfg
}

// logSummary logs the auth posture (counts and groups, never keys) and, given
// the served groups, which tenants still have no per-tenant key.
func (a ingestAuth) logSummary(logger *slog.Logger, served []string) {
	bound := map[string]bool{}
	for _, g := range a.keys.Groups() {
		bound[g] = true
	}
	var unbound, unknown []string
	servedSet := map[string]bool{}
	for _, g := range served {
		g = strings.ToUpper(strings.TrimSpace(g))
		servedSet[g] = true
		if !bound[g] {
			unbound = append(unbound, g)
		}
	}
	for g := range bound {
		if !servedSet[g] {
			unknown = append(unknown, g)
		}
	}
	logger.Info("ingest auth",
		"per_tenant_keys", a.keys.Len(),
		"key_map_source", a.source,
		"legacy_key_configured", a.legacyKey != "",
		"legacy_key_allowed", a.legacyAllowed,
		"groups_with_key", strings.Join(a.keys.Groups(), ","))
	if len(unbound) > 0 {
		if a.legacyAllowed && a.legacyKey != "" {
			logger.Warn("tenants without a per-tenant ingest key still rely on the deprecated shared key",
				"groups", strings.Join(unbound, ","))
		} else {
			logger.Warn("tenants without a per-tenant ingest key cannot post (legacy key disabled)",
				"groups", strings.Join(unbound, ","))
		}
	}
	if len(unknown) > 0 {
		logger.Warn("ingest keys bound to groups this agent does not serve", "groups", strings.Join(unknown, ","))
	}
}

const ingestOutcomesHelp = "HTTP raw-tag ingest requests by outcome (received|accepted|rejected_auth|rejected_scope|rejected_key_scope|rejected_bad|legacy_key). legacy_key counts admitted requests that used the deprecated shared key."
