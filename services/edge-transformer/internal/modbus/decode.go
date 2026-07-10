// Package modbus reads a Modbus TCP PLC and turns configured registers/coils
// into PackML/SparkPlug metrics — the Modbus sibling of the S7 reader
// (internal/s7). It is an additive SparkPlug PRODUCER (publishes NBIRTH/NDATA
// over MQTT exactly like plc-sim, the s7-reader, and a real SparkPlug PLC
// would), so the whole edge-transformer decode→transform→publish pipeline
// consumes it unchanged. CPACK runs S7 + Modbus TCP + OPC-UA across its lines;
// S7 shipped first, this is the Modbus half of the gap.
//
// This file holds the pure register/coil value decoders. Modbus data is
// organised in 16-bit "registers" transmitted BIG-ENDIAN (high byte first) —
// that byte order is fixed by the protocol. What the spec does NOT define is
// the WORD order of values that span two registers (uint32/int32/float32):
// vendors disagree on whether the FIRST register holds the high word (ABCD,
// "big-endian word order") or the low word (CDAB, "word-swapped"). We surface
// that as a per-tag WordSwap flag rather than guessing — a device-by-device
// truth you can only learn from the vendor's register map. Kept dependency-free
// and bounds-checked so they unit-test against known byte buffers without a
// live PLC, exactly like internal/s7/decode.go.
package modbus

import (
	"encoding/binary"
	"math"
)

// Kind is the Modbus address space a tag lives in. Each maps to a distinct
// function code, so tags of different kinds cannot share a batch read.
//
//   - holding  → Read Holding Registers (FC 3), read/write 16-bit registers
//   - input    → Read Input Registers   (FC 4), read-only 16-bit registers
//   - coil     → Read Coils             (FC 1), read/write 1-bit values
//   - discrete → Read Discrete Inputs   (FC 2), read-only 1-bit values
type Kind int

const (
	KindHolding  Kind = iota // FC 3 — holding registers
	KindInput                // FC 4 — input registers
	KindCoil                 // FC 1 — coils (bits)
	KindDiscrete             // FC 2 — discrete inputs (bits)
)

// IsBit reports whether the kind addresses single-bit values (coils/discrete
// inputs) rather than 16-bit registers. Bit spaces are read into PACKED bytes
// (coil N in bit N%8 of byte N/8, LSB-first) — a different decode path.
func (k Kind) IsBit() bool { return k == KindCoil || k == KindDiscrete }

// Type is the value encoding of a register tag — how many registers to decode
// and how to interpret them. Bit-space tags (coil/discrete) ignore Type.
type Type int

const (
	TypeUint16  Type = iota // 1 register, unsigned 16-bit big-endian
	TypeInt16               // 1 register, signed 16-bit big-endian
	TypeUint32              // 2 registers, unsigned 32-bit (word order per WordSwap)
	TypeInt32               // 2 registers, signed 32-bit (word order per WordSwap)
	TypeFloat32             // 2 registers, IEEE-754 single (word order per WordSwap)
	TypeBool                // a coil/discrete bit (register width is meaningless)
)

// Regs returns how many 16-bit registers a value of this type occupies. Bit
// types return 1 (a single coil/discrete address) so the read-plan span math
// stays uniform.
func (t Type) Regs() int {
	switch t {
	case TypeUint16, TypeInt16:
		return 1
	case TypeUint32, TypeInt32, TypeFloat32:
		return 2
	case TypeBool:
		return 1
	default:
		return 0
	}
}

// GetUint16 decodes an unsigned 16-bit big-endian register at BYTE offset off.
func GetUint16(b []byte, off int) (uint16, bool) {
	if off < 0 || off+2 > len(b) {
		return 0, false
	}
	return binary.BigEndian.Uint16(b[off:]), true
}

// GetInt16 decodes a signed 16-bit big-endian register at byte offset off.
func GetInt16(b []byte, off int) (int16, bool) {
	v, ok := GetUint16(b, off)
	return int16(v), ok
}

// getU32 assembles the 32-bit word from two consecutive registers, honoring
// word order. wordSwap=false is ABCD (first register = high word, the Modbus
// "big-endian" convention); wordSwap=true is CDAB (first register = low word,
// what many PLCs — Schneider, some Siemens gateways — actually emit).
func getU32(b []byte, off int, wordSwap bool) (uint32, bool) {
	if off < 0 || off+4 > len(b) {
		return 0, false
	}
	hi := binary.BigEndian.Uint16(b[off:])   // first register
	lo := binary.BigEndian.Uint16(b[off+2:]) // second register
	if wordSwap {
		hi, lo = lo, hi
	}
	return uint32(hi)<<16 | uint32(lo), true
}

// GetUint32 decodes an unsigned 32-bit value across two registers.
func GetUint32(b []byte, off int, wordSwap bool) (uint32, bool) {
	return getU32(b, off, wordSwap)
}

// GetInt32 decodes a signed 32-bit value across two registers.
func GetInt32(b []byte, off int, wordSwap bool) (int32, bool) {
	v, ok := getU32(b, off, wordSwap)
	return int32(v), ok
}

// GetFloat32 decodes an IEEE-754 single-precision value across two registers.
func GetFloat32(b []byte, off int, wordSwap bool) (float32, bool) {
	v, ok := getU32(b, off, wordSwap)
	return math.Float32frombits(v), ok
}

// GetCoil decodes a single coil/discrete bit from a PACKED coil buffer. Modbus
// packs coil status LSB-first: coil 0 is bit 0 (0x01) of byte 0, coil 8 is bit
// 0 of byte 1. bit is the coil's index within the read block.
func GetCoil(b []byte, bit int) (bool, bool) {
	if bit < 0 {
		return false, false
	}
	byteIdx := bit / 8
	if byteIdx >= len(b) {
		return false, false
	}
	return b[byteIdx]&(1<<uint(bit%8)) != 0, true
}

// decodeFloat reads a tag's raw value from buf and returns it as a float64 (the
// common currency for scaling + SparkPlug emission). start is the first address
// of buf's read block, so the tag's position is (t.Address - start). ok is
// false when the buffer is too short — a config / device-map mismatch.
func decodeFloat(buf []byte, t Tag, start uint16) (float64, bool) {
	if t.Kind.IsBit() {
		v, ok := GetCoil(buf, int(t.Address)-int(start))
		if v {
			return 1, ok
		}
		return 0, ok
	}
	// Register spaces: byte offset = register distance × 2.
	off := (int(t.Address) - int(start)) * 2
	switch t.Type {
	case TypeUint16:
		v, ok := GetUint16(buf, off)
		return float64(v), ok
	case TypeInt16:
		v, ok := GetInt16(buf, off)
		return float64(v), ok
	case TypeUint32:
		v, ok := GetUint32(buf, off, t.WordSwap)
		return float64(v), ok
	case TypeInt32:
		v, ok := GetInt32(buf, off, t.WordSwap)
		return float64(v), ok
	case TypeFloat32:
		v, ok := GetFloat32(buf, off, t.WordSwap)
		return float64(v), ok
	default:
		return 0, false
	}
}
