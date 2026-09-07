// Package softplc is a pure-Go, stdlib-only S7 "soft-PLC" server: it speaks just
// enough Siemens S7comm (over ISO-on-TCP / RFC1006) to satisfy the gos7 CLIENT
// that internal/s7.Client drives. Its whole reason to exist is TESTING — it lets
// the real gos7 read path (AGReadDB) run end-to-end against an in-memory data
// block store, with no live PLC, no CGo, and no build tags.
//
// # Protocol layering (bottom to top) — the "why" behind every response byte
//
// A Siemens read is three nested envelopes. Reading the client's parser
// (github.com/robinson/gos7 tcpclient.go + client.go) tells us EXACTLY which
// bytes it inspects; we match those and keep the rest protocol-plausible.
//
//		┌──────────────────────────────────────────────────────────────┐
//		│ TPKT (RFC1006)   4 bytes: 03 00 <len_hi> <len_lo>            │  framing
//		│  ├───────────────────────────────────────────────────────┐   │
//		│  │ COTP (ISO 8073)   CR/CC handshake, then DT data units  │   │  transport
//		│  │  ├────────────────────────────────────────────────┐    │   │
//		│  │  │ S7comm (ROSCTR job / ack_data)                 │    │   │  application
//		│  │  └────────────────────────────────────────────────┘    │   │
//		│  └───────────────────────────────────────────────────────┘   │
//		└──────────────────────────────────────────────────────────────┘
//
//	 1. TPKT: every message is prefixed with 03 00 and a 16-bit big-endian TOTAL
//	    length (header included). gos7's transporter reads the 4-byte header, then
//	    `length-4` more bytes (tcpclient.go Send). So our TPKT length field must
//	    equal the real frame size or the client blocks / errors.
//
//	 2. COTP: connection setup is a Connection Request (CR, PDU type 0xE0) from the
//	    client answered by a Connection Confirm (CC, 0xD0). The client checks the
//	    CC is EXACTLY 22 bytes and that the PDU-type byte (frame[5]) == 0xD0
//	    (tcpclient.go isoConnect). After that, S7 payloads travel inside COTP DT
//	    data units (PDU type 0xF0, byte sequence 02 F0 80 = LI, DT, EOT).
//
//	 3. S7comm: a request is ROSCTR 0x01 (job); a reply is ROSCTR 0x03 (ack_data).
//	    Two jobs matter here — Setup Communication (function 0xF0, negotiates the
//	    max PDU length) and Read Var (function 0x04). We answer both.
//
// Everything is bounds-checked: a malformed client frame yields an S7 error PDU
// or a dropped connection, never a panic. gos7's Client.Read drops and redials
// on any read error, so a rejected/half frame degrades to a reconnect, not a
// crash — exactly what we exercise in the reconnect test.
package softplc

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
)

// S7 item return codes (data section, response byte [21]). The client treats
// 0xFF as success and anything else as a CPU error (client.go readArea).
const (
	s7ItemOK          = 0xFF // success — payload follows
	s7ItemObjNotExist = 0x0A // "object does not exist" — we use it for unknown DB
	s7ItemOutOfRange  = 0x05 // "address out of range" — start+size past the DB
	s7ItemUnsupported = 0x03 // "object access not allowed" — malformed/other
)

// negotiatedPDULen is the max S7 PDU length we advertise in the Setup
// Communication ack. 240 is the classic S7-300 value; negotiating DOWN from the
// client's proposed 480 exercises the real negotiation path (the client stores
// whatever we return in PDULength and sizes its read chunking off it). 240 is
// ample for the tiny reads here — one AGReadDB stays a single ReadVar round-trip.
const negotiatedPDULen = 240

// Server is an in-memory S7 soft-PLC. Zero value is not usable — call New.
type Server struct {
	mu    sync.Mutex
	store map[int][]byte // DB number → raw bytes (big-endian S7 layout)

	ln     net.Listener
	closed chan struct{}
	wg     sync.WaitGroup
}

