package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/httpingest"
)

func clearIngestEnv(t *testing.T) {
	for _, k := range []string{"AGENT_INGEST_API_KEY", "AGENT_INGEST_LEGACY_KEY_ALLOWED", "AGENT_INGEST_KEYS_SECRET_ID", "AGENT_INGEST_KEYS_JSON"} {
		t.Setenv(k, "")
	}
}

func TestLoadIngestAuth_DefaultsKeepLegacyBehaviour(t *testing.T) {
	clearIngestEnv(t)
	t.Setenv("AGENT_INGEST_API_KEY", "shared")
	a, err := loadIngestAuth(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	cfg := a.apply(httpingest.Config{})
	if cfg.APIKey != "shared" || cfg.LegacyKeyDisabled || cfg.Keys.Len() != 0 {
		t.Fatalf("unset new env must keep today's behaviour: %+v", cfg)
	}
}

func TestLoadIngestAuth_Errors(t *testing.T) {
	m := `{"` + httpingest.HashKey("k") + `":["CPACK"]}`
	for name, env := range map[string]map[string]string{
		"no key at all":           {},
		"legacy off, no map":      {"AGENT_INGEST_API_KEY": "shared", "AGENT_INGEST_LEGACY_KEY_ALLOWED": "false"},
		"both map sources":        {"AGENT_INGEST_KEYS_JSON": m, "AGENT_INGEST_KEYS_SECRET_ID": "x"},
		"map holds a raw key":     {"AGENT_INGEST_API_KEY": "shared", "AGENT_INGEST_KEYS_JSON": `{"raw-key":["CPACK"]}`},
		"secret fetch fails loud": {"AGENT_INGEST_API_KEY": "shared", "AGENT_INGEST_KEYS_SECRET_ID": "packiot/staging/agent-ingest-keys"},
	} {
		t.Run(name, func(t *testing.T) {
			clearIngestEnv(t)
			for k, v := range env {
				t.Setenv(k, v)
			}
			orig := fetchIngestKeyMap
			fetchIngestKeyMap = func(context.Context, string, string) ([]byte, error) { return nil, errors.New("AccessDenied") }
			defer func() { fetchIngestKeyMap = orig }()
			if _, err := loadIngestAuth(context.Background()); err == nil {
				t.Fatal("want error")
			} else if strings.Contains(err.Error(), "raw-key") {
				t.Fatalf("error leaks the map entry: %v", err)
			}
		})
	}
}

func TestLoadIngestAuth_SecretsManagerMapLegacyOff(t *testing.T) {
	clearIngestEnv(t)
	t.Setenv("AGENT_INGEST_KEYS_SECRET_ID", "packiot/staging/agent-ingest-keys")
	t.Setenv("AGENT_INGEST_LEGACY_KEY_ALLOWED", "false")
	orig := fetchIngestKeyMap
	var gotID string
	fetchIngestKeyMap = func(_ context.Context, _ string, id string) ([]byte, error) {
		gotID = id
		return []byte(`{"` + httpingest.HashKey("k1") + `":["CPACK"],"` + httpingest.HashKey("k2") + `":["incoplast"]}`), nil
	}
	defer func() { fetchIngestKeyMap = orig }()
	a, err := loadIngestAuth(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if gotID != "packiot/staging/agent-ingest-keys" || a.keys.Len() != 2 || a.legacyAllowed {
		t.Fatalf("got id=%q keys=%d legacyAllowed=%v", gotID, a.keys.Len(), a.legacyAllowed)
	}
}
