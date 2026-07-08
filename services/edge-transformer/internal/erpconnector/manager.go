package erpconnector

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"golang.org/x/sync/errgroup"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
)

// IntegrationType is the clientconfig.Integration.Type value this package
// answers to. Entries of any other type are ignored (a different capability
// owns them).
const IntegrationType = "database"

// DefaultReadCadence is used when Config.ReadCadence is zero. Matches the
// spec's example `cadence: 15m` for production-order reads — low-QPS by
// design (an ERP is polled, not streamed).
const DefaultReadCadence = 15 * time.Minute

// Config assembles a Manager. Integrations comes straight from
// clientconfig.Config.Capabilities.Integrations (already parsed + validated
// upstream); everything else is supplied by the wiring layer.
type Config struct {
	// Integrations is the tenant's declared capability list. Only entries
	// with Type=="database" are consumed; the rest are ignored.
	Integrations []clientconfig.Integration
	// Resolver turns each dsn_ref into a DSN at open time. Required when any
	// database integration is declared.
	Resolver SecretResolver
	// Templates loads the reads/writes SQL files. Required when any database
	// integration is declared.
	Templates *TemplateStore
	// Drivers maps a descriptor `driver:` value to a DBDriver. Defaults to
	// DefaultDrivers() (SQLite only) when nil — the wiring layer adds oracle.
	Drivers map[string]DBDriver
	// Metrics is the observability sink (zero value is a valid no-op).
	Metrics Metrics
	// ReadSink receives every read cycle's ReadResult — the seam into the
	// PO-control path. nil is allowed (rows are counted + dropped) so the
	// connector can run before the sink is wired.
	ReadSink func(context.Context, ReadResult) error
	// ReadCadence is the read-poll interval. Zero → DefaultReadCadence.
	ReadCadence time.Duration
	// DedupCap bounds the in-memory dedup set per connector. Zero → default.
	DedupCap int
	// Logger; nil → slog.Default().
	Logger *slog.Logger
}

// Manager owns the lifecycle of every database integration a descriptor
// declares. New validates + builds the specs (enforcing secrets-by-ref and a
// known driver); Start opens the connections and runs the read cadence. With
// no database integration declared it holds zero specs and Start is a no-op —
// the connector is inert by construction.
type Manager struct {
	specs     []databaseSpec
	resolver  SecretResolver
	templates *TemplateStore
	metrics   Metrics
	readSink  func(context.Context, ReadResult) error
	cadence   time.Duration
	dedupCap  int
	logger    *slog.Logger

	opened []*Connector
}

// databaseSpec is a validated-but-not-yet-opened integration: the parsed
// descriptor entry plus the resolved DBDriver. DSN resolution + Open are
// deferred to Start so New never reaches the network.
type databaseSpec struct {
	integration clientconfig.Integration
	driver      DBDriver
}

// New validates the declared integrations and builds the Manager. It is the
// enforcement point for the two hard rules:
//
//   - secrets by reference: every database integration's dsn_ref MUST be a
//     secret:// reference. A literal DSN fails here, at init, before any
//     connection is attempted (the Incoplast cleartext-creds finding).
//   - known driver: the descriptor's `driver:` must be registered. An
//     unregistered driver (e.g. "oracle" in a build that hasn't vendored the
//     Oracle client) fails loud rather than silently no-op'ing.
//
// With zero database integrations, New succeeds and returns a Manager whose
// Start is a no-op.
func New(cfg Config) (*Manager, error) {
	drivers := cfg.Drivers
	if drivers == nil {
		drivers = DefaultDrivers()
	}
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	cadence := cfg.ReadCadence
	if cadence <= 0 {
		cadence = DefaultReadCadence
	}

	var specs []databaseSpec
	for i, in := range cfg.Integrations {
		if in.Type != IntegrationType {
			continue
		}
		// Rule 1 — secrets by reference, enforced before anything else.
		if err := RequireSecretRef(
			fmt.Sprintf("integrations[%d].dsn_ref", i), in.DSNRef); err != nil {
			return nil, err
		}
		// Rule 2 — known driver.
		drv, ok := drivers[in.Driver]
		if !ok {
			return nil, fmt.Errorf(
				"erpconnector: integrations[%d]: no driver registered for %q "+
					"(oracle is the production driver — register it in the wiring layer)",
				i, in.Driver)
		}
		specs = append(specs, databaseSpec{integration: in, driver: drv})
	}

	// Templates + resolver are only required if there is real work to do.
	if len(specs) > 0 {
		if cfg.Resolver == nil {
			return nil, errors.New("erpconnector: a SecretResolver is required when database integrations are declared")
		}
		if cfg.Templates == nil {
			return nil, errors.New("erpconnector: a TemplateStore is required when database integrations are declared")
		}
	}

	return &Manager{
		specs:     specs,
		resolver:  cfg.Resolver,
		templates: cfg.Templates,
		metrics:   cfg.Metrics,
		readSink:  cfg.ReadSink,
		cadence:   cadence,
		dedupCap:  cfg.DedupCap,
		logger:    logger,
	}, nil
}

