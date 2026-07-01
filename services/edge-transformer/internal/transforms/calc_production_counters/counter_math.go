// TRIG suffix corrections + speed + threshold + status helpers.

package calc_production_counters

import (
	"strings"
)

// applyTrigCorrections implements Phase 4 — the ***TRIG_* suffix corrections.
// Ordering matters: the JS's `count_zeros` gate makes TRIG_CS and TRIG_CI
// exclusive (only one fires per message even if both suffixes present, which
// they shouldn't be — but defensive).
//
// Reads ___IN_INCR / ___IN_SCRAP from state for TRIG_CO reconstruction.
// Writes to those keys are appended to Decision.StateUpdates by the caller
// (this function is pure with respect to writes; it returns new counter
// values only).
//
// NOTE: TRIG_CO's ___IN_INCR/___IN_SCRAP state writes are handled inline in
// Phase 5 (persist) — TrigCO reconstruction returns new counter values but
// the writes flow through the normal persist path in the main Calc body.
func applyTrigCorrections(
	curProcessed, curConsumed, curDefective int64,
	prevProcessed, prevConsumed, prevDefective int64,
	flags TriggerFlags,
	state State,
	baseTopic, topicConsumed, topicDefective string,
) (int64, int64, int64) {
	countZeros := 0

	// JS: `ProdDefectiveCount = isNaN(ProdDefectiveCount) ? 0 : ProdDefectiveCount`
	// — but int64 can't be NaN so this is a no-op in Go. Keep the check to
	// document intent.

	// Scrap = Infeed - Outfeed  (TRIG_CS)
	if curDefective <= 0 || flags.TrigCS {
		curDefective = curConsumed - curProcessed
		countZeros++
	}

	// Infeed = Outfeed + Scrap  (TRIG_CI) — exclusive with TRIG_CS via countZeros.
	if (curConsumed <= 0 && countZeros < 1) || flags.TrigCI {
		curConsumed = curProcessed + curDefective
		countZeros++
	}

	// Infeed = Outfeed  (TRIG_C=I) — mirrors.
	if flags.TrigCEqualsI {
		curConsumed = curProcessed
		prevConsumed = prevProcessed
		curDefective = 0
	}

	// Outfeed = Infeed  (TRIG_C=O)
	if flags.TrigCEqualsO {
		curProcessed = curConsumed
		prevProcessed = prevConsumed
		curDefective = 0
	}

	// TRIG_CO — complex reconstruction (JS lines 261-278).
	if flags.TrigCO {
		inIncrKey := topicConsumed + "___IN_INCR"
		inScrapKey := topicDefective + "___IN_SCRAP"

		inIncr, _ := state.Int(inIncrKey)
		inScrap, _ := state.Int(inScrapKey)

		// JS: `if (global.get(...___IN_INCR) == "0")` — a string comparison
		// in the JS. In Go: check int64 == 0.
		if inIncr == 0 {
			curProcessed = curConsumed - 2*curDefective - inScrap + prevDefective
		}

		// Update ___IN_INCR (Consumed increment, clamped ≥0).
		newInIncr := curConsumed - prevConsumed
		if newInIncr < 0 {
			newInIncr = 0
		}
		// Update ___IN_SCRAP (Defective increment, clamped ≥0).
		newInScrap := curDefective - prevDefective
		if newInScrap < 0 {
			newInScrap = 0
		}
		// Persist these — caller doesn't need to know about them.
		_ = state.SetInt(inIncrKey, newInIncr)
		_ = state.SetInt(inScrapKey, newInScrap)

		// JS: if both Processed and Defective look unchanged, treat this as
		// an incoming-only tick and bump Processed by the Consumed delta.
		if curProcessed == prevProcessed && curDefective == prevDefective {
			curProcessed = curProcessed + curConsumed - prevConsumed
		}
	}

	// countZeros is used only for the exclusion above — no return.
	_ = countZeros
	_ = baseTopic
	_ = prevDefective
	return curProcessed, curConsumed, curDefective
}

