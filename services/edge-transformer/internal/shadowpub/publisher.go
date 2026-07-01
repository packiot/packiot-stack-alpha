// Package shadowpub publishes ResolvedPayload → the edge.plc-normalized
// exchange, mirroring the envelope shape that Phase 2.5b's Node-RED publisher
// tab produces. This enables ADR-0008-style comparator validation: both
// pipelines write to the SAME exchange with the SAME shape, and the
// comparator diffs them on (metric_name, value, timestamp) tuples.
//
// The envelope is defined by docs/clients/_normalized-payload-schema.yaml v1.0.
// The only fields that differ from the Node-RED path:
//
//   envelope.source.type      "go"        (Node-RED path: "nodered")
//   envelope.source.package   "sparkplug" (Node-RED path: absent)
//   envelope.source.tab       absent      (Node-RED path: "Publish to edge...")
//   payload.equipment_id      0 (TBD)     (Node-RED path: real ID from client.yaml map)
//
// The equipment_id resolution (name → int) belongs in the ADR-0009 Phase 3
// normalizer that Phase 2.5b hard-coded as an inline const. For shadow-mode
// the comparator can ignore that field or match on metric name instead.
//
// SPIKE STATUS (ADR-0010 Phase 2 follow-up):
// This is a working publisher but not yet fanned out per-tenant with
// per-tenant credentials + retry topology. Uses the same AMQP creds as the
// consumer (both talk to the same broker). Retries + DLX + dead-letter
// routing are deferred until the shadow path proves useful for the
// comparator use case.
package shadowpub

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync/atomic"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// SchemaVersion is the docs/clients/_normalized-payload-schema.yaml version
// this publisher emits. Bumped only on breaking envelope changes.
const SchemaVersion = "1.0"

// Envelope is the outer JSON structure published to edge.plc-normalized.
// Matches the shape Phase 2.5b's Node-RED publisher produces so the
// comparator can diff both paths at the RMQ boundary.
type Envelope struct {
	SchemaVersion string      `json:"schema_version"`
	Envelope      EnvMetadata `json:"envelope"`
	Type          string      `json:"type"`
	Payload       Payload     `json:"payload"`
}

// EnvMetadata is the always-present envelope metadata: source identity,
// message + trace IDs (identical for shadow — no cross-service tracing yet),
// and timing fields.
type EnvMetadata struct {
	Tenant          string       `json:"tenant"`
	Source          SourceInfo   `json:"source"`
	MessageID       string       `json:"message_id"`
	TraceID         string       `json:"trace_id"`
	OrderingKey     string       `json:"ordering_key"`
	IngestedAt      string       `json:"ingested_at"`
	SourceTimestamp string       `json:"source_timestamp"`
	PublisherKey    string       `json:"publisher_key,omitempty"`
}

// SourceInfo identifies which pipeline produced this envelope. Comparator
// uses source.type to distinguish Node-RED path vs Go path at diff time.
type SourceInfo struct {
	Type     string `json:"type"`
	Instance string `json:"instance"`
	Package  string `json:"package,omitempty"`
}

// Payload is the per-metric data body. equipment_id is 0 in shadow-mode until
// the Phase 3 normalizer lands a name → equipment_id lookup.
type Payload struct {
	EquipmentID       int    `json:"equipment_id"`
	Parameter         string `json:"parameter"`
	Value             any    `json:"value"`
	Datatype          string `json:"datatype"`
	Quality           string `json:"quality"`
	SourceMetricName  string `json:"source_metric_name,omitempty"` // full Sparkplug topic
}

// Publisher owns an AMQP Channel (single-writer) for shadow publishes.
// Not goroutine-safe — callers should hold the mutex or serialize calls.
// (In our wiring only one goroutine — the MQTT Handler — calls Publish.)
type Publisher struct {
	conn     *amqp.Connection
	ch       *amqp.Channel
	exchange string
	instance string
	logger   *slog.Logger

	// atomic counters — read by /health JSON body.
	published atomic.Uint64
	failed    atomic.Uint64
}

// New opens an AMQP connection + channel and returns a Publisher ready for
// Publish calls. Caller must Close when done.
//
// amqpURL is the same shape amqp.Consumer uses (built from Secrets).
// exchange is typically "edge.plc-normalized" (matches Phase 2.5b topology).
func New(amqpURL, exchange string, logger *slog.Logger) (*Publisher, error) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		return nil, fmt.Errorf("shadowpub: dial: %w", err)
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("shadowpub: channel: %w", err)
	}
	instance, _ := os.Hostname()
	if instance == "" {
		instance = "edge-transformer"
	}
	return &Publisher{
		conn:     conn,
		ch:       ch,
		exchange: exchange,
		instance: instance,
		logger:   logger,
	}, nil
}

// Close releases the AMQP channel + connection.
func (p *Publisher) Close() error {
	if p.ch != nil {
		_ = p.ch.Close()
	}
	if p.conn != nil {
		return p.conn.Close()
	}
	return nil
}

// PublishedCount + FailedCount are read by /health snapshots.
func (p *Publisher) PublishedCount() uint64 { return p.published.Load() }
func (p *Publisher) FailedCount() uint64    { return p.failed.Load() }

