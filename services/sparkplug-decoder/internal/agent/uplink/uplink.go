// Package uplink is the agent's cloud-facing SparkPlug B publisher +
// store-and-forward drain (ADR-0042 §2.5). It reuses internal/outbox verbatim
// (encode-then-buffer: the buffered NDATA carry their assigned seq + aliases,
// so a drained backlog is a valid SparkPlug stream, not re-numberable JSON).
//
// Two genuinely-new-to-the-tree concerns live here:
//
//  1. NDEATH-via-MQTT-Last-Will (ADR-0042 §2.2). No prior producer registers a
//     Will; the agent MUST, so an ungraceful loss is announced to the cloud as
//     a birth→death transition (the observability half of ADR-0011's
//     asymmetric-responsibility rule). SetBinaryWill(NDEATH) at connect.
//
//  2. REBIRTH-before-drain (ADR-0042 §2.5). On (re)connect the agent republishes
//     NBIRTH — re-establishing the alias table the cloud may have dropped after
//     an NDEATH/restart — BEFORE draining buffered NDATA whose alias references
//     would otherwise be unresolvable.
package uplink

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/outbox"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// Config controls the uplink connection + topic identity.
type Config struct {
	BrokerURL      string
	ClientID       string
	GroupID        string // SparkPlug tenant
	EdgeNodeID     string
	KeepAlive      time.Duration
	ConnectTimeout time.Duration
	PublishTimeout time.Duration
	DrainBatch     int
	DrainInterval  time.Duration

	// TLS is the mTLS material for the Mode-B WAN crossing (ADR-0042 §6): a
	// per-tenant client cert whose CN=<tenant> the cloud broker's ACL keys
	// isolation on. Nil on the Mode-A staging loopback (tcp:// → no TLS). When
	// set, it is applied to the paho client for an ssl:// / tls:// broker.
	TLS *tls.Config
}

func (c *Config) withDefaults() {
	if c.KeepAlive == 0 {
		c.KeepAlive = 30 * time.Second
	}
	if c.ConnectTimeout == 0 {
		c.ConnectTimeout = 10 * time.Second
	}
	if c.PublishTimeout == 0 {
		c.PublishTimeout = 5 * time.Second
	}
	if c.DrainBatch == 0 {
		c.DrainBatch = 64
	}
	if c.DrainInterval == 0 {
		c.DrainInterval = time.Second
	}
}

// publishFn abstracts the transport so rebirth-then-drain is unit-testable
// without a live broker.
type publishFn func(topic string, qos byte, retained bool, body []byte) error

// ErrNotConnected is returned by the real publish path when the client is
// down — the drain loop treats it as "try again next tick", never a data loss
// (the outbox retains the row).
var ErrNotConnected = errors.New("uplink: not connected")

// Uplink owns the paho publisher, the outbox drain, and the session's
// birth/death minting.
type Uplink struct {
	cfg      Config
	pub      *session.Publisher
	store    *outbox.Store
	snapshot func() []rawtag.RawTag // typically tagstore.Snapshot
	logger   *slog.Logger

	birthTopic, deathTopic, dataTopic, ncmdTopic string

	mu        sync.RWMutex
	client    paho.Client
	connected bool
	lastErr   string

	pendingRebirth atomic.Bool // set on (re)connect OR on a Rebirth NCMD; consumed by drainLoop
	onRebirthNCMD  func()      // nil-safe Prometheus hook — fired per accepted Rebirth NCMD
	published      atomic.Uint64
	births         atomic.Uint64
	rebirthsNCMD   atomic.Uint64 // rebirths triggered by an inbound Rebirth NCMD (task #31)
	startedAt      time.Time
}

// New constructs an Uplink. snapshot supplies the current full tag set for
// NBIRTH (rebirth) construction.
func New(cfg Config, pub *session.Publisher, store *outbox.Store, snapshot func() []rawtag.RawTag, logger *slog.Logger) *Uplink {
	cfg.withDefaults()
	base := "spBv1.0/" + cfg.GroupID
	return &Uplink{
		cfg:        cfg,
		pub:        pub,
		store:      store,
		snapshot:   snapshot,
		logger:     logger,
		birthTopic: base + "/NBIRTH/" + cfg.EdgeNodeID,
		deathTopic: base + "/NDEATH/" + cfg.EdgeNodeID,
		dataTopic:  base + "/NDATA/" + cfg.EdgeNodeID,
		ncmdTopic:  base + "/NCMD/" + cfg.EdgeNodeID,
		startedAt:  time.Now(),
	}
}

