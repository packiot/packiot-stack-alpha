// Package agentcfg is the sparkplug-agent's focused config (ADR-0042 §5): a
// standalone YAML descriptor for the MVP rather than bolting onto the larger
// clientconfig schema. It carries the SparkPlug session identity (group_id,
// edge_node_id), the internal + uplink broker URLs, uplink mTLS cert
// references, and the raw_tag_map that binds each Tier-1 metric SUFFIX to a
// full packml name + SparkPlug type.
//
// Secrets discipline (ADR-0042 §6, ADR-0004 Layer-2): cert/key/CA are carried
// by REFERENCE only (secret://…). There is deliberately no inline-value field;
// validate() rejects a value smuggled through a *_ref field, so a leaked
// credential fails the config load (and, in P2, CI's flow-lint).
package agentcfg

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

const secretScheme = "secret://"

// Config is the parsed shape of the agent's YAML descriptor.
type Config struct {
	Sparkplug SparkplugCfg  `yaml:"sparkplug"`
	RawTagMap []TagMapEntry `yaml:"raw_tag_map"`
}

// SparkplugCfg is the session identity + transport wiring.
type SparkplugCfg struct {
	// GroupID / EdgeNodeID form the SparkPlug topic identity:
	// spBv1.0/<GroupID>/<Type>/<EdgeNodeID>. GroupID is the tenant.
	GroupID    string `yaml:"group_id"`
	EdgeNodeID string `yaml:"edge_node_id"`

	// PackMLTopic is the tenant-scoped prefix prepended to every raw-tag
	// metric SUFFIX to form the full SparkPlug metric name (the s7/mapping.go
	// PackMLTopic+Metric discipline). Tier 1 never spells the full path.
	PackMLTopic string `yaml:"packml_topic"`

	// InternalBroker is the loopback MQTT URL the connectivity plane
	// publishes raw tags to (e.g. tcp://mosquitto:1883). No TLS — loopback.
	InternalBroker string `yaml:"internal_broker"`

	// RawTopic is the internal subscription filter (e.g. "edge/raw/#" or
	// "edge/tags/<tenant>/#"). Empty ⇒ DefaultRawTopic.
	RawTopic string `yaml:"raw_topic"`

	// UplinkBroker is the cloud edge-transformer's MQTT URL the agent
	// publishes SparkPlug B to (tcp:// for staging Mode A; ssl:// + the
	// cert refs below for Mode B mTLS).
	UplinkBroker string `yaml:"uplink_broker"`

	// Uplink mTLS material — secret references, never values (ADR-0042 §6
	// per-tenant CN). Empty on the staging loopback (Mode A). Loading the
	// referenced bytes is P2/Mode B; the refs are validated here today.
	UplinkTLSCertRef string `yaml:"uplink_tls_cert_ref"`
	UplinkTLSKeyRef  string `yaml:"uplink_tls_key_ref"`
	UplinkCARef      string `yaml:"uplink_ca_ref"`
}

// TagMapEntry binds one Tier-1 metric SUFFIX to its full packml name + type.
// Name is optional: when empty the full name is packml_topic + metric_suffix
// (the common case); an explicit Name overrides for tags whose full path
// diverges from the tenant prefix.
type TagMapEntry struct {
	MetricSuffix string `yaml:"metric_suffix"`
	Name         string `yaml:"name,omitempty"`
	// Type is the SparkPlug value type: double | float | long | int | bool |
	// string. It is authoritative over the wire's optional `long` hint.
	Type string `yaml:"type"`
}

// DefaultRawTopic is the internal subscription filter when unset.
const DefaultRawTopic = "edge/raw/#"

// FullName resolves the entry's full SparkPlug metric name against the given
// packml_topic prefix.
func (e TagMapEntry) FullName(prefix string) string {
	if e.Name != "" {
		return e.Name
	}
	return prefix + e.MetricSuffix
}

// Load parses the agent descriptor from disk and validates it.
func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("agentcfg: read %s: %w", path, err)
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("agentcfg: parse %s: %w", path, err)
	}
	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("agentcfg: validate %s: %w", path, err)
	}
	if cfg.Sparkplug.RawTopic == "" {
		cfg.Sparkplug.RawTopic = DefaultRawTopic
	}
	return &cfg, nil
}

func (c *Config) validate() error {
	s := c.Sparkplug
	if strings.TrimSpace(s.GroupID) == "" {
		return fmt.Errorf("sparkplug.group_id is required")
	}
	if strings.TrimSpace(s.EdgeNodeID) == "" {
		return fmt.Errorf("sparkplug.edge_node_id is required")
	}
	if strings.TrimSpace(s.InternalBroker) == "" {
		return fmt.Errorf("sparkplug.internal_broker is required")
	}
	if strings.TrimSpace(s.UplinkBroker) == "" {
		return fmt.Errorf("sparkplug.uplink_broker is required")
	}
	for _, ref := range []struct{ field, val string }{
		{"uplink_tls_cert_ref", s.UplinkTLSCertRef},
		{"uplink_tls_key_ref", s.UplinkTLSKeyRef},
		{"uplink_ca_ref", s.UplinkCARef},
	} {
		if ref.val != "" && !strings.HasPrefix(ref.val, secretScheme) {
			return fmt.Errorf("sparkplug.%s=%q must be empty or a %s reference, not a value",
				ref.field, ref.val, secretScheme)
		}
	}
	if len(c.RawTagMap) == 0 {
		return fmt.Errorf("raw_tag_map is required (agent has no tags to map)")
	}
	seen := map[string]bool{}
	for i, e := range c.RawTagMap {
		if strings.TrimSpace(e.MetricSuffix) == "" {
			return fmt.Errorf("raw_tag_map[%d]: metric_suffix is required", i)
		}
		if seen[e.MetricSuffix] {
			return fmt.Errorf("raw_tag_map[%d]: duplicate metric_suffix %q", i, e.MetricSuffix)
		}
		seen[e.MetricSuffix] = true
		switch e.Type {
		case "double", "float", "long", "int", "bool", "string":
		default:
			return fmt.Errorf("raw_tag_map[%d] (%s): type=%q must be double|float|long|int|bool|string",
				i, e.MetricSuffix, e.Type)
		}
	}
	return nil
}

// TagMap indexes the raw_tag_map by metric suffix for O(1) resolution in the
// session builder.
func (c *Config) TagMap() map[string]TagMapEntry {
	m := make(map[string]TagMapEntry, len(c.RawTagMap))
	for _, e := range c.RawTagMap {
		m[e.MetricSuffix] = e
	}
	return m
}
