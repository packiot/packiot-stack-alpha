package command

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// nowMillis is the DCMD timestamp source (Unix millis), matching the
// SparkPlug decoder's expectation.
func nowMillis() uint64 { return uint64(time.Now().UnixMilli()) }

// Translation errors. Every one is a REJECT reason — the fail-safe rule means
// an ambiguous or incomplete command must never produce a partial write.
var (
	// ErrUnknownVerb — the verb has no DCMD mapping. (The allow-list gates
	// this first; this is defense-in-depth for a verb that is allow-listed
	// but has no translator.)
	ErrUnknownVerb = errors.New("command: no DCMD mapping for verb")
	// ErrMissingParam — a required param is absent or the wrong type. A write
	// must carry every value explicitly; we do not default or guess.
	ErrMissingParam = errors.New("command: required param missing or wrong type")
	// ErrBadTopic — packmlTopic is empty or malformed, so we cannot derive the
	// SparkPlug group / build the DCMD topic.
	ErrBadTopic = errors.New("command: packmlTopic empty or malformed")
)

// DCMD is the encoded device command ready to publish over MQTT.
type DCMD struct {
	Topic string // spBv1.0/<group>/DCMD/<edgeNode>
	Body  []byte // protobuf-encoded SparkPlug B Payload
	// Metric is the single metric name the DCMD writes, retained for the ack
	// + logs so operators see exactly what was actuated.
	Metric string
}

//
// ── verb → DCMD translation table ────────────────────────────────────────────
//
// This is the INVERSE of the ingest normalizer. Where the decoder turns a
// SparkPlug metric into a value, here a verb + params become a SparkPlug metric
// the controller applies. Every mapping is deterministic and total over its
// required params; anything outside the table REJECTS.
//
//	verb          required params            DCMD metric written (relative to packmlTopic)      value type
//	───────────   ───────────────────────    ─────────────────────────────────────────────     ──────────
//	param_write   parameter (string),        <packmlTopic>/<parameter>                          Double
//	              value (number)             e.g. .../Status/MachSpeed, .../Status/Parameter30701
//	po_setup      poNumber (string|number)   <packmlTopic>/Status/Parameter30700                String
//
// group (SparkPlug GroupID) is the FIRST segment of packmlTopic (e.g. "CPACK").
// edgeNode is deployment-fixed (config). Topic = spBv1.0/<group>/DCMD/<edgeNode>.

// BuildDCMD translates a command into a SparkPlug DCMD. It returns a REJECT
// error (one of ErrUnknownVerb / ErrMissingParam / ErrBadTopic) for anything
// it cannot map to a definite single write — the caller turns that into an
// ack-rejected + DLX, never a partial emit.
func BuildDCMD(cmd Command, edgeNode string) (DCMD, error) {
	group, err := sparkplugGroup(cmd.PackmlTopic)
	if err != nil {
		return DCMD{}, err
	}

	var metricName string
	var metric *sparkplug.Metric

	switch cmd.Verb {
	case VerbParamWrite:
		leaf, ok := paramString(cmd.Params, "parameter")
		if !ok || leaf == "" {
			return DCMD{}, fmt.Errorf("%w: param_write needs 'parameter'", ErrMissingParam)
		}
		val, ok := paramFloat(cmd.Params, "value")
		if !ok {
			return DCMD{}, fmt.Errorf("%w: param_write needs numeric 'value'", ErrMissingParam)
		}
		metricName = joinTopic(cmd.PackmlTopic, leaf)
		metric = doubleMetric(metricName, val)

	case VerbPOSetup:
		po, ok := paramScalarString(cmd.Params, "poNumber")
		if !ok || po == "" {
			return DCMD{}, fmt.Errorf("%w: po_setup needs 'poNumber'", ErrMissingParam)
		}
		metricName = joinTopic(cmd.PackmlTopic, "Status/Parameter30700")
		metric = stringMetric(metricName, po)

	default:
		return DCMD{}, fmt.Errorf("%w: %q", ErrUnknownVerb, cmd.Verb)
	}

	body, err := sparkplug.Encode(&sparkplug.Payload{
		Timestamp: u64ptr(nowMillis()),
		Metrics:   []*sparkplug.Metric{metric},
	})
	if err != nil {
		return DCMD{}, fmt.Errorf("command: encode DCMD: %w", err)
	}
	return DCMD{
		Topic:  fmt.Sprintf("spBv1.0/%s/DCMD/%s", group, edgeNode),
		Body:   body,
		Metric: metricName,
	}, nil
}

// sparkplugGroup extracts the SparkPlug GroupID (first topic segment).
func sparkplugGroup(packmlTopic string) (string, error) {
	t := strings.Trim(strings.TrimSpace(packmlTopic), "/")
	if t == "" {
		return "", ErrBadTopic
	}
	group := strings.SplitN(t, "/", 2)[0]
	if group == "" {
		return "", ErrBadTopic
	}
	return group, nil
}

// joinTopic joins the packmlTopic base and a metric leaf with exactly one
// slash, tolerating leading/trailing slashes on either part.
func joinTopic(base, leaf string) string {
	return strings.TrimRight(base, "/") + "/" + strings.TrimLeft(leaf, "/")
}

func doubleMetric(name string, v float64) *sparkplug.Metric {
	n := name
	dt := uint32(sparkplug.DataType_Double)
	return &sparkplug.Metric{
		Name:     &n,
		Datatype: &dt,
		Value:    &sparkplug.Metric_DoubleValue{DoubleValue: v},
	}
}

func stringMetric(name, v string) *sparkplug.Metric {
	n := name
	dt := uint32(sparkplug.DataType_String)
	return &sparkplug.Metric{
		Name:     &n,
		Datatype: &dt,
		Value:    &sparkplug.Metric_StringValue{StringValue: v},
	}
}

// paramString reads a string param. Returns false when absent or not a string.
func paramString(p map[string]any, key string) (string, bool) {
	if p == nil {
		return "", false
	}
	s, ok := p[key].(string)
	return s, ok
}

// paramFloat reads a numeric param. JSON numbers unmarshal to float64; we also
// accept the other Go numeric shapes for programmatic callers + tests. A string
// is NOT coerced — a write value must be an unambiguous number.
func paramFloat(p map[string]any, key string) (float64, bool) {
	if p == nil {
		return 0, false
	}
	switch v := p[key].(type) {
	case float64:
		return v, true
	case float32:
		return float64(v), true
	case int:
		return float64(v), true
	case int64:
		return float64(v), true
	case json.Number:
		f, err := v.Float64()
		return f, err == nil
	}
	return 0, false
}

// paramScalarString reads a scalar param (string or number) and renders it as a
// string — used for poNumber, which may arrive as "PO-42" or 42. Integers are
// rendered without a trailing ".0"; bools/maps/nil are rejected.
func paramScalarString(p map[string]any, key string) (string, bool) {
	if p == nil {
		return "", false
	}
	switch v := p[key].(type) {
	case string:
		return v, true
	case float64:
		if v == math.Trunc(v) && !math.IsInf(v, 0) {
			return strconv.FormatInt(int64(v), 10), true
		}
		return strconv.FormatFloat(v, 'f', -1, 64), true
	case int:
		return strconv.Itoa(v), true
	case int64:
		return strconv.FormatInt(v, 10), true
	case json.Number:
		return v.String(), true
	}
	return "", false
}

func u64ptr(v uint64) *uint64 { return &v }