// computeSpeed implements Phase 6 — ProdSpeed calculation.
// Two paths:
//
//	A) External-speed override: Parameter*30761*=true → read Status/CurMachSpeed.
//	B) Derived: (consIncr / (now - lastTS)) * 60000  → parts per minute.
//
// Writes CurMachSpeed timestamp + value for the next iteration.
func computeSpeed(state State, unitTopic string, timestampMs, consIncr int64, dec *Decision) float64 {
	externalKey := unitTopic + "/Status/Parameter*30761*"
	if external, _ := state.Bool(externalKey); external {
		curSpeedKey := unitTopic + "/Status/CurMachSpeed"
		v, _ := state.Float(curSpeedKey)
		return v
	}

	if consIncr <= 0 {
		return 0
	}

	tsKey := unitTopic + "/Status/CurMachSpeed___TS"
	lastTs, _ := state.TimeMs(tsKey)

	// First observation — no delta possible yet; persist timestamp and return 0.
	if lastTs == 0 {
		tsKeyCopy := tsKey
		timestampMsCopy := timestampMs
		dec.StateUpdates = append(dec.StateUpdates, StateMutation{
			Kind: "speed.ts_first", Key: tsKeyCopy, TimeMs: timestampMsCopy,
			Setter: func(s State) error { return s.SetTimeMs(tsKeyCopy, timestampMsCopy) },
		})
		return 0
	}

	delta := timestampMs - lastTs
	if delta <= 0 {
		return 0
	}

	// JS: `Math.round(ProdConsumedIncremet / (timestamp - ts_speed_before) * 60000)`
	// The multiplication happens before division numerically in the JS due to
	// operator precedence — but the final round is on the whole expression.
	// We preserve: (consIncr * 60000) / delta rounded to nearest int, then float.
	speedInt := (consIncr*60000 + delta/2) / delta // integer round-half-up
	speed := float64(speedInt)

	// Persist new timestamp for next iteration.
	tsKeyCopy := tsKey
	timestampMsCopy := timestampMs
	dec.StateUpdates = append(dec.StateUpdates, StateMutation{
		Kind: "speed.ts", Key: tsKeyCopy, TimeMs: timestampMsCopy,
		Setter: func(s State) error { return s.SetTimeMs(tsKeyCopy, timestampMsCopy) },
	})

	// Also persist CurMachSpeed for external readers.
	curSpeedKey := unitTopic + "/Status/CurMachSpeed"
	speedCopy := speed
	dec.StateUpdates = append(dec.StateUpdates, StateMutation{
		Kind: "speed.value", Key: curSpeedKey, FloatValue: speedCopy,
		Setter: func(s State) error { return s.SetFloat(curSpeedKey, speedCopy) },
	})

	return speed
}

// rollingAvgThreshold implements Phase 7's threshold_mode=4 branch —
// (delta counter) / (delta time). Reads the last-crossing state written
// during Phase 8's threshold check.
func rollingAvgThreshold(state State, unitTopic string, curConsumed, timestampMs int64) float64 {
	// JS uses `topic_threshold_mode` (the topic itself) as the base for
	// the state keys. Simplification: use unitTopic-prefixed keys.
	lastTsKey := unitTopic + "/Status/_6_Consumed_last_TS"
	lastCounterKey := unitTopic + "/Status/_6_Consumed_last_counter_value"

	lastTs, _ := state.TimeMs(lastTsKey)
	lastCounter, _ := state.Int(lastCounterKey)

	if timestampMs == lastTs {
		return 0
	}
	delta := timestampMs - lastTs
	if delta == 0 {
		return 0
	}
	return float64(curConsumed-lastCounter) / float64(delta)
}

// statusMetricFor builds the Status/StateCurrent metric emitted in Phase 10.
// The status_topic_name is the counter topic that crossed the threshold;
// we swap the metric-name segment ("Admin/Prod*Count/N/Unit") for
// "Status/StateCurrent".
func statusMetricFor(statusTopicName string, statusCode int, timestampMs int64, msg Message) Metric {
	parts := strings.Split(statusTopicName, "/")
	if len(parts) >= 6 {
		// Segments 0..4 = enterprise/site/area/line/unit; replace segment 5+.
		parts = parts[:5]
		parts = append(parts, "Status", "StateCurrent")
	}
	statusName := strings.Join(parts, "/")
	return Metric{
		Name:      statusName,
		Timestamp: timestampMs,
		Value:     int64(statusCode),
		Type:      "int32",
		Counter:   int64(statusCode),
		Timezone:  msg.SparkPlugTimezone,
		Extra:     msg.SparkPlugAddMetrics,
	}
}

// registerStatusTopic appends the status topic to ___STATUS_TOPICS for
// downstream timer re-evaluation. Idempotent — no double-register.
func registerStatusTopic(state State, statusTopic string, dec *Decision) {
	const key = "___STATUS_TOPICS"
	list, _ := state.Strings(key)
	for _, t := range list {
		if t == statusTopic {
			return // already present
		}
	}
	newList := append([]string{}, list...)
	newList = append(newList, statusTopic)
	newListCopy := newList
	dec.StateUpdates = append(dec.StateUpdates, StateMutation{
		Kind: "status.topics", Key: key, StringsValue: newListCopy,
		Setter: func(s State) error { return s.SetStrings(key, newListCopy) },
	})
}