// New builds a soft-PLC seeded with the given data blocks. seed may be nil; the
// map is copied so the caller can't mutate our store behind the mutex. Call
// Start to bind and begin serving.
func New(seed map[int][]byte) *Server {
	store := make(map[int][]byte, len(seed))
	for db, data := range seed {
		cp := make([]byte, len(data))
		copy(cp, data)
		store[db] = cp
	}
	return &Server{store: store, closed: make(chan struct{})}
}

// SetDB installs (or replaces) a data block. Safe to call while serving.
func (s *Server) SetDB(db int, data []byte) {
	cp := make([]byte, len(data))
	copy(cp, data)
	s.mu.Lock()
	s.store[db] = cp
	s.mu.Unlock()
}

// Start binds a TCP listener on 127.0.0.1:0 (an OS-chosen free port so parallel
// tests never collide) and launches the accept loop in a goroutine. Use Addr to
// discover the chosen host:port. This is the test entry point.
func (s *Server) Start() error {
	return s.StartOn("127.0.0.1:0")
}

// StartOn is Start with an explicit bind address — used by the cmd/s7-softplc
// binary to listen on a container-reachable address (e.g. "0.0.0.0:102", the S7
// ISO-on-TCP port) so the s7-reader service can dial it across the compose
// network. Tests use Start (loopback, ephemeral port).
func (s *Server) StartOn(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	s.ln = ln
	s.wg.Add(1)
	go s.serve()
	return nil
}

// Addr returns the resolved listen address (host:port). Only valid after Start.
func (s *Server) Addr() string {
	if s.ln == nil {
		return ""
	}
	return s.ln.Addr().String()
}

// Close stops accepting and waits for the accept loop to drain. Idempotent.
func (s *Server) Close() error {
	select {
	case <-s.closed:
		return nil // already closed
	default:
		close(s.closed)
	}
	var err error
	if s.ln != nil {
		err = s.ln.Close() // unblocks Accept with a net.ErrClosed
	}
	s.wg.Wait()
	return err
}

// serve accepts connections sequentially. gos7 drives one PLC over one session,
// but it redials on any read error, so we must survive an arbitrary number of
// sequential connections. We handle one connection at a time (each fully drained
// before the next Accept) which is all a single client needs; it also keeps the
// store access trivially ordered.
func (s *Server) serve() {
	defer s.wg.Done()
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			// Accept fails once Close shuts the listener — that's our exit.
			select {
			case <-s.closed:
				return
			default:
				return // any other accept error: nothing left to serve
			}
		}
		s.handleConn(conn)
	}
}

// handleConn runs the S7 state machine for one client session: CR→CC, then a
// stream of S7 job frames (Setup Comm, Read Var) until the client hangs up or
// sends something we can't parse. Any framing/parse error simply closes the
// connection; the real client redials, so we never need to recover in place.
func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()
	for {
		frame, err := readTPKT(conn)
		if err != nil {
			return // EOF / client closed / malformed framing → drop the session
		}
		// COTP PDU type lives at frame[5] (after the 4-byte TPKT header and the
		// 1-byte COTP length indicator). It tells us CR vs. a DT data unit.
		if len(frame) < 6 {
			return
		}
		switch frame[5] {
		case 0xE0: // COTP Connection Request → Connection Confirm
			if _, err := conn.Write(buildCC(frame)); err != nil {
				return
			}
		case 0xF0: // COTP DT data unit → carries an S7comm PDU
			resp, ok := s.handleS7(frame)
			if !ok {
				return // unparseable S7 job → drop; client will redial
			}
			if _, err := conn.Write(resp); err != nil {
				return
			}
		default:
			return // unknown COTP PDU type → drop
		}
	}
}

