// Package clientconfig parses the per-customer client.yaml file (ADR-0009
// Phase 1, ADR-0004 config centralization). One YAML file per customer
// becomes the single source of truth for:
//
//   - the tenant identifier (used to drive per-tenant queue names +
//     per-tenant Prometheus labels — the silent-metric-coverage-gap fix
//     pattern; see services/oeecloud-worker/internal/amqp/topology.go)
//   - equipment mappings (Sparkplug topic → equipment id)
//   - shift schedules + integration targets
//   - references to AWS Secrets Manager secret IDs for the runtime creds
//
// NOT in this file (deliberate, per ADR-0009 Errata Correction 3):
//
//   - the actual secret values (DB passwords, API keys, cert bytes) —
//     those live in AWS Secrets Manager and are referenced by ID here.
//     The naming convention is `*_env: VAR_NAME` → matching key in the
//     SM secret JSON; CI lint enforces both sides.
//
// TODO(ADR-0009 Phase 2): expand the schema to cover the full ADR-0004
// surface (currently shipping the minimum needed for tenant discovery +
// shadow-mode boot). Spec must absorb `docs/clients/cpack.example.yaml`
// once that file lands.
//
// TODO(ADR-0009 Phase 2): add a `clientconfig.Watch(ctx, path)` that
// fsnotify-watches the YAML file and emits new snapshots on the returned
// channel. Today the loader is one-shot at boot — a config change
// requires a service restart, matching oeecloud-worker's behavior.
package clientconfig

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config is the parsed shape of client.yaml. Skeleton-minimum: just
// enough fields to drive tenant discovery + tag log lines. The full
// schema lands in ADR-0009 Phase 2 work alongside the cpack example.
type Config struct {
	// TenantID is the lowercased Sparkplug group_id. Matches what
	// services/oeecloud-worker/internal/tenants/discovery.go computes from
	// packml_register, so per-tenant queue names line up across both
	// services (no mismatched routing keys = no silent drops).
	TenantID string `yaml:"tenant_id"`

	// Customer is the human-readable name. Logged at boot for operator
	// sanity-checks ("yes, this binary booted with the right config").
	Customer string `yaml:"customer"`

	// Environment is one of "staging" | "production". Used today only for
	// log context; in Phase 2 it gates which SM secret-ID prefix is used.
	Environment string `yaml:"environment"`

	// Equipments is the static topic→equipment mapping. Empty in the
	// skeleton; Phase 2 fills it from packml_register exports or
	// CS-Admin onboarding output.
	Equipments []EquipmentMapping `yaml:"equipments,omitempty"`
}

// EquipmentMapping is one row of the topic↔equipment table — the same
// thing packml_register stores in the DB, lifted into git per ADR-0004.
type EquipmentMapping struct {
	PackMLTopic string `yaml:"packml_topic"`
	IDEquipment int    `yaml:"id_equipment"`
	IDUnit      int    `yaml:"id_unit,omitempty"`
}

// Load parses client.yaml from disk. Returns a useful error for the
// common failure modes (missing file, bad YAML, missing required field).
func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("validate %s: %w", path, err)
	}
	// Normalize: lowercased tenant id to match the per-tenant queue
	// naming convention used in internal/amqp/topology.go. CS Admin
	// often writes uppercase customer codes (CPACK, SIMCORP) so the
	// normalize step here saves a class of "almost-matches" bugs.
	cfg.TenantID = strings.ToLower(strings.TrimSpace(cfg.TenantID))
	return &cfg, nil
}

func (c *Config) validate() error {
	if strings.TrimSpace(c.TenantID) == "" {
		return fmt.Errorf("tenant_id is required")
	}
	if strings.TrimSpace(c.Customer) == "" {
		return fmt.Errorf("customer is required")
	}
	switch strings.ToLower(c.Environment) {
	case "staging", "production":
	case "":
		return fmt.Errorf("environment is required (staging|production)")
	default:
		return fmt.Errorf("environment=%q: must be staging or production", c.Environment)
	}
	return nil
}

// Tenants returns the single-element tenant list this transformer
// instance is responsible for. The skeleton ships ONE tenant per
// container — same factory-per-container model as edge-node-red today.
// Returned as a slice to match the shape oeecloud-worker's amqp.Consumer
// expects (it consumes from N per-tenant queues in one process; we
// consume from 1, but the topology code generalizes).
func (c *Config) Tenants() []string {
	return []string{c.TenantID}
}