// Enabled reports whether any database integration was declared. When false,
// Start is a no-op — useful for a wiring-layer log line.
func (m *Manager) Enabled() bool { return len(m.specs) > 0 }

// Connectors returns the opened connectors (valid only after open/Start).
// It is the write-side seam: the follow-up that taps equipment_events drives
// writes through these.
func (m *Manager) Connectors() []*Connector { return m.opened }

// Start opens every declared connector, then runs the read cadence until ctx
// is cancelled. It is a no-op returning nil when no database integration was
// declared — the inert path. Connections are closed on return.
func (m *Manager) Start(ctx context.Context) error {
	if len(m.specs) == 0 {
		m.logger.Info("erpconnector: no database integrations declared — inert")
		return nil
	}
	if err := m.open(ctx); err != nil {
		return err
	}
	defer m.closeAll()

	m.logger.Info("erpconnector: started",
		slog.Int("connectors", len(m.opened)),
		slog.Duration("read_cadence", m.cadence))

	// Initial cycle immediately, then on the cadence ticker.
	if err := m.runReadCycle(ctx); err != nil && !errors.Is(err, context.Canceled) {
		m.logger.Warn("erpconnector: initial read cycle error", slog.Any("err", err))
	}
	ticker := time.NewTicker(m.cadence)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			if err := m.runReadCycle(ctx); err != nil && !errors.Is(err, context.Canceled) {
				m.logger.Warn("erpconnector: read cycle error", slog.Any("err", err))
			}
		}
	}
}

// open resolves each spec's DSN via the SecretResolver and opens its Conn.
// It re-checks the secret-by-ref rule as a second gate (New already did) so
// the guarantee holds even if a Manager were constructed by a future path
// that skipped New.
func (m *Manager) open(ctx context.Context) error {
	for _, spec := range m.specs {
		ref := spec.integration.DSNRef
		if err := RequireSecretRef("dsn_ref", ref); err != nil {
			return err
		}
		dsn, err := m.resolver.Resolve(ctx, ref)
		if err != nil {
			m.metrics.errored(spec.integration.Driver, "open")
			return fmt.Errorf("erpconnector: resolve %s: %w", ref, err)
		}
		conn, err := spec.driver.Open(ctx, dsn)
		if err != nil {
			m.metrics.errored(spec.integration.Driver, "open")
			return err
		}
		m.opened = append(m.opened, &Connector{
			driverName: spec.integration.Driver,
			dsnRef:     ref,
			conn:       conn,
			templates:  m.templates,
			dedupKey:   spec.integration.DedupKey,
			seen:       NewMemSeenSet(m.dedupCap),
			readRefs:   spec.integration.Reads,
			writeRefs:  spec.integration.Writes,
			metrics:    m.metrics,
			logger:     m.logger,
		})
	}
	return nil
}

// runReadCycle runs every read template on every opened connector once and
// pushes each ReadResult to the sink. Factored out of Start so it is
// deterministically testable without waiting on a ticker.
func (m *Manager) runReadCycle(ctx context.Context) error {
	for _, c := range m.opened {
		for _, ref := range c.readRefs {
			res, err := c.Read(ctx, ref)
			if err != nil {
				return err
			}
			if m.readSink != nil {
				if err := m.readSink(ctx, *res); err != nil {
					return fmt.Errorf("erpconnector: read sink %q: %w", ref, err)
				}
			}
		}
	}
	return nil
}

func (m *Manager) closeAll() {
	for _, c := range m.opened {
		if err := c.Close(); err != nil {
			m.logger.Warn("erpconnector: close error", slog.Any("err", err))
		}
	}
}

// StartInGroup registers Start on an errgroup — the shape the boot wiring
// uses (cmd/edge-transformer/main.go runs its long-lived loops this way).
func (m *Manager) StartInGroup(ctx context.Context, g *errgroup.Group) {
	g.Go(func() error { return m.Start(ctx) })
}