// handleS7 dispatches an S7comm PDU carried in a COTP DT frame. Both Setup
// Communication and Read Var arrive as ROSCTR job (0x01); they differ by the
// FUNCTION byte at offset 17 (the first parameter byte, right after the 10-byte
// S7 job header + the 2-byte error-free-for-job gap that ack_data adds). We key
// off frame[17]: 0xF0 = Setup Comm, 0x04 = Read Var.
func (s *Server) handleS7(frame []byte) (resp []byte, ok bool) {
	// Minimum S7 job: TPKT(4) + COTP(3) + S7 header(10) + at least 1 param byte.
	if len(frame) < 18 {
		return nil, false
	}
	if frame[7] != 0x32 || frame[8] != 0x01 { // 0x32 = S7 protocol id, 0x01 = job
		return nil, false
	}
	switch frame[17] { // function byte (first parameter)
	case 0xF0: // Setup Communication
		return buildSetupAck(frame), true
	case 0x04: // Read Var
		return s.buildReadResponse(frame), true
	default:
		return nil, false
	}
}

// ---------------------------------------------------------------------------
// Response builders
// ---------------------------------------------------------------------------

// buildCC turns a client Connection Request into a Connection Confirm. gos7 only
// checks two things (isoConnect): the reply is EXACTLY 22 bytes and the PDU-type
// byte is 0xD0. Everything else is cosmetic to the client, but we still fill a
// protocol-plausible CC: swap the reference numbers (the confirm's destination
// reference echoes the request's source reference) and assign our own source
// reference, mirroring what a real PLC does.
func buildCC(cr []byte) []byte {
	cc := make([]byte, 22)
	// TPKT: version 3, reserved 0, total length 22 big-endian.
	cc[0] = 0x03
	cc[1] = 0x00
	binary.BigEndian.PutUint16(cc[2:4], 22)
	// COTP CC. LI (length indicator) = 17: 17 bytes follow the LI byte
	// (indices 5..21). 4 (TPKT) + 1 (LI) + 17 = 22.
	cc[4] = 0x11 // LI
	cc[5] = 0xD0 // PDU type: Connection Confirm — the byte gos7 asserts
	// Destination reference = the request's source reference (cr[8:10]); source
	// reference = a server-assigned handle. cr is a 22-byte CR: src-ref at [8:10].
	if len(cr) >= 10 {
		cc[6] = cr[8]
		cc[7] = cr[9]
	}
	cc[8] = 0x00  // our source reference hi
	cc[9] = 0x01  // our source reference lo
	cc[10] = 0x00 // class / options
	// TPDU-size parameter: code 0xC0, len 1, value 0x0A (2^10 = 1024).
	cc[11] = 0xC0
	cc[12] = 0x01
	cc[13] = 0x0A
	// Calling/called TSAP parameters, echoed from the CR (client ignores them,
	// but a real CC carries them). CR layout: src-tsap at [16:18], dst-tsap at
	// [20:22]. We echo them straight through.
	cc[14] = 0xC1
	cc[15] = 0x02
	if len(cr) >= 22 {
		cc[16] = cr[16]
		cc[17] = cr[17]
	}
	cc[18] = 0xC2
	cc[19] = 0x02
	if len(cr) >= 22 {
		cc[20] = cr[20]
		cc[21] = cr[21]
	}
	return cc
}

