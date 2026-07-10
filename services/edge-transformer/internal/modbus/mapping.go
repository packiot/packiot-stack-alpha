package modbus

import (
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

// FindEndpoint returns the plc.endpoints entry named `name`. The modbus-reader
// drives ONE device per process, so the operator selects which endpoint via env
// — exactly like s7.FindEndpoint.
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

// TagsForEndpoint compiles the tenant's modbus_tag_map entries for one endpoint
// into poller Tags. The full SparkPlug metric name is <packml_topic><tag.metric>;
// aliases are assigned 1..N in config order (stable within a boot — the NBIRTH
// binds name↔alias). Config validation (clientconfig.validateV11) has already
// checked kinds/types/prefixes, so the parse switches here are total.
func TagsForEndpoint(cfg *clientconfig.Config, endpoint string) ([]Tag, error) {
	if cfg == nil {
		return nil, fmt.Errorf("modbus tag map: nil config")
	}
	var out []Tag
	var alias uint64
	for _, m := range cfg.ModbusTagMap {
		if m.Endpoint != endpoint {
			continue
		}
		for _, t := range m.Tags {
			kind, err := parseKind(t.Kind)
			if err != nil {
				return nil, fmt.Errorf("modbus tag %q: %w", t.Metric, err)
			}
			// Bit spaces carry no numeric type token; force TypeBool so the
			// poller's decode path is unambiguous.
			var ty Type
			if kind.IsBit() {
				ty = TypeBool
			} else if ty, err = parseType(t.Type); err != nil {
				return nil, fmt.Errorf("modbus tag %q: %w", t.Metric, err)
			}
			alias++
			out = append(out, Tag{
				Metric:   m.PackMLTopic + t.Metric,
				Alias:    alias,
				Kind:     kind,
				Address:  uint16(t.Address),
				Quantity: uint16(t.Quantity),
				Type:     ty,
				WordSwap: t.WordSwap,
				Long:     t.Long,
				Scale:    t.Scale,
			})
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("modbus tag map: no tags for endpoint %q", endpoint)
	}
	return out, nil
}

// parseKind maps a client.yaml kind token to the poller's Kind.
func parseKind(s string) (Kind, error) {
	switch s {
	case "holding":
		return KindHolding, nil
	case "input":
		return KindInput, nil
	case "coil":
		return KindCoil, nil
	case "discrete":
		return KindDiscrete, nil
	default:
		return 0, fmt.Errorf("unknown modbus kind %q (want holding|input|coil|discrete)", s)
	}
}

// parseType maps a client.yaml type token to the poller's Type. Register kinds
// only; bit kinds set TypeBool without a token (see TagsForEndpoint).
func parseType(s string) (Type, error) {
	switch s {
	case "uint16":
		return TypeUint16, nil
	case "int16":
		return TypeInt16, nil
	case "uint32":
		return TypeUint32, nil
	case "int32":
		return TypeInt32, nil
	case "float32":
		return TypeFloat32, nil
	case "bool":
		return TypeBool, nil
	default:
		return 0, fmt.Errorf("unknown modbus type %q (want uint16|int16|uint32|int32|float32|bool)", s)
	}
}
