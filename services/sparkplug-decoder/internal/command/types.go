// Package command implements the edge command channel executor (ADR-0019 C1 /
// task G4) — the ONE machine-write path in the stack. An operator action in
// the cloud lands as a typed envelope on `edge.commands.<tenant>`; this package
// consumes it, translates the verb to a SparkPlug DCMD (device command — the
// inverse of the ingest decoder), publishes the DCMD to the PLC over MQTT, and
// publishes a delivered|rejected ack to `edge.commands.<tenant>.ack`.
//
// The discipline here is HIGHER than the ingest side because a write actuates
// a physical machine (design doc §Safety):
//
//   - Allow-list only    — a verb not in the configured set is REJECTED, never
//     guessed at.
//   - Fail-safe on ambiguity — if the verb→DCMD mapping is unmapped or the
//     params are incomplete, REJECT (DLX). Contrast ingest, which fail-soft
//     zero-fills; a write must never emit a partial or guessed value.
//   - Idempotent         — a re-delivered idempotencyKey does NOT re-issue the
//     DCMD (a replayed PLC write is a physical action taken twice).
//   - Gated              — the consumer only runs when EDGE_COMMANDS_ENABLED=true.
//     Ships inert.
//
// The package is split so the executor + translation + safety rules are pure
// and unit-testable behind interfaces (DevicePublisher, AckPublisher) with no
// live broker required.
package command

import "time"

// Verb identifiers. These mirror the ADR-0019 capabilities.commands.allowed
// contract. Only verbs present in BOTH this set AND the runtime allow-list
// translate to a write.
const (
	VerbParamWrite = "param_write"
	VerbPOSetup    = "po_setup"
)

// Command is the typed envelope published to `edge.commands.<tenant>` by the
// edge-api producer (follow-up) and consumed here.
//
// Params is intentionally a free-form map: each verb documents which keys it
// requires (see dcmd.go). A verb that finds its required keys missing REJECTS
// rather than defaulting — the fail-safe rule.
type Command struct {
	Tenant         string         `json:"tenant"`
	IDEquipment    int            `json:"idEquipment"`
	PackmlTopic    string         `json:"packmlTopic"`
	Verb           string         `json:"verb"`
	Params         map[string]any `json:"params"`
	IdempotencyKey string         `json:"idempotencyKey"`
}

// Outcome is the executor's terminal verdict for one command.
type Outcome string

const (
	// OutcomeDelivered — the DCMD was published to the PLC (or was a
	// no-op duplicate of an already-delivered command). The broker delivery
	// is ACKed.
	OutcomeDelivered Outcome = "delivered"
	// OutcomeRejected — the command was refused (bad verb, missing params,
	// ambiguous mapping, malformed envelope). No DCMD emitted. The broker
	// delivery is nacked → DLX for human triage.
	OutcomeRejected Outcome = "rejected"
)

// Result is what Execute returns. It carries enough for the consumer to (a)
// decide ack vs nack-to-DLX and (b) publish a correlatable ack message.
type Result struct {
	Outcome Outcome
	// Reason is a stable, human-readable explanation — populated on reject,
	// and on delivered-duplicate. Safe to surface in the ack + logs.
	Reason string
	// Duplicate is true when the idempotencyKey was already seen, so the
	// DCMD was intentionally NOT re-issued this time.
	Duplicate bool
	// Command is the parsed envelope (zero-value Command if the body failed
	// to parse). Used to build the ack + choose the ack routing key.
	Command Command
	// DCMDTopic is the MQTT topic the DCMD was published to (empty on reject).
	DCMDTopic string
}

// Ack is the message published to `edge.commands.<tenant>.ack`. The edge-api
// producer correlates it back to the operator action via IdempotencyKey.
type Ack struct {
	IdempotencyKey string `json:"idempotencyKey"`
	Tenant         string `json:"tenant"`
	IDEquipment    int    `json:"idEquipment"`
	Verb           string `json:"verb"`
	Status         string `json:"status"` // "delivered" | "rejected"
	Reason         string `json:"reason,omitempty"`
	DCMDTopic      string `json:"dcmdTopic,omitempty"`
	Duplicate      bool   `json:"duplicate,omitempty"`
	TimestampMs    int64  `json:"timestampMs"`
}

// toAck projects a Result into the wire ack shape.
func (r Result) toAck() Ack {
	return Ack{
		IdempotencyKey: r.Command.IdempotencyKey,
		Tenant:         r.Command.Tenant,
		IDEquipment:    r.Command.IDEquipment,
		Verb:           r.Command.Verb,
		Status:         string(r.Outcome),
		Reason:         r.Reason,
		DCMDTopic:      r.DCMDTopic,
		Duplicate:      r.Duplicate,
		TimestampMs:    time.Now().UnixMilli(),
	}
}