// buildSetupAck answers a Setup Communication job with an S7 ack_data that
// negotiates the max PDU length. gos7's negotiatePduLength requires the reply be
// EXACTLY 27 bytes, with the S7 error class/code bytes (response[17], [18]) both
// zero, and reads the negotiated length from big-endian response[25:27].
//
// Layout (27 bytes):
//
//	[0:4]   TPKT           03 00 00 1B (len 27)
//	[4:7]   COTP DT        02 F0 80 (LI=2, DT, EOT)
//	[7]     S7 proto id    32
//	[8]     ROSCTR         03 (ack_data)
//	[9:11]  redundancy     00 00
//	[11:13] PDU reference  echoed from the request
//	[13:15] param length   00 08 (8-byte setup param)
//	[15:17] data length    00 00
//	[17]    error class    00   ← client asserts == 0
//	[18]    error code     00   ← client asserts == 0
//	[19]    function       F0 (setup comm)
//	[20]    reserved       00
//	[21:23] max AmQ caller 00 01
//	[23:25] max AmQ called 00 01
//	[25:27] PDU length     negotiated, big-endian ← client stores this
func buildSetupAck(req []byte) []byte {
	r := make([]byte, 27)
	r[0] = 0x03
	binary.BigEndian.PutUint16(r[2:4], 27)
	r[4] = 0x02
	r[5] = 0xF0
	r[6] = 0x80
	r[7] = 0x32
	r[8] = 0x03 // ack_data
	// Echo the request's PDU reference (req[11:13]) so a real client could
	// correlate; gos7 doesn't check it but a real PLC preserves it.
	if len(req) >= 13 {
		r[11] = req[11]
		r[12] = req[12]
	}
	binary.BigEndian.PutUint16(r[13:15], 8) // param length
	binary.BigEndian.PutUint16(r[15:17], 0) // data length
	r[17] = 0x00                            // error class — MUST be 0
	r[18] = 0x00                            // error code  — MUST be 0
	r[19] = 0xF0                            // function: setup communication
	r[20] = 0x00
	binary.BigEndian.PutUint16(r[21:23], 1)                        // max AmQ calling
	binary.BigEndian.PutUint16(r[23:25], 1)                        // max AmQ called
	binary.BigEndian.PutUint16(r[25:27], uint16(negotiatedPDULen)) // negotiated PDU length
	return r
}

// buildReadResponse answers a Read Var job. gos7's readArea checks:
//   - len(response) >= 25
//   - response[21] == 0xFF (item return code success), else CPU error
//   - copies response[25 : 25+sizeRequested] as the payload
//
// So the item return code sits at [21] and the payload at [25]. We parse the
// request for (db, start, size), fetch the slice, and either return it or, on a
// bad address, return a 25-byte error PDU (return code != 0xFF, no payload) so
// the client surfaces an error instead of reading garbage.
//
// Request field offsets (client.go readArea, byte reads use word length "byte"):
//
//	[23:25] numElements (big-endian) == byte count for a byte read == size
//	[25:27] DB number   (big-endian)
//	[27]    area type    (0x84 = DB)
//	[28:31] bit address  (big-endian) == start << 3
func (s *Server) buildReadResponse(req []byte) []byte {
	// A Read Var request header is 31 bytes; anything shorter is malformed.
	if len(req) < 31 {
		return buildReadError(req, s7ItemUnsupported, 0)
	}
	numElements := int(binary.BigEndian.Uint16(req[23:25]))
	db := int(binary.BigEndian.Uint16(req[25:27]))
	// Address is a 3-byte big-endian BIT address; byte start = bits >> 3.
	bitAddr := int(req[28])<<16 | int(req[29])<<8 | int(req[30])
	start := bitAddr >> 3
	size := numElements // byte word length ⇒ one element per byte

	data, ok := s.readDB(db, start, size)
	if !ok {
		// Distinguish "no such DB" from "range past end" purely for realism —
		// the client errors on either. We can't cheaply tell them apart after
		// the fact, so pick the code inside readDB's failure by re-checking.
		s.mu.Lock()
		_, dbExists := s.store[db]
		s.mu.Unlock()
		code := s7ItemOutOfRange
		if !dbExists {
			code = s7ItemObjNotExist
		}
		return buildReadError(req, byte(code), size)
	}

	// Success PDU. Total length = 25 (header up to and including the 4-byte item
	// header) + size (payload).
	total := 25 + size
	r := make([]byte, total)
	r[0] = 0x03
	binary.BigEndian.PutUint16(r[2:4], uint16(total))
	r[4] = 0x02
	r[5] = 0xF0
	r[6] = 0x80
	r[7] = 0x32
	r[8] = 0x03 // ack_data
	// Echo the request's PDU reference (req[11:13]).
	r[11] = req[11]
	r[12] = req[12]
	binary.BigEndian.PutUint16(r[13:15], 2)              // param length: function + item count
	binary.BigEndian.PutUint16(r[15:17], uint16(4+size)) // data length: item header (4) + payload
	r[17] = 0x00                                         // error class
	r[18] = 0x00                                         // error code
	r[19] = 0x04                                         // function: read var
	r[20] = 0x01                                         // item count
	// Item header (data section):
	r[21] = s7ItemOK // return code 0xFF — the byte gos7 asserts
	r[22] = 0x04     // transport size: BYTE
	// For transport size BYTE the length field is in BITS. gos7 ignores this
	// field (it slices by the size it requested) but a real PLC sets it, so do
	// the correct thing: size * 8 bits.
	binary.BigEndian.PutUint16(r[23:25], uint16(size*8))
	copy(r[25:], data) // payload — the seeded DB bytes
	return r
}

