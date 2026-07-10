// Tests for the Modbus + OPC-UA tag-map sections of client.yaml — the
// multi-protocol siblings of the s7_tag_map lint rules in loader_test.go. Same
// contract: a valid map Loads; each rule rejects its own violation; a secret
// reference (endpoint_url_ref) is enforced like host_ref/dsn_ref.
package clientconfig

import "testing"

// modbusValid is a minimal Modbus tenant descriptor: one endpoint + a tag map
// spanning registers (holding/input), a 32-bit word-swapped value, and a coil.
const modbusValid = `
schema_version: "1.1"
tenant_id: cpack
customer: C-Pack
environment: staging
plc:
  protocol: modbus
  endpoints:
    - name: MACH_1
      host_ref: secret://cpack/plc/mach1
      unit_id: 1
modbus_tag_map:
  - endpoint: MACH_1
    packml_topic: CPACK/PLANT/LINE1/MACH_1/MACH_1
    id_equipment: 880001
    tags:
      - {metric: /Admin/Count, kind: holding, address: 0, type: uint32}
      - {metric: /Status/MachSpeed, kind: input, address: 10, type: float32, scale: 0.1, word_swap: true}
      - {metric: /Status/Running, kind: coil, address: 0}
`

// opcuaValid is a minimal OPC-UA tenant descriptor: one endpoint (URL by secret
// reference) + a tag map addressing nodes by NodeID.
const opcuaValid = `
schema_version: "1.1"
tenant_id: cpack
customer: C-Pack
environment: staging
plc:
  protocol: opcua
  endpoints:
    - name: MACH_1
      endpoint_url_ref: secret://cpack/plc/mach1-url
      security_policy: None
      security_mode: None
opcua_tag_map:
  - endpoint: MACH_1
    packml_topic: CPACK/PLANT/LINE1/MACH_1/MACH_1
    id_equipment: 880001
    tags:
      - {metric: /Admin/Count, node_id: "ns=2;s=Count", type: int}
      - {metric: /Status/MachSpeed, node_id: "ns=2;s=Speed", type: float, scale: 0.1}
      - {metric: /Status/Running, node_id: "ns=2;i=42", type: bool, long: true}
`

func TestLoadModbusTagMap_Valid(t *testing.T) {
	cfg, err := Load(writeConfig(t, modbusValid))
	if err != nil {
		t.Fatalf("valid modbus config must Load: %v", err)
	}
	if len(cfg.ModbusTagMap) != 1 || len(cfg.ModbusTagMap[0].Tags) != 3 {
		t.Fatalf("modbus_tag_map not parsed: %+v", cfg.ModbusTagMap)
	}
	if cfg.ModbusTagMap[0].Endpoint != "MACH_1" || cfg.ModbusTagMap[0].IDEquipment != 880001 {
		t.Fatalf("modbus map fields wrong: %+v", cfg.ModbusTagMap[0])
	}
	if !cfg.ModbusTagMap[0].Tags[1].WordSwap || cfg.ModbusTagMap[0].Tags[1].Scale != 0.1 {
		t.Fatalf("word_swap/scale not parsed: %+v", cfg.ModbusTagMap[0].Tags[1])
	}
	if cfg.PLC.Endpoints[0].UnitID == nil || *cfg.PLC.Endpoints[0].UnitID != 1 {
		t.Fatalf("unit_id not parsed as pointer: %v", cfg.PLC.Endpoints[0].UnitID)
	}
}

func TestLoadModbusTagMap_Invalid(t *testing.T) {
	cases := []struct{ name, body, wantErr string }{
		{"unknown endpoint", replace(modbusValid, "endpoint: MACH_1", "endpoint: GHOST"), "must reference a plc.endpoints"},
		{"wrong tenant prefix", replace(modbusValid, "packml_topic: CPACK", "packml_topic: WRONGTENANT"), "must equal tenant_id"},
		{"bad kind", replace(modbusValid, "kind: holding", "kind: register"), "must be holding|input|coil|discrete"},
		{"bad type", replace(modbusValid, "type: uint32", "type: real"), "must be uint16|int16|uint32|int32|float32|bool"},
		{"zero id_equipment", replace(modbusValid, "id_equipment: 880001", "id_equipment: 0"), "id_equipment must be > 0"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Load(writeConfig(t, tc.body))
			if err == nil || !contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestLoadOPCUATagMap_Valid(t *testing.T) {
	cfg, err := Load(writeConfig(t, opcuaValid))
	if err != nil {
		t.Fatalf("valid opcua config must Load: %v", err)
	}
	if len(cfg.OPCUATagMap) != 1 || len(cfg.OPCUATagMap[0].Tags) != 3 {
		t.Fatalf("opcua_tag_map not parsed: %+v", cfg.OPCUATagMap)
	}
	if cfg.OPCUATagMap[0].Tags[0].NodeID != "ns=2;s=Count" {
		t.Fatalf("node_id not parsed: %+v", cfg.OPCUATagMap[0].Tags[0])
	}
	if cfg.PLC.Endpoints[0].EndpointURLRef != "secret://cpack/plc/mach1-url" {
		t.Fatalf("endpoint_url_ref not parsed: %q", cfg.PLC.Endpoints[0].EndpointURLRef)
	}
}

func TestLoadOPCUATagMap_Invalid(t *testing.T) {
	cases := []struct{ name, body, wantErr string }{
		{"unknown endpoint", replace(opcuaValid, "endpoint: MACH_1", "endpoint: GHOST"), "must reference a plc.endpoints"},
		{"wrong tenant prefix", replace(opcuaValid, "packml_topic: CPACK", "packml_topic: WRONGTENANT"), "must equal tenant_id"},
		{"bad type", replace(opcuaValid, "type: int", "type: double"), "must be int|float|bool|string"},
		{"empty node_id", replace(opcuaValid, `node_id: "ns=2;s=Count"`, `node_id: ""`), "node_id is required"},
		{"url ref is a value not a secret", replace(opcuaValid, "endpoint_url_ref: secret://cpack/plc/mach1-url", "endpoint_url_ref: opc.tcp://10.0.0.5:4840"), "must be empty or a secret:// reference"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Load(writeConfig(t, tc.body))
			if err == nil || !contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

func replace(s, old, new string) string { return strings_Replace(s, old, new) }
