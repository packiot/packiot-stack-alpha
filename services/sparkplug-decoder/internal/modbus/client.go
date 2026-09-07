package modbus

import (
	"fmt"
	"sync"
	"time"

	"github.com/goburrow/modbus"
)

// Client wraps a goburrow/modbus TCP session to ONE Modbus device (host:port +
// unit/slave id). goburrow/modbus is pure Go (BSD-3) — no CGo, so the static /
// distroless build (CGO_ENABLED=0) is preserved, consistent with the gos7
// choice for S7. The underlying handler is not goroutine-safe, so a mutex
// serialises reads; one Client drives one poll loop.
//
// Modbus TCP framing note: the "unit id" (a.k.a. slave/server id) is the last
// byte of the MBAP header. On a native Ethernet device it is usually 1 or 0;
// on a serial-to-TCP gateway it selects which RTU device behind the gateway
// you're addressing — hence it is configurable per endpoint.
type Client struct {
	address string
	unitID  byte
	timeout time.Duration

	mu      sync.Mutex
	handler *modbus.TCPClientHandler
	client  modbus.Client
}

// NewClient builds a Client but does NOT dial — call Connect (or let Read
// lazily connect). timeout bounds each request; <=0 uses a 5s default.
func NewClient(address string, unitID byte, timeout time.Duration) *Client {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &Client{address: address, unitID: unitID, timeout: timeout}
}

// Connect dials the device. Safe to call repeatedly (reconnect) — it closes any
// prior handler first.
func (c *Client) Connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connectLocked()
}

func (c *Client) connectLocked() error {
	if c.handler != nil {
		_ = c.handler.Close()
		c.handler = nil
		c.client = nil
	}
	h := modbus.NewTCPClientHandler(c.address)
	h.Timeout = c.timeout
	h.IdleTimeout = 4 * c.timeout
	h.SlaveId = c.unitID
	if err := h.Connect(); err != nil {
		return fmt.Errorf("modbus connect %s (unit=%d): %w", c.address, c.unitID, err)
	}
	c.handler = h
	c.client = modbus.NewClient(h)
	return nil
}

// Read reads `quantity` registers/coils of address space `kind` starting at
// `start`. It satisfies ReadFunc. On a transport error it drops the connection
// so the next call (or an explicit Connect) redials — mirrors the s7 client's
// reconnect discipline.
func (c *Client) Read(kind Kind, start, quantity uint16) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.client == nil {
		if err := c.connectLocked(); err != nil {
			return nil, err
		}
	}

	var (
		buf []byte
		err error
	)
	switch kind {
	case KindHolding:
		buf, err = c.client.ReadHoldingRegisters(start, quantity)
	case KindInput:
		buf, err = c.client.ReadInputRegisters(start, quantity)
	case KindCoil:
		buf, err = c.client.ReadCoils(start, quantity)
	case KindDiscrete:
		buf, err = c.client.ReadDiscreteInputs(start, quantity)
	default:
		return nil, fmt.Errorf("modbus read: unknown kind %v", kind)
	}
	if err != nil {
		// Force a redial next time; the read is reported failed this tick.
		if c.handler != nil {
			_ = c.handler.Close()
			c.handler = nil
			c.client = nil
		}
		return nil, fmt.Errorf("modbus read %v(start=%d qty=%d): %w", kind, start, quantity, err)
	}
	return buf, nil
}

// Close releases the device connection.
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.handler != nil {
		err := c.handler.Close()
		c.handler = nil
		c.client = nil
		return err
	}
	return nil
}