// SetRebirthMetric wires the Prometheus counter bumped each time an inbound
// Rebirth NCMD is accepted (sparkplug_agent_rebirths_total). Nil-safe; call
// before Run.
func (u *Uplink) SetRebirthMetric(fn func()) { u.onRebirthNCMD = fn }

// DataTopic is the NDATA topic the agent buffers encoded payloads under.
func (u *Uplink) DataTopic() string { return u.dataTopic }

// EnqueueData buffers an already-encoded NDATA payload to the outbox
// (encode-then-buffer). The drain loop publishes it when connected.
func (u *Uplink) EnqueueData(ctx context.Context, body []byte) error {
	_, err := u.store.Enqueue(ctx, outbox.Message{
		Tenant:  u.cfg.GroupID,
		Topic:   u.dataTopic,
		Payload: body,
	})
	return err
}

// Run connects with the NDEATH Last-Will registered, then blocks until ctx is
// cancelled, running a periodic drain. On (re)connect the OnConnect handler
// rebirths-then-drains.
func (u *Uplink) Run(ctx context.Context) error {
	if u.cfg.BrokerURL == "" {
		return errors.New("uplink: BrokerURL is required")
	}
	if u.cfg.ClientID == "" {
		return errors.New("uplink: ClientID is required")
	}

	// bdSeq for THIS process's connection cycle. Registered into the LWT and
	// stamped into every NBIRTH this process publishes, so death correlates to
	// birth. (Per-reconnect bdSeq advance needs will re-registration — ADR-0042
	// open-Q1, deferred; see report.)
	bdSeq := u.pub.NewConnection()
	death, err := u.pub.BuildNDEATH()
	if err != nil {
		return fmt.Errorf("uplink: build NDEATH will: %w", err)
	}
	willBody, err := sparkplug.Encode(death)
	if err != nil {
		return fmt.Errorf("uplink: encode NDEATH will: %w", err)
	}
	u.logger.Info("uplink: registering NDEATH Last-Will", "topic", u.deathTopic, "bdSeq", bdSeq)

	opts := paho.NewClientOptions().
		AddBroker(u.cfg.BrokerURL).
		SetClientID(u.cfg.ClientID).
		SetCleanSession(true).
		SetKeepAlive(u.cfg.KeepAlive).
		SetConnectTimeout(u.cfg.ConnectTimeout).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetMaxReconnectInterval(30*time.Second).
		SetBinaryWill(u.deathTopic, willBody, 1, false).
		SetOnConnectHandler(u.onConnect).
		SetConnectionLostHandler(u.onConnectionLost)

	// Mode-B mTLS (ADR-0042 §6): apply the per-tenant client cert on an
	// ssl:// / tls:// broker. Paho selects TLS from the broker scheme; the
	// cert asserts CN=<tenant> so the broker ACL scopes spBv1.0/<tenant>/# —
	// the client never names its own tenant on the wire. Nil on the Mode-A
	// loopback (tcp://), so staging is unaffected.
	if u.cfg.TLS != nil {
		opts.SetTLSConfig(u.cfg.TLS)
		u.logger.Info("uplink: mTLS enabled for WAN crossing", "broker", u.cfg.BrokerURL)
	}

	client := paho.NewClient(opts)
	u.mu.Lock()
	u.client = client
	u.mu.Unlock()

	tok := client.Connect()
	if !tok.WaitTimeout(u.cfg.ConnectTimeout) {
		return fmt.Errorf("uplink: connect timeout to %s", u.cfg.BrokerURL)
	}
	if err := tok.Error(); err != nil {
		return fmt.Errorf("uplink: connect: %w", err)
	}

	u.drainLoop(ctx)

	client.Disconnect(250)
	return ctx.Err()
}

