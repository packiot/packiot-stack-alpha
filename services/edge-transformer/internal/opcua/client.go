package opcua

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/gopcua/opcua"
	"github.com/gopcua/opcua/ua"
)

// Client wraps a gopcua session to ONE OPC-UA server (endpoint URL +
// security). gopcua is pure Go (MIT) — no CGo, so the static / distroless build
// (CGO_ENABLED=0) is preserved, consistent with the gos7 + goburrow choices.
// gopcua's *Client is not safe for concurrent Read calls, so a mutex serialises
// them; one Client drives one poll loop.
//
// Security (MVP): default is SecurityPolicy "None" + SecurityMode "None" +
// anonymous auth — the lowest-friction mode, and what a factory OPC-UA server
// on an isolated OT VLAN commonly exposes. Both are configurable per endpoint
// (policy: None|Basic256Sha256|…, mode: None|Sign|SignAndEncrypt) so a
// hardened server can be dialed later, but certificate provisioning for
// Sign/SignAndEncrypt is out of scope for the MVP and noted as follow-up.
type Client struct {
	endpointURL string
	policy      string // OPC-UA security policy name ("None", "Basic256Sha256", …)
	mode        string // OPC-UA message security mode ("None", "Sign", "SignAndEncrypt")
	timeout     time.Duration

	mu sync.Mutex
	c  *opcua.Client
}

// NewClient builds a Client but does NOT dial — call Connect (or let Read lazily
// connect). Empty policy/mode default to "None". timeout bounds each Read
// request; <=0 uses a 5s default.
func NewClient(endpointURL, policy, mode string, timeout time.Duration) *Client {
	if policy == "" {
		policy = "None"
	}
	if mode == "" {
		mode = "None"
	}
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &Client{endpointURL: endpointURL, policy: policy, mode: mode, timeout: timeout}
}

// Connect opens a secure channel + session. Safe to call repeatedly (reconnect)
// — it closes any prior client first.
func (c *Client) Connect(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connectLocked(ctx)
}

func (c *Client) connectLocked(ctx context.Context) error {
	if c.c != nil {
		_ = c.c.Close(ctx)
		c.c = nil
	}
	cl, err := opcua.NewClient(c.endpointURL,
		opcua.SecurityPolicy(c.policy),
		opcua.SecurityModeString(c.mode),
	)
	if err != nil {
		return fmt.Errorf("opcua new client %s (policy=%s mode=%s): %w", c.endpointURL, c.policy, c.mode, err)
	}
	if err := cl.Connect(ctx); err != nil {
		return fmt.Errorf("opcua connect %s: %w", c.endpointURL, err)
	}
	c.c = cl
	return nil
}

// Read reads the Value attribute of every nodeID in one batched request,
// returning one value per nodeID in the SAME order (nil for a node with a bad
// status code). It satisfies ReadFunc. On a transport error it drops the session
// so the next call redials — mirrors the s7/modbus reconnect discipline.
func (c *Client) Read(nodeIDs []string) ([]any, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), c.timeout)
	defer cancel()

	if c.c == nil {
		if err := c.connectLocked(ctx); err != nil {
			return nil, err
		}
	}

	// Parse NodeIDs up front so a config typo fails loudly (not silently nil).
	nodes := make([]*ua.ReadValueID, len(nodeIDs))
	for i, s := range nodeIDs {
		id, err := ua.ParseNodeID(s)
		if err != nil {
			return nil, fmt.Errorf("opcua parse node id %q: %w", s, err)
		}
		nodes[i] = &ua.ReadValueID{NodeID: id, AttributeID: ua.AttributeIDValue}
	}

	req := &ua.ReadRequest{
		// MaxAge 0 = force the server to read the source, not a cached value.
		// Timestamps Neither = we don't need source/server timestamps (the
		// SparkPlug layer stamps its own), shrinking the response.
		MaxAge:             0,
		TimestampsToReturn: ua.TimestampsToReturnNeither,
		NodesToRead:        nodes,
	}

	resp, err := c.c.Read(ctx, req)
	if err != nil {
		_ = c.c.Close(ctx)
		c.c = nil
		return nil, fmt.Errorf("opcua read (%d nodes): %w", len(nodeIDs), err)
	}
	if resp == nil || len(resp.Results) != len(nodeIDs) {
		return nil, fmt.Errorf("opcua read: got %d results for %d nodes", len(resp.Results), len(nodeIDs))
	}

	out := make([]any, len(nodeIDs))
	for i, dv := range resp.Results {
		// A bad status → leave the value nil; the poller reports the tag
		// unreadable rather than emitting a garbage number.
		if dv == nil || dv.Status != ua.StatusOK || dv.Value == nil {
			continue
		}
		out[i] = dv.Value.Value()
	}
	return out, nil
}

// Close releases the OPC-UA session.
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.c != nil {
		ctx, cancel := context.WithTimeout(context.Background(), c.timeout)
		defer cancel()
		err := c.c.Close(ctx)
		c.c = nil
		return err
	}
	return nil
}
