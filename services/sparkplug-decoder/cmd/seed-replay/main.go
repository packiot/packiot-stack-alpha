// seed-replay — ADR-0060 D7: makes the local dev environment LIVE by replaying the dev seed's own week.
//
// The dev seed (ADR-0060 D4) is a frozen, anonymized week of CPACK-shaped data, rebased by whole weeks on load
// (D6), so a Tier-0-only slice shows data 0–7 days old. seed-replay closes the gap to "now": at wall-clock time T
// it reads the seed's silver rows for (T − lag − tick, T − lag] (lag = 7 days) and publishes them as SparkPlug B
// over the local MQTT broker, at wall-clock pace. With Tier 2 running, the REAL decoder and stream-engine turn that
// into fresh silver/gold rows at T — which next week's lap reads back (lap-based: week k+1 = week k + 7 days).
//
// Wire shape = the edge-source contract (docs/reference/edge-source-topic-contract.md), the same one plc-sim and
// the sparkplug-agent speak:
//   - one NBIRTH for edge node <group>/<edge-node>, every metric with an alias;
//   - per equipment: gross/net/scrap counters as canonical count leaves (…/ProdConsumedCount/<n>/Unit etc.) with
//     the ADR-0046 counter_role + the ADR-0061 DECLARED device_key, plus StateCurrent (role state.current) and
//     MachSpeed (role speed.current) carrying the same device_key;
//   - NDATA every tick, alias + value only.
//
// Identity: device_key comes from the seed's core.device_bindings (random keys minted when the seed was built —
// never real ones), and the decoder resolves it through read-api /internal/resolve-device exactly as on staging.
// Names are the seed's own (anonymized) packml_register topics, because stream-engine still resolves equipment by
// topic until ADR-0061 removes it (staging runs the same way): each registered counter path
// (…/ProdConsumedCount/<n>/Unit etc.) is published verbatim, and StateCurrent/MachSpeed go under the equipment's
// shortest registered topic. An equipment with no registered counter path (a line's own stream) gets
// <topic>/Admin/<leaf>/<id_equipment>/Unit, the shape plc-sim uses for line own-streams. Each metric ALSO declares
// its device_key, so the same births keep working when routing moves to the declared identity.
//
// Counters are cumulative, as a PLC sends them: a running sum of the seed's *_incr per equipment, starting at the
// birth value. A restart re-births, and the decoder baselines a new session at its birth value (no spike).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/birth"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// binding is one replayed equipment: its seed id, DECLARED device_key and the names it publishes under.
type binding struct {
	IDEquipment int
	DeviceKey   string
	Topic       string            // shortest registered topic: StateCurrent / MachSpeed live under it
	Counters    map[uint64]string // slotGross/slotNet/slotScrap → full metric name (registered path)
	// Carries: the slots the seed has values for on this equipment. A metric the PLC never sends (NULL all week) is
	// not published at all: a constant-0 net next to a rising gross reads downstream as scrap, and a line has no
	// state of its own.
	Carries map[uint64]bool
}

// counterSlot maps a canonical count leaf to its slot (birth.go: Consumed→gross, Processed→net, Defective→scrap).
var counterSlot = map[string]uint64{"ProdConsumedCount": slotGross, "ProdProcessedCount": slotNet, "ProdDefectiveCount": slotScrap}

// metricName is the published name of a slot, "" when this equipment does not publish it.
func (b binding) metricName(slot uint64) string {
	if !b.Carries[slot] {
		return ""
	}
	switch slot {
	case slotSpeed:
		return b.Topic + "/Status/MachSpeed"
	case slotState:
		return b.Topic + "/Status/StateCurrent"
	}
	if len(b.Counters) == 0 { // no registered counter path: the line own-stream shape
		for leaf, sl := range counterSlot {
			if sl == slot {
				return fmt.Sprintf("%s/Admin/%s/%d/Unit", b.Topic, leaf, b.IDEquipment)
			}
		}
	}
	return b.Counters[slot]
}

// sample is one seed silver row, the fields the wire carries. NULL means "not sent in this row" for every field
// (never 0): a line has counters but no state, many machines never send net.
type sample struct {
	IDEquipment                int
	Ts                         time.Time
	Gross, Net, Scrap          float64
	HasGross, HasNet, HasScrap bool
	Speed                      float64
	HasSpeed                   bool
	State                      int64
	HasState                   bool
}

// eqState is the replayed PLC's memory for one equipment.
type eqState struct {
	gross, net, scrap float64
	speed             float64
	state             int64
	hasState          bool
}