// Publish fans out a ResolvedPayload into per-metric envelopes and publishes
// each to edge.plc-normalized.<tenant>. Errors on the first publish failure —
// remaining metrics in the batch are NOT retried by this call (upstream
// caller decides retry semantics).
//
// Tenant is derived from the publisher key's GroupID (lowercased). This
// matches the Phase 2.5b publisher's env-var-driven CLIENT_TENANT_ID default
// of "cpack" when GroupID is "CPACK".
func (p *Publisher) Publish(ctx context.Context, resolved *sparkplug.ResolvedPayload) error {
	tenant := strings.ToLower(resolved.PublisherKey.GroupID)
	routingKey := fmt.Sprintf("%s.%s", p.exchange, tenant)

	now := time.Now().UTC()
	sourceTs := time.Unix(0, int64(resolved.Timestamp)*int64(time.Millisecond)).UTC().Format(rfc3339Millis)
	ingestedAt := now.Format(rfc3339Millis)

	for _, m := range resolved.Metrics {
		env := BuildEnvelope(EnvelopeInput{
			Tenant:          tenant,
			PublisherKey:    resolved.PublisherKey.String(),
			Instance:        p.instance,
			Metric:          m,
			IngestedAt:      ingestedAt,
			SourceTimestamp: sourceTs,
		})

		body, err := json.Marshal(env)
		if err != nil {
			p.failed.Add(1)
			return fmt.Errorf("shadowpub: marshal envelope: %w", err)
		}

		err = p.ch.PublishWithContext(ctx, p.exchange, routingKey, false, false,
			amqp.Publishing{
				ContentType:  "application/json",
				DeliveryMode: amqp.Persistent,
				MessageId:    env.Envelope.MessageID,
				Body:         body,
			})
		if err != nil {
			p.failed.Add(1)
			return fmt.Errorf("shadowpub: publish %s: %w", routingKey, err)
		}
		p.published.Add(1)
	}
	return nil
}

// EnvelopeInput is the pure-function seam used by BuildEnvelope. Isolated
// so unit tests don't need an AMQP connection.
type EnvelopeInput struct {
	Tenant          string
	PublisherKey    string
	Instance        string
	Metric          sparkplug.ResolvedMetric
	IngestedAt      string
	SourceTimestamp string
}

// BuildEnvelope constructs the envelope + payload for a single resolved
// metric. Extracted so tests can assert JSON keys without AMQP wiring.
func BuildEnvelope(in EnvelopeInput) Envelope {
	msgID := newMessageID()
	return Envelope{
		SchemaVersion: SchemaVersion,
		Envelope: EnvMetadata{
			Tenant: in.Tenant,
			Source: SourceInfo{
				Type:     "go",
				Instance: in.Instance,
				Package:  "sparkplug",
			},
			MessageID:       msgID,
			TraceID:         msgID,
			OrderingKey:     fmt.Sprintf("publisher_%s", strings.ReplaceAll(in.PublisherKey, "/", "_")),
			IngestedAt:      in.IngestedAt,
			SourceTimestamp: in.SourceTimestamp,
			PublisherKey:    in.PublisherKey,
		},
		Type: "sparkplug.metric",
		Payload: Payload{
			EquipmentID:      0, // TODO Phase 3: name → equipment_id lookup
			Parameter:        parameterFromMetricName(in.Metric.Name),
			Value:            in.Metric.Value,
			Datatype:         datatypeToString(in.Metric.Datatype),
			Quality:          "good",
			SourceMetricName: in.Metric.Name,
		},
	}
}

// parameterFromMetricName extracts the last segment of the Sparkplug topic
// name, matching what Phase 2.5b's Node-RED adapter emits as `parameter`.
// e.g. "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit" → "Unit"
func parameterFromMetricName(name string) string {
	if name == "" {
		return "unknown"
	}
	if i := strings.LastIndex(name, "/"); i >= 0 && i < len(name)-1 {
		return name[i+1:]
	}
	return name
}

// datatypeToString maps the Sparkplug B datatype enum int back to the
// lowercase-with-underscore form that Phase 2.5b's Node-RED path emits.
// The comparator diffs on this string so both paths must agree.
func datatypeToString(dt uint32) string {
	switch sparkplug.DataType(dt) {
	case sparkplug.DataType_Int8, sparkplug.DataType_Int16, sparkplug.DataType_Int32:
		return "int32"
	case sparkplug.DataType_Int64:
		return "int64"
	case sparkplug.DataType_UInt8, sparkplug.DataType_UInt16, sparkplug.DataType_UInt32:
		return "uint32"
	case sparkplug.DataType_UInt64:
		return "uint64"
	case sparkplug.DataType_Float:
		return "float"
	case sparkplug.DataType_Double:
		return "double"
	case sparkplug.DataType_Boolean:
		return "bool"
	case sparkplug.DataType_String:
		return "string"
	default:
		return "auto"
	}
}

// newMessageID returns a compact URL-safe random ID. Matches the general
// shape the Node-RED publisher emits (timestamp-suffix + random) without
// requiring an exact byte-match.
func newMessageID() string {
	var b [9]byte
	_, _ = rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}

// rfc3339Millis is ISO-8601 with millisecond precision — matches the
// Node-RED path's `.toISOString().replace('Z', '000Z')` convention.
const rfc3339Millis = "2006-01-02T15:04:05.000Z07:00"
