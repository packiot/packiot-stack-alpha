package s7

import (
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

// FindEndpoint returns the plc.endpoints entry named `name`. The s7-reader
// drives ONE PLC per process, so the operator selects which endpoint via env.
func FindEndpoint(cfg *clientconfig.Config, name string) (*clientconfig.PLCEndpoint, bool) {
	if cfg == nil || cfg.PLC == nil {
		return nil, false
	}
	for i := range cfg.PLC.Endpoints {
		if cfg.PLC.Endpoints[i].Name == name {
			return &cfg.PLC.Endpoints[i], true
		}
	}
	return nil, false
}

// Endpoints returns the DISTINCT endpoint names referenced by this tenant's
// s7_tag_map, in config order. The s7-reader drives ALL of them (one poller +
// one PLC connection each) when no single --endpoint is pinned — the multi-PLC
// path (e.g. CPACK's nine S7 cells). An endpoint with no s7_tag_map entry is not
// returned, so a mixed-protocol client.yaml yields only this reader's endpoints.
func Endpoints(cfg *clientconfig.Config) []string {
	if cfg == nil {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	for _, m := range cfg.S7TagMap {
		if m.Endpoint == "" || seen[m.Endpoint] {
			continue
		}
		seen[m.Endpoint] = true
		out = append(out, m.Endpoint)
	}
	return out
}

// TagsForEndpoint compiles the tenant's s7_tag_map entries for one endpoint
// into poller Tags. The full SparkPlug metric name is
// <packml_topic><tag.metric>; aliases are assigned 1..N in config order
// (stable within a boot — the NBIRTH binds name↔alias). Config validation
// (clientconfig.validateV11) has already checked types/prefixes, so the type
// switch here is total.
func TagsForEndpoint(cfg *clientconfig.Config, endpoint string) ([]Tag, error) {
	if cfg == nil {
		return nil, fmt.Errorf("s7 tag map: nil config")
	}
	var out []Tag
	var alias uint64
	for _, m := range cfg.S7TagMap {
		if m.Endpoint != endpoint {
			continue
		}
		for _, t := range m.Tags {
			ty, err := parseType(t.Type)
			if err != nil {
				return nil, fmt.Errorf("s7 tag %q: %w", t.Metric, err)
			}
			alias++
			out = append(out, Tag{
				Metric: m.PackMLTopic + t.Metric,
				Alias:  alias,
				DB:     t.DB,
				Offset: t.Offset,
				Bit:    t.Bit,
				Type:   ty,
				Long:   t.Long,
				Scale:  t.Scale,
			})
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("s7 tag map: no tags for endpoint %q", endpoint)
	}
	return out, nil
}

// parseType maps a client.yaml type token to the poller's S7 Type.
func parseType(s string) (Type, error) {
	switch s {
	case "int":
		return TypeInt, nil
	case "dint":
		return TypeDInt, nil
	case "real":
		return TypeReal, nil
	case "bool":
		return TypeBool, nil
	default:
		return 0, fmt.Errorf("unknown s7 type %q (want int|dint|real|bool)", s)
	}
}