// drainLoop is the SOLE outbox drainer (the outbox is single-drainer by
// design — a second concurrent drainer could Peek the same rows and double-
// publish). On each tick, if connected: when a (re)connect is pending it
// rebirths-THEN-drains (the load-bearing ADR-0042 §2.5 ordering); otherwise it
// just drains newly-buffered NDATA. onConnect merely flips the pending flag —
// it never drains off the paho callback goroutine.
func (u *Uplink) drainLoop(ctx context.Context) {
	t := time.NewTicker(u.cfg.DrainInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if !u.isConnected() {
				continue
			}
			var err error
			if u.pendingRebirth.CompareAndSwap(true, false) {
				err = u.rebirthThenDrain(ctx, u.publishViaClient)
			} else {
				err = u.drain(ctx, u.publishViaClient)
			}
			if err != nil && !errors.Is(err, ErrNotConnected) {
				u.logger.Warn("uplink: drain error", "err", err)
			}
		}
	}
}

// onConnect fires on every (re)connect. It records state, arms a pending
// rebirth, and (re)subscribes to the inbound NCMD topic so a host-side Rebirth
// request reaches us. Clean-session drops subscriptions across reconnect, so
// the subscribe MUST happen here, not once at startup. The drainLoop (single
// drainer) performs the rebirth-then-drain on its next tick; keeping the paho
// callback non-blocking guarantees exactly one drainer.
func (u *Uplink) onConnect(c paho.Client) {
	u.mu.Lock()
	u.connected = true
	u.lastErr = ""
	u.mu.Unlock()
	u.pendingRebirth.Store(true)
	u.logger.Info("uplink: connected — rebirth armed", "broker", u.cfg.BrokerURL)

	// Subscribe to the Rebirth NCMD channel (task #31). Don't Wait() the token
	// on the paho callback goroutine indefinitely — bound it and log failure.
	go func() {
		tok := c.Subscribe(u.ncmdTopic, 1, u.onNCMD)
		if !tok.WaitTimeout(5 * time.Second) {
			u.logger.Error("uplink: NCMD subscribe timeout", "topic", u.ncmdTopic)
			return
		}
		if err := tok.Error(); err != nil {
			u.logger.Error("uplink: NCMD subscribe failed", "topic", u.ncmdTopic, "err", err)
			return
		}
		u.logger.Info("uplink: subscribed to Rebirth NCMD", "topic", u.ncmdTopic)
	}()
}

// onNCMD handles inbound NCMDs on spBv1.0/<group>/NCMD/<edge_node>. A
// "Node Control/Rebirth"=true request re-arms pendingRebirth, so the drainLoop
// republishes the full NBIRTH (seq reset to 0) on its next tick — reusing the
// single-drainer rebirth-then-drain path rather than publishing off the paho
// callback goroutine. This is the edge-node half of the task #31 self-heal:
// after the cloud edge-transformer restarts and loses its alias/counter
// baseline, it asks us to rebirth and we re-seed it. Non-rebirth NCMDs (none
// defined yet) are logged and ignored.
func (u *Uplink) onNCMD(_ paho.Client, msg paho.Message) {
	p, err := sparkplug.Decode(msg.Payload())
	if err != nil {
		u.logger.Warn("uplink: NCMD decode failed", "topic", msg.Topic(), "err", err)
		return
	}
	if !sparkplug.IsRebirthRequest(p) {
		u.logger.Debug("uplink: NCMD ignored (not a rebirth request)", "topic", msg.Topic())
		return
	}
	u.rebirthsNCMD.Add(1)
	if u.onRebirthNCMD != nil {
		u.onRebirthNCMD()
	}
	u.pendingRebirth.Store(true)
	u.logger.Info("rebirth requested via NCMD", "topic", msg.Topic(), "rebirths_ncmd_total", u.rebirthsNCMD.Load())
}

func (u *Uplink) onConnectionLost(_ paho.Client, err error) {
	u.mu.Lock()
	u.connected = false
	u.lastErr = err.Error()
	u.mu.Unlock()
	u.logger.Warn("uplink: connection lost — reconnecting", "err", err)
}

// rebirthThenDrain republishes NBIRTH from the current snapshot, THEN drains
// the outbox. Extracted with an injected publishFn so the ordering invariant
// is unit-tested without a broker (ADR-0042 §2.5).
func (u *Uplink) rebirthThenDrain(ctx context.Context, pub publishFn) error {
	birth, err := u.pub.BuildNBIRTH(u.snapshot())
	if err != nil {
		return fmt.Errorf("build NBIRTH: %w", err)
	}
	body, err := sparkplug.Encode(birth)
	if err != nil {
		return fmt.Errorf("encode NBIRTH: %w", err)
	}
	// Rebirth FIRST — retained so a late-joining/restarted cloud subscriber
	// still finds the alias table.
	if err := pub(u.birthTopic, 1, true, body); err != nil {
		return fmt.Errorf("publish NBIRTH: %w", err)
	}
	u.births.Add(1)
	return u.drain(ctx, pub)
}

