package s7

import (
	"fmt"
	"sync"
	"time"

	"github.com/robinson/gos7"
)

// Client wraps a gos7 TCP session to ONE S7 PLC (IP + rack + slot). gos7 is a
// pure-Go, clean-room S7comm implementation (BSD-3) — no CGo, so the static /
// distroless build (CGO_ENABLED=0) is preserved. A gos7 handler is not
// goroutine-safe, so a mutex serialises reads; one Client drives one poll loop.
type Client struct {
	address    string
	rack, slot int
	timeout    time.Duration

	mu      sync.Mutex
	handler *gos7.TCPClientHandler
	client  gos7.Client
}

// NewClient builds a Client but does NOT dial — call Connect (or let Read
// lazily connect). timeout bounds each request; <=0 uses a 5s default.
func NewClient(address string, rack, slot int, timeout time.Duration) *Client {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &Client{address: address, rack: rack, slot: slot, timeout: timeout}
}

// Connect dials the PLC. Safe to call repeatedly (reconnect) — it closes any
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
	h := gos7.NewTCPClientHandler(c.address, c.rack, c.slot)
	h.Timeout = c.timeout
	h.IdleTimeout = 4 * c.timeout
	if err := h.Connect(); err != nil {
		return fmt.Errorf("s7 connect %s (rack=%d slot=%d): %w", c.address, c.rack, c.slot, err)
	}
	c.handler = h
	c.client = gos7.NewClient(h)
	return nil
}

// Read reads size bytes from data block db starting at start. It satisfies
// ReadFunc. On a transport error it drops the connection so the next call (or
// an explicit Connect) redials — mirrors the MQTT subscriber's reconnect
// discipline.
func (c *Client) Read(db, start, size int) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.client == nil {
		if err := c.connectLocked(); err != nil {
			return nil, err
		}
	}
	buf := make([]byte, size)
	if err := c.client.AGReadDB(db, start, size, buf); err != nil {
		// Force a redial next time; the read is reported failed this tick.
		if c.handler != nil {
			_ = c.handler.Close()
			c.handler = nil
			c.client = nil
		}
		return nil, fmt.Errorf("s7 AGReadDB(db=%d start=%d size=%d): %w", db, start, size, err)
	}
	return buf, nil
}

// Close releases the PLC connection.
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
