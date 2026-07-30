// Package sparkplug provides a thin Go wrapper for decoding Eclipse Tahu's
// Sparkplug B protobuf payload format.
//
// SPIKE STATUS (2026-06-30, ADR-0010 horizon):
// This is a proof-of-concept that edge-transformer can decode Sparkplug B
// payloads in Go with parity to Node-RED's existing SparkPlug subflow. No
// production wiring yet — pure feasibility check.
//
// Once validated, the decoder will be wired into a new MQTT subscriber that
// retires the Node-RED Sparkplug tab per ADR-0010 (see docs/adr/0010-*.md).
//
// The encoded shape is defined by Eclipse Tahu's canonical sparkplug_b.proto
// (vendored under internal/). We re-export the generated Payload type so
// callers don't need to import the internal/internal subpath.
package sparkplug

import (
	"fmt"

	"google.golang.org/protobuf/proto"

	pb "github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug/internal"
)

// Payload is the decoded Sparkplug B message — a thin alias over the protobuf
// generated type. Sparkplug B uses proto2, so optional fields surface as
// pointer types and callers should use the Get*() accessors.
type Payload = pb.Payload

// Metric is the per-metric record inside a Payload.
type Metric = pb.Payload_Metric

// DataType enumerates the Sparkplug B value-type encoding (Int32=3, Float=9,
// String=12, etc.). The full mapping is in sparkplug_b.proto.
type DataType = pb.DataType

// DataType_value mirrors the protobuf-generated string→int32 lookup so callers
// can do `pb.DataType_value["Int64"]` without importing the internal package.
var DataType_value = pb.DataType_value

// Canonical Sparkplug B data type constants. Re-exported here so test + future
// production code can write `sparkplug.DataType_Int64` without touching the
// internal subpath.
const (
	DataType_Unknown = pb.DataType_Unknown
	DataType_Int8    = pb.DataType_Int8
	DataType_Int16   = pb.DataType_Int16
	DataType_Int32   = pb.DataType_Int32
	DataType_Int64   = pb.DataType_Int64
	DataType_UInt8   = pb.DataType_UInt8
	DataType_UInt16  = pb.DataType_UInt16
	DataType_UInt32  = pb.DataType_UInt32
	DataType_UInt64  = pb.DataType_UInt64
	DataType_Float   = pb.DataType_Float
	DataType_Double  = pb.DataType_Double
	DataType_Boolean = pb.DataType_Boolean
	DataType_String  = pb.DataType_String
)

// Metric variant types — re-exported so callers can construct test fixtures
// without importing the internal subpath. The proto2 oneof Value field uses
// these wrappers (Metric_LongValue{LongValue: 42}) to carry typed payloads.
type (
	Metric_IntValue     = pb.Payload_Metric_IntValue
	Metric_LongValue    = pb.Payload_Metric_LongValue
	Metric_FloatValue   = pb.Payload_Metric_FloatValue
	Metric_DoubleValue  = pb.Payload_Metric_DoubleValue
	Metric_BooleanValue = pb.Payload_Metric_BooleanValue
	Metric_StringValue  = pb.Payload_Metric_StringValue
)

// PropertySet + PropertyValue are the per-metric SparkPlug B property carrier
// (the `properties` field on a Metric). Re-exported so a producer can attach
// birth-only metric properties — the ADR-0046 definitive-birth counter_role /
// source_ref / device_key tags — without importing the internal subpath.
// PropertySet is parallel Keys[] + Values[]; each value is a typed oneof, the
// same shape as a Metric value (PropertyValue_StringValue{StringValue: v}).
type (
	PropertySet               = pb.Payload_PropertySet
	PropertyValue             = pb.Payload_PropertyValue
	PropertyValue_StringValue = pb.Payload_PropertyValue_StringValue
)

// Decode parses a binary Sparkplug B payload (as received over MQTT) into
// the canonical structure. Returns a wrapped error on protobuf failures.
//
// The input is the raw MQTT message body — NOT the MQTT topic, NOT the JSON
// representation. Sparkplug B is binary-only over the wire.
func Decode(body []byte) (*Payload, error) {
	var p Payload
	if err := proto.Unmarshal(body, &p); err != nil {
		return nil, fmt.Errorf("sparkplug: decode payload (%d bytes): %w", len(body), err)
	}
	return &p, nil
}

// Encode is the inverse — primarily used in tests and for producing fixtures.
// Production code should not need this (we are a consumer, not a producer).
func Encode(p *Payload) ([]byte, error) {
	body, err := proto.Marshal(p)
	if err != nil {
		return nil, fmt.Errorf("sparkplug: encode payload: %w", err)
	}
	return body, nil
}
