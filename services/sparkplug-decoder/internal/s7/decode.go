// Package s7 reads Siemens S7 PLC data blocks and turns configured tags into
// PackML/SparkPlug metrics — the real-client counterpart to plc-sim. It is an
// additive SparkPlug PRODUCER (publishes NBIRTH/NDATA over MQTT exactly like
// plc-sim and a real PLC edge would), so the entire edge-transformer
// decode→transform→publish pipeline consumes it unchanged.
//
// This file holds the pure, big-endian S7 value decoders. S7 (Step7) stores
// multi-byte numerics big-endian; REAL is IEEE-754 single precision. Kept
// dependency-free and bounds-checked so they unit-test against known byte
// buffers without a live PLC.
package s7

import (
	"encoding/binary"
	"math"
)

// Type is the S7 wire type of a tag — determines how many bytes to decode and
// how to interpret them.
type Type int

const (
	TypeInt  Type = iota // INT   — 2 bytes, signed big-endian (int16)
	TypeDInt             // DINT  — 4 bytes, signed big-endian (int32)
	TypeReal             // REAL  — 4 bytes, IEEE-754 single
	TypeBool             // BOOL  — 1 bit within a byte
)

// Width returns the byte span a value of this type occupies (1 for BOOL — the
// containing byte).
func (t Type) Width() int {
	switch t {
	case TypeInt:
		return 2
	case TypeDInt, TypeReal:
		return 4
	case TypeBool:
		return 1
	default:
		return 0
	}
}

// GetInt decodes a signed 16-bit big-endian INT at byte offset off.
func GetInt(b []byte, off int) (int16, bool) {
	if off < 0 || off+2 > len(b) {
		return 0, false
	}
	return int16(binary.BigEndian.Uint16(b[off:])), true
}

// GetDInt decodes a signed 32-bit big-endian DINT at byte offset off.
func GetDInt(b []byte, off int) (int32, bool) {
	if off < 0 || off+4 > len(b) {
		return 0, false
	}
	return int32(binary.BigEndian.Uint32(b[off:])), true
}

// GetReal decodes an IEEE-754 single-precision REAL at byte offset off.
func GetReal(b []byte, off int) (float32, bool) {
	if off < 0 || off+4 > len(b) {
		return 0, false
	}
	return math.Float32frombits(binary.BigEndian.Uint32(b[off:])), true
}

// GetBool decodes a single bit (0..7) within the byte at offset off. S7 numbers
// bits LSB-first, so bit 0 is 0x01.
func GetBool(b []byte, off, bit int) (bool, bool) {
	if off < 0 || off >= len(b) || bit < 0 || bit > 7 {
		return false, false
	}
	return b[off]&(1<<uint(bit)) != 0, true
}

// decodeFloat reads a tag's raw value from buf and returns it as a float64
// (the common currency for scaling + SparkPlug emission). ok is false when the
// buffer is too short for the tag's address — a config/DB-size mismatch.
func decodeFloat(buf []byte, t Tag) (float64, bool) {
	switch t.Type {
	case TypeInt:
		v, ok := GetInt(buf, t.Offset)
		return float64(v), ok
	case TypeDInt:
		v, ok := GetDInt(buf, t.Offset)
		return float64(v), ok
	case TypeReal:
		v, ok := GetReal(buf, t.Offset)
		return float64(v), ok
	case TypeBool:
		v, ok := GetBool(buf, t.Offset, t.Bit)
		if v {
			return 1, ok
		}
		return 0, ok
	default:
		return 0, false
	}
}
