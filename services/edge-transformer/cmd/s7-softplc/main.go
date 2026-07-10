// s7-softplc — a pure-Go Siemens S7 "soft-PLC" for the staging S7 end-to-end
// test. It serves an in-memory data block over real S7comm (ISO-on-TCP) so the
// s7-reader service can read it exactly as it would a physical Incoplast PLC —
// with no CGo, no Snap7/C library, and no real hardware.
//
// It exists so the S7 read path (gos7 client → NBIRTH/NDATA → edge-transformer
// → F1/F3) can run live in staging, where there is no PLC. The same server type
// backs the wire-level integration test in internal/s7/softplc; here it is
// wrapped as a long-running service that also MUTATES the data block each tick
// (counters climb, state stays running) so the downstream OEE pipeline sees
// changing values instead of a flat line.
//
// DB100 layout (big-endian, mirrors the demo tag set in cmd/s7-reader/main.go):
//
//	offset 0  DINT  ProdProcessedCount   (climbs)
//	offset 4  DINT  ProdConsumedCount    (climbs)
//	offset 8  REAL  MachSpeed            (near-constant, small wobble)
//	offset 12 INT   StateCurrent         (6 = running)
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"log/slog"
	"math"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/s7/softplc"
)

func main() {
	addr := flag.String("listen", getenv("LISTEN_ADDR", ":102"), "S7 ISO-on-TCP listen address (102 is the S7 port)")
	dbNum := flag.Int("db", getenvInt("S7_DB", 100), "data block number to serve")
	tickSec := flag.Int("tick", getenvInt("SOFTPLC_TICK_SEC", 5), "seconds between data-block mutations")
	procStep := flag.Int("processed-step", getenvInt("SOFTPLC_PROCESSED_STEP", 20), "ProdProcessedCount increment per tick")
	consStep := flag.Int("consumed-step", getenvInt("SOFTPLC_CONSUMED_STEP", 1), "ProdConsumedCount (scrap) increment per tick")
	speed := flag.Float64("speed", getenvFloat("SOFTPLC_SPEED", 42.5), "MachSpeed base value")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "s7-softplc")

	// Seed the initial DB image. 16 bytes: the four demo tags + 2 pad bytes so a
	// 16-byte read (the s7-reader demo plan) never runs past the block.
	processed := int32(0)
	consumed := int32(0)
	buf := encodeDB(processed, consumed, float32(*speed), 6)

	srv := softplc.New(map[int][]byte{*dbNum: buf})
	if err := srv.StartOn(*addr); err != nil {
		logger.Error("bind S7 listener", "addr", *addr, "err", err)
		os.Exit(1)
	}
	defer srv.Close()
	logger.Info("s7-softplc serving", "addr", srv.Addr(), "db", *dbNum, "tick_sec", *tickSec)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	tick := time.NewTicker(time.Duration(*tickSec) * time.Second)
	defer tick.Stop()

	for {
		select {
		case <-stop:
			logger.Info("s7-softplc stopping")
			return
		case <-tick.C:
			// Advance the counters so the OEE pipeline sees production. Speed
			// gets a tiny deterministic wobble around the base so MachSpeed isn't
			// perfectly flat; state stays 6 (running).
			processed += int32(*procStep)
			consumed += int32(*consStep)
			wobble := float32(math.Sin(float64(processed) / 100.0)) // ~[-1,1]
			srv.SetDB(*dbNum, encodeDB(processed, consumed, float32(*speed)+wobble, 6))
		}
	}
}

// encodeDB lays the four demo tags into a 16-byte big-endian S7 data block.
func encodeDB(processed, consumed int32, speed float32, state int16) []byte {
	b := make([]byte, 16)
	binary.BigEndian.PutUint32(b[0:], uint32(processed))       // DINT ProdProcessedCount
	binary.BigEndian.PutUint32(b[4:], uint32(consumed))        // DINT ProdConsumedCount
	binary.BigEndian.PutUint32(b[8:], math.Float32bits(speed)) // REAL MachSpeed
	binary.BigEndian.PutUint16(b[12:], uint16(state))          // INT  StateCurrent
	// b[14:16] stays zero padding.
	return b
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func getenvInt(k string, d int) int {
	if v := os.Getenv(k); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			return n
		}
	}
	return d
}

func getenvFloat(k string, d float64) float64 {
	if v := os.Getenv(k); v != "" {
		var f float64
		if _, err := fmt.Sscanf(v, "%g", &f); err == nil {
			return f
		}
	}
	return d
}
