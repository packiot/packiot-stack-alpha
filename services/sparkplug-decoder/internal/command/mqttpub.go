package command

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
)

// MQTTDevicePublisher is the production DevicePublisher: it owns a paho MQTT
// client and publishes encoded SparkPlug DCMDs to mosquitto. It is the mirror
// image of the ingest subscriber (internal/mqtt) — same broker, opposite
// direction.
//
// DCMDs are published at QoS 1: a machine WRITE warrants the broker's PUBACK
// (at-least-once) rather than the fire-and-forget QoS 0 the ingest DATA stream
// uses. At-least-once is safe here precisely because the executor is idempotent
// on idempotencyKey — a duplicate delivery to the device is deduped upstream,
// and the sim/PLC applying the same absolute value twice is a no-op.
type MQTTDevicePublisher struct {
	client      paho.Client
	qos         byte
	publishWait time.Duration
	logger      *slog.Logger
}

// NewMQTTDevicePublisher connects to the broker and returns a ready publisher.
// Caller must Close when done.
func NewMQTTDevicePublisher(brokerURL, clientID, username, password string, logger *slog.Logger) (*MQTTDevicePublisher, error) {
	if brokerURL == "" {
		return nil, fmt.Errorf("command: MQTT broker URL required")
	}
	if clientID == "" {
		clientID = "edge-transformer-cmd"
	}
	opts := paho.NewClientOptions().
		AddBroker(brokerURL).
		SetClientID(clientID).
		SetUsername(username).
		SetPassword(password).
		SetCleanSession(true).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetKeepAlive(30 * time.Second).
		SetConnectTimeout(10 * time.Second)
	c := paho.NewClient(opts)
	tok := c.Connect()
	if !tok.WaitTimeout(10 * time.Second) {
		return nil, fmt.Errorf("command: MQTT connect timeout to %s", brokerURL)
	}
	if err := tok.Error(); err != nil {
		return nil, fmt.Errorf("command: MQTT connect: %w", err)
	}
	logger.Info("command: DCMD MQTT publisher connected",
		slog.String("broker", brokerURL), slog.String("client_id", clientID))
	return &MQTTDevicePublisher{client: c, qos: 1, publishWait: 5 * time.Second, logger: logger}, nil
}

// PublishDCMD publishes the encoded DCMD to the given topic, waiting for the
// QoS-1 PUBACK (bounded by publishWait or the context deadline, whichever is
// sooner). A timeout or error is returned so the caller retries — the write is
// never assumed delivered on a slow broker.
func (m *MQTTDevicePublisher) PublishDCMD(ctx context.Context, topic string, body []byte) error {
	tok := m.client.Publish(topic, m.qos, false, body)
	wait := m.publishWait
	if dl, ok := ctx.Deadline(); ok {
		if d := time.Until(dl); d < wait {
			wait = d
		}
	}
	if !tok.WaitTimeout(wait) {
		return fmt.Errorf("command: DCMD publish timeout to %s", topic)
	}
	if err := tok.Error(); err != nil {
		return fmt.Errorf("command: DCMD publish to %s: %w", topic, err)
	}
	return nil
}

// Close disconnects the MQTT client.
func (m *MQTTDevicePublisher) Close() {
	if m.client != nil {
		m.client.Disconnect(250)
	}
}