// Metric slots per equipment: base+1..base+5. aliasBase spaces equipments 10 aliases apart (like plc-sim).
const (
	slotGross = iota + 1
	slotNet
	slotScrap
	slotSpeed
	slotState
)

func aliasBase(i int) uint64 { return uint64((i + 1) * 10) }

// buildBirth is the NBIRTH metric set: every equipment's published metrics with names, aliases, current values
// and the declared properties. Pure, so the producer↔consumer round trip is unit-testable.
func buildBirth(bs []binding, st map[int]*eqState) ([]sparkplug.SimMetric, error) {
	var ms []sparkplug.SimMetric
	for i, b := range bs {
		s := st[b.IDEquipment]
		base := aliasBase(i)
		for slot := uint64(slotGross); slot <= slotState; slot++ {
			name := b.metricName(slot)
			if name == "" {
				continue
			}
			var role string
			switch slot {
			case slotSpeed:
				role = "speed.current"
			case slotState:
				role = "state.current"
			}
			ps, ok := birth.MetricProps(name, b.DeviceKey, role)
			if !ok {
				return nil, fmt.Errorf("no birth properties for %q", name)
			}
			m := sparkplug.SimMetric{Name: name, Alias: base + slot, Props: ps}
			switch slot {
			case slotGross:
				m.Double = s.gross
			case slotNet:
				m.Double = s.net
			case slotScrap:
				m.Double = s.scrap
			case slotSpeed:
				m.Double = s.speed
			case slotState:
				m.Long, m.IsLong = s.state, true
			}
			ms = append(ms, m)
		}
	}
	return ms, nil
}

// step applies one window of seed rows (in ts order) to the PLC memory and returns the NDATA metrics: the final
// counters of every equipment that had a row, plus speed/state when the window carried them. Equipments with no
// row in the window send nothing (report-by-exception, like a real edge node).
func step(bs []binding, idx map[int]int, st map[int]*eqState, rows []sample) []sparkplug.SimMetric {
	touched := map[int]bool{}
	sent := map[int]map[uint64]bool{}
	for _, r := range rows {
		s, ok := st[r.IDEquipment]
		if !ok {
			continue
		}
		if sent[r.IDEquipment] == nil {
			sent[r.IDEquipment] = map[uint64]bool{}
		}
		if r.HasGross {
			s.gross += r.Gross
			sent[r.IDEquipment][slotGross] = true
		}
		if r.HasNet {
			s.net += r.Net
			sent[r.IDEquipment][slotNet] = true
		}
		if r.HasScrap {
			s.scrap += r.Scrap
			sent[r.IDEquipment][slotScrap] = true
		}
		if r.HasSpeed {
			s.speed = r.Speed
			sent[r.IDEquipment][slotSpeed] = true
		}
		if r.HasState {
			s.state, s.hasState = r.State, true
			sent[r.IDEquipment][slotState] = true
		}
		touched[r.IDEquipment] = true
	}
	var ms []sparkplug.SimMetric
	for _, b := range bs {
		if !touched[b.IDEquipment] {
			continue
		}
		s, base, sn := st[b.IDEquipment], aliasBase(idx[b.IDEquipment]), sent[b.IDEquipment]
		for _, c := range []struct {
			slot uint64
			v    float64
		}{{slotGross, s.gross}, {slotNet, s.net}, {slotScrap, s.scrap}, {slotSpeed, s.speed}} {
			if sn[c.slot] && b.metricName(c.slot) != "" {
				ms = append(ms, sparkplug.SimMetric{Alias: base + c.slot, Double: c.v})
			}
		}
		if sn[slotState] {
			ms = append(ms, sparkplug.SimMetric{Alias: base + slotState, Long: s.state, IsLong: true})
		}
	}
	return ms
}

// bindingsSQL: every actively bound equipment with seed values, its shortest registered topic, its registered
// counter paths (leaf + full name) and which counters the seed carries at all. Equipments with no registered topic
// cannot be resolved downstream and are skipped (logged).
const bindingsSQL = `
SELECT b.id_equipment, b.device_key,
       (SELECT pr.packml_topic FROM packml_register pr
         WHERE pr.active AND pr.id_equipment = b.id_equipment AND pr.packml_topic !~ '/Unit$'
         ORDER BY length(pr.packml_topic), pr.packml_topic LIMIT 1),
       coalesce((SELECT array_agg(substring(pr.packml_topic FROM '/(Prod[A-Za-z]+Count)/[0-9]+/Unit$') || '|' || pr.packml_topic
                                  ORDER BY pr.packml_topic)
                   FROM packml_register pr
                  WHERE pr.active AND pr.id_equipment = b.id_equipment
                    AND pr.packml_topic ~ '/Prod(Consumed|Processed|Defective)Count/[0-9]+/Unit$'), '{}'),
       c.g, c.n, c.s, c.sp, c.st
  FROM core.device_bindings b
  JOIN (SELECT id_equipment, bool_or(gross_production_incr IS NOT NULL) g, bool_or(net_production_incr IS NOT NULL) n,
               bool_or(scrap_incr IS NOT NULL) s, bool_or(speed IS NOT NULL) sp, bool_or(state IS NOT NULL) st
          FROM silver.equipment_values GROUP BY 1) c USING (id_equipment)
 WHERE b.active
   AND ($1::int[] IS NULL OR b.id_enterprise = ANY ($1::int[]))
 ORDER BY b.id_equipment`