// Rebirth republishes NBIRTH immediately — used when a brand-new tag appears
// mid-stream (session.NeedsRebirth): its alias must be frozen at the cloud
// BEFORE any NDATA references it. Returns ErrNotConnected when down; the next
// onConnect rebirths anyway, and the new tag's value is preserved in the
// snapshot, so nothing is lost.
func (u *Uplink) Rebirth(ctx context.Context) error {
	birth, err := u.pub.BuildNBIRTH(u.snapshot())
	if err != nil {
		return fmt.Errorf("build NBIRTH: %w", err)
	}
	body, err := sparkplug.Encode(birth)
	if err != nil {
		return fmt.Errorf("encode NBIRTH: %w", err)
	}
	if err := u.publishViaClient(u.birthTopic, 1, true, body); err != nil {
		return err
	}
	u.births.Add(1)
	return nil
}

// drain publishes buffered NDATA in FIFO order: Peek → publish(QoS1) → Delete.
// A publish failure marks the row for backoff-retry and stops the batch (the
// outbox retains it — no data loss).
func (u *Uplink) drain(ctx context.Context, pub publishFn) error {
	for {
		msgs, err := u.store.Peek(ctx, u.cfg.DrainBatch)
		if errors.Is(err, outbox.ErrOutboxEmpty) {
			return nil
		}
		if err != nil {
			return err
		}
		for _, m := range msgs {
			if err := pub(m.Topic, 1, false, m.Payload); err != nil {
				_ = u.store.MarkAttempt(ctx, m.ID, 2*time.Second)
				return err
			}
			if err := u.store.Delete(ctx, m.ID); err != nil {
				return err
			}
			u.published.Add(1)
		}
	}
}

// publishViaClient is the real transport publishFn (QoS1 + PUBACK wait).
func (u *Uplink) publishViaClient(topic string, qos byte, retained bool, body []byte) error {
	u.mu.RLock()
	c := u.client
	connected := u.connected
	u.mu.RUnlock()
	if c == nil || !connected {
		return ErrNotConnected
	}
	tok := c.Publish(topic, qos, retained, body)
	if !tok.WaitTimeout(u.cfg.PublishTimeout) {
		return fmt.Errorf("uplink: publish timeout on %s", topic)
	}
	return tok.Error()
}

func (u *Uplink) isConnected() bool {
	u.mu.RLock()
	defer u.mu.RUnlock()
	return u.connected
}

// ── health.ComponentSnapshotter ──────────────────────────────────────────

// Component is the /healthz key.
func (u *Uplink) Component() string { return "uplink_publisher" }

// Snapshot is the /healthz JSON body.
type Snapshot struct {
	Connected      bool   `json:"connected"`
	BrokerURL      string `json:"broker_url"`
	PublishedTotal uint64 `json:"published_total"`
	BirthsTotal    uint64 `json:"births_total"`
	RebirthsNCMD   uint64 `json:"rebirths_ncmd_total"`
	OutboxDepth    int    `json:"outbox_depth"`
	StartedAt      string `json:"started_at"`
	LastErr        string `json:"last_error,omitempty"`
}

// SnapshotDetail satisfies health.ComponentSnapshotter.
func (u *Uplink) SnapshotDetail() any {
	u.mu.RLock()
	connected, lastErr := u.connected, u.lastErr
	u.mu.RUnlock()
	depth, _ := u.store.Depth(context.Background())
	return Snapshot{
		Connected:      connected,
		BrokerURL:      u.cfg.BrokerURL,
		PublishedTotal: u.published.Load(),
		BirthsTotal:    u.births.Load(),
		RebirthsNCMD:   u.rebirthsNCMD.Load(),
		OutboxDepth:    depth,
		StartedAt:      u.startedAt.Format(time.RFC3339),
		LastErr:        lastErr,
	}
}

// Degraded returns a non-empty reason when unhealthy (ADR-0011 rule 4).
func (u *Uplink) Degraded() string {
	u.mu.RLock()
	defer u.mu.RUnlock()
	if !u.connected {
		if u.lastErr != "" {
			return "not connected: " + u.lastErr
		}
		return "not connected to uplink broker"
	}
	return ""
}