// buildReadError builds a 25-byte Read Var ack_data whose single item carries an
// error return code and no payload. 25 bytes satisfies gos7's `len >= 25` guard,
// and response[21] != 0xFF makes it surface a CPU error and drop the connection.
func buildReadError(req []byte, code byte, _ int) []byte {
	r := make([]byte, 25)
	r[0] = 0x03
	binary.BigEndian.PutUint16(r[2:4], 25)
	r[4] = 0x02
	r[5] = 0xF0
	r[6] = 0x80
	r[7] = 0x32
	r[8] = 0x03
	if len(req) >= 13 {
		r[11] = req[11]
		r[12] = req[12]
	}
	binary.BigEndian.PutUint16(r[13:15], 2) // param length
	binary.BigEndian.PutUint16(r[15:17], 4) // data length: bare 4-byte item header
	r[17] = 0x00
	r[18] = 0x00
	r[19] = 0x04 // function: read var
	r[20] = 0x01 // item count
	r[21] = code // error return code (!= 0xFF)
	r[22] = 0x00 // transport size 0 (no data)
	binary.BigEndian.PutUint16(r[23:25], 0)
	return r
}

// readDB returns store[db][start:start+size] (a copy) or ok=false if the DB is
// unknown or the range is out of bounds. Bounds-checked so a bad request can
// never index past a slice.
func (s *Server) readDB(db, start, size int) ([]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, ok := s.store[db]
	if !ok {
		return nil, false
	}
	if start < 0 || size < 0 || start+size > len(data) {
		return nil, false
	}
	out := make([]byte, size)
	copy(out, data[start:start+size])
	return out, true
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

// errShortFrame is returned when a TPKT length field is implausible.
var errShortFrame = errors.New("softplc: malformed TPKT frame")

// readTPKT reads one whole TPKT-framed message: the 4-byte header (03 00 len_hi
// len_lo) then `len-4` payload bytes. It mirrors gos7's own transporter read so
// the two agree on frame boundaries. Returns io.EOF when the client hangs up
// cleanly between frames.
func readTPKT(r io.Reader) ([]byte, error) {
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return nil, err // includes io.EOF on a clean close
	}
	if hdr[0] != 0x03 {
		return nil, errShortFrame
	}
	length := int(binary.BigEndian.Uint16(hdr[2:4]))
	// A TPKT frame is at least its own 4-byte header; cap at gos7's tcpMaxLength
	// (2084) so a corrupt length can't make us allocate wildly.
	if length < 4 || length > 2084 {
		return nil, errShortFrame
	}
	frame := make([]byte, length)
	copy(frame, hdr)
	if length > 4 {
		if _, err := io.ReadFull(r, frame[4:]); err != nil {
			return nil, err
		}
	}
	return frame, nil
}