// parseCounters turns "<leaf>|<full name>" rows into slot → name, first registration per slot wins (the seed has
// a few duplicate registrations of the same leaf).
func parseCounters(rows []string) map[uint64]string {
	out := map[uint64]string{}
	for _, r := range rows {
		leaf, name, ok := strings.Cut(r, "|")
		if !ok {
			continue
		}
		if slot, ok := counterSlot[leaf]; ok {
			if _, dup := out[slot]; !dup {
				out[slot] = name
			}
		}
	}
	return out
}

// windowSQL reads the seed rows for (from, to]. Replayed rows written back by the pipeline are read the same way
// a week later — that is the lap.
const windowSQL = `
SELECT id_equipment, ts_value, gross_production_incr, net_production_incr, scrap_incr, speed, state
  FROM silver.equipment_values
 WHERE ts_value > $1 AND ts_value <= $2 AND id_equipment = ANY ($3::int[])
 ORDER BY ts_value, id_equipment`

func loadWindow(ctx context.Context, db *pgxpool.Pool, from, to time.Time, ids []int) ([]sample, error) {
	rows, err := db.Query(ctx, windowSQL, from, to, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []sample
	for rows.Next() {
		var r sample
		var g, n, s, speed *float32
		var state *int32
		if err := rows.Scan(&r.IDEquipment, &r.Ts, &g, &n, &s, &speed, &state); err != nil {
			return nil, err
		}
		if g != nil {
			r.Gross, r.HasGross = float64(*g), true
		}
		if n != nil {
			r.Net, r.HasNet = float64(*n), true
		}
		if s != nil {
			r.Scrap, r.HasScrap = float64(*s), true
		}
		if speed != nil {
			r.Speed, r.HasSpeed = float64(*speed), true
		}
		if state != nil {
			r.State, r.HasState = int64(*state), true
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func parseEnterprises(s string) ([]int32, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	var out []int32
	for _, f := range strings.Split(s, ",") {
		n, err := strconv.Atoi(strings.TrimSpace(f))
		if err != nil {
			return nil, fmt.Errorf("REPLAY_ENTERPRISES: %q is not an integer", f)
		}
		out = append(out, int32(n))
	}
	return out, nil
}

func main() {
	broker := flag.String("broker", getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"), "MQTT broker")
	group := flag.String("group", getenv("REPLAY_GROUP_ID", "DEV"), "Sparkplug group id (routing comes from the metric names / device_key, not this)")
	edgeNode := flag.String("edge-node", getenv("REPLAY_EDGE_NODE", "seed-replay"), "Sparkplug edge node id")
	dsn := flag.String("dsn", os.Getenv("DATABASE_URL"), "dev Postgres DSN (the seed)")
	tick := flag.Duration("tick", getenvDuration("REPLAY_TICK", 5*time.Second), "publish interval")
	lag := flag.Duration("lag", getenvDuration("REPLAY_LAG", 7*24*time.Hour), "replay offset (whole weeks, ADR-0060 D6)")
	ents := flag.String("enterprises", os.Getenv("REPLAY_ENTERPRISES"), "comma-separated id_enterprise filter (empty = all)")
	flag.Parse()
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "seed-replay")

	if err := run(logger, *broker, *group, *edgeNode, *dsn, *tick, *lag, *ents); err != nil {
		logger.Error("seed-replay failed", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger, broker, group, edgeNode, dsn string, tick, lag time.Duration, ents string) error {
	if dsn == "" {
		return errors.New("DATABASE_URL is empty")
	}
	if lag <= 0 || lag%(7*24*time.Hour) != 0 {
		// Whole weeks keep shift calendars and weekday patterns aligned (ADR-0060 D6).
		return fmt.Errorf("REPLAY_LAG must be a positive whole number of weeks, got %s", lag)
	}
	entFilter, err := parseEnterprises(ents)
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return err
	}
	defer db.Close()

	var bs []binding
	rows, err := db.Query(ctx, bindingsSQL, entFilter)
	if err != nil {
		return fmt.Errorf("load bindings: %w", err)
	}
	for rows.Next() {
		var b binding
		var topic *string
		var counters []string
		var g, n, sc, sp, stt bool
		if err := rows.Scan(&b.IDEquipment, &b.DeviceKey, &topic, &counters, &g, &n, &sc, &sp, &stt); err != nil {
			rows.Close()
			return err
		}
		if topic == nil {
			logger.Warn("equipment has a binding but no registered topic — not replayed", "id_equipment", b.IDEquipment)
			continue
		}
		b.Topic, b.Counters = *topic, parseCounters(counters)
		b.Carries = map[uint64]bool{slotGross: g, slotNet: n, slotScrap: sc, slotSpeed: sp, slotState: stt}
		bs = append(bs, b)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if len(bs) == 0 {
		return errors.New("no active device_bindings with seed values — is DEVDB_IMAGE the dev seed?")
	}
	ids := make([]int, len(bs))
	idx := make(map[int]int, len(bs))
	st := make(map[int]*eqState, len(bs))
	for i, b := range bs {
		ids[i], idx[b.IDEquipment], st[b.IDEquipment] = b.IDEquipment, i, &eqState{}
	}

	var seq uint64
	// mu serializes the births (paho callback goroutines) with the replay loop:
	// both read st and advance seq.
	var mu sync.Mutex
	birthTopic := "spBv1.0/" + group + "/NBIRTH/" + edgeNode
	dataTopic := "spBv1.0/" + group + "/NDATA/" + edgeNode
	cmdTopic := "spBv1.0/" + group + "/NCMD/" + edgeNode
	publishBirth := func(c paho.Client) {
		mu.Lock()
		defer mu.Unlock()
		ms, err := buildBirth(bs, st)
		if err != nil {
			logger.Error("build NBIRTH", "err", err)
			return
		}
		body, err := sparkplug.EncodeSim(ms, &seq, true)
		if err != nil {
			logger.Error("encode NBIRTH", "err", err)
			return
		}
		c.Publish(birthTopic, 0, false, body).Wait()
		logger.Info("NBIRTH published", "equipments", len(bs), "metrics", len(ms))
	}
	// Honor the decoder's NCMD "Node Control/Rebirth" (task #31) like the real
	// edge agent: a restarted decoder has an empty alias table and asks for a
	// rebirth. Without this a decoder restart in dev stalled until seed-replay
	// itself restarted — which resets its counters and hides restart behavior.
	onConnect := func(c paho.Client) {
		publishBirth(c)
		c.Subscribe(cmdTopic, 1, func(c paho.Client, _ paho.Message) {
			logger.Info("NCMD received — re-publishing NBIRTH")
			go publishBirth(c)
		})
	}
	opts := paho.NewClientOptions().AddBroker(broker).
		SetClientID(fmt.Sprintf("seed-replay-%d", os.Getpid())).
		SetAutoReconnect(true).SetConnectRetry(true).
		SetOnConnectHandler(onConnect)
	client := paho.NewClient(opts)
	if tok := client.Connect(); tok.Wait() && tok.Error() != nil {
		return fmt.Errorf("mqtt connect: %w", tok.Error())
	}
	defer client.Disconnect(250)

	t := time.NewTicker(tick)
	defer t.Stop()
	cursor := time.Now().Add(-lag)
	logger.Info("seed-replay running", "equipments", len(bs), "tick", tick.String(), "lag", lag.String(), "replaying_from", cursor)
	for {
		select {
		case <-ctx.Done():
			logger.Info("seed-replay stopping")
			return nil
		case now := <-t.C:
			to := now.Add(-lag)
			rs, err := loadWindow(ctx, db, cursor, to, ids)
			mu.Lock()
			if err != nil {
				mu.Unlock()
				logger.Error("load window", "err", err, "from", cursor, "to", to)
				continue // retry the same window next tick
			}
			cursor = to
			ms := step(bs, idx, st, rs)
			if len(ms) == 0 {
				mu.Unlock()
				continue
			}
			body, err := sparkplug.EncodeSim(ms, &seq, false)
			mu.Unlock()
			if err != nil {
				logger.Error("encode NDATA", "err", err)
				continue
			}
			client.Publish(dataTopic, 0, false, body).Wait()
		}
	}
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func getenvDuration(k string, d time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if p, err := time.ParseDuration(v); err == nil {
			return p
		}
	}
	return d
}
