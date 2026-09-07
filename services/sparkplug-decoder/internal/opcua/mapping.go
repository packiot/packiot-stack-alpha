package opcua

import (
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/clientconfig"
)

// FindEndpoint returns the plc.endpoints entry named `name`. The opcua-reader
// drives ONE server per process, so the operator selects which endpoint via env
// — exactly like s7.FindEndpoint / modbus.FindEndpoint.
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
// opcua_tag_map, in config order — the OPC-UA analogue of s7.Endpoints. The
// opcua-reader drives ALL of them when no single --endpoint is pinned.
func Endpoints(cfg *clientconfig.Config) []string {
	if cfg == nil {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	for _, m := range cfg.OPCUATagMap {
		if m.Endpoint == "" || seen[m.Endpoint] {
			continue
		}
		seen[m.Endpoint] = true
		out = append(out, m.Endpoint)
	}
	return out
}

// TagsForEndpoint compiles the tenant's opcua_tag_map entries for one endpoint
// into poller Tags. The full SparkPlug metric name is <packml_topic><tag.metric>;
// aliases are assigned 1..N in config order (stable within a boot — the NBIRTH
// binds name↔alias). Config validation (clientconfig.validateV11) has already
// checked types/prefixes/node-ids, so the parse switch here is total.
func TagsForEndpoint(cfg *clientconfig.Config, endpoint string) ([]Tag, error) {
	if cfg == nil {
		return nil, fmt.Errorf("opcua tag map: nil config")
	}
	var out []Tag
	var alias uint64
	for _, m := range cfg.OPCUATagMap {
		if m.Endpoint != endpoint {
			continue
		}
		for _, t := range m.Tags {
			ty, err := parseType(t.Type)
			if err != nil {
				return nil, fmt.Errorf("opcua tag %q: %w", t.Metric, err)
			}
			alias++
			out = append(out, Tag{
				Metric: m.PackMLTopic + t.Metric,
				Alias:  alias,
				NodeID: t.NodeID,
				Type:   ty,
				Long:   t.Long,
				Scale:  t.Scale,
			})
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("opcua tag map: no tags for endpoint %q", endpoint)
	}
	return out, nil
}

// parseType maps a client.yaml type token to the poller's Type.
func parseType(s string) (Type, error) {
	switch s {
	case "int":
		return TypeInt, nil
	case "float":
		return TypeFloat, nil
	case "bool":
		return TypeBool, nil
	case "string":
		return TypeString, nil
	default:
		return 0, fmt.Errorf("unknown opcua type %q (want int|float|bool|string)", s)
	}
}
