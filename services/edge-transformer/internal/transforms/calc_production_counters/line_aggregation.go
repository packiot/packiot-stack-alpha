// Phase 9 — Line/sector aggregation. Ported from source.js lines ~605-800.
//
// When a unit is part of a LINE (Parameter30700 CSV lists machine indices
// that participate), and the unit's machine index is the "first" or
// "last" in the CSV, its counter tick contributes to LINE-level metrics:
//
//   - First-in-CSV → emits LINE ProdConsumedCount metric, bumps
//     line-level Defective counter by +ConsumedIncrement.
//   - Last-in-CSV  → emits LINE ProdProcessedCount metric, decrements
//     line-level Defective counter by ProcessedIncrement.
//   - When either fires AND >20 ms has passed since the last line
//     Defective emission, also emits LINE ProdDefectiveCount = (line
//     Defective - previous line Defective).
//
// If the unit's Line topic segment (topicArray[3]) contains "::" (the
// "SECTOR::LINE" naming convention), the aggregation runs TWICE — once
// for the sector-line topic ("SECTOR::LINE"), once for the parent line
// topic ("LINE") that comes after the "::" strip. Both writes are
// independent and target different Parameter30700 CSVs.
//
// This phase is HIGH RISK per state-machine doc §7. The topology-string
// juggling + off-by-one at the CSV boundaries is where a naive port
// silently emits wrong LINE totals.

package calc_production_counters

import (
	"strings"
)

// runPhase9LineAggregation appends LINE-level metrics to dec.Metrics and
// records state mutations for line-level Defective accumulators. Called
// after Phase 8 completes for a message.
//
// Preserves the JS's j=0/1 double-pass for "SECTOR::LINE" units. See
// source.js lines 631-663.
func runPhase9LineAggregation(
	dec *Decision,
	state State,
	msg Message,
	unitTopic string,
	timestampMs int64,
	procIncr, consIncr int64,
	curProcessed, curConsumed int64,
	prodConsumedSet, prodProcessedSet bool,
	prodSpeed float64,
	stateSpeedThis bool,
	resetLineScrap bool,
) {
	// Split the topic to work with the same string indices as JS.
	// topicArray[0..4] = Enterprise/Site/Area/Line/Unit
	// topicArray[7]    = machine index in the counter path
	baseTopic := stripTriggerSuffix(msg.Topic)
	topicArray := strings.Split(baseTopic, "/")
	if len(topicArray) < 8 {
		// Can't derive machine index → skip Phase 9.
		return
	}
	machineIdx := topicArray[7]
	enterprise, site, area, linePart := topicArray[0], topicArray[1], topicArray[2], topicArray[3]

	// Determine the two topic candidates to check.
	// j=0: use the actual line segment as-is (may be "SECTOR::LINE" or plain "LINE")
	// j=1: only if linePart contains "::", also try the "LINE" part (after ::).
	candidates := []string{linePart}
	if idx := strings.Index(linePart, "::"); idx >= 0 {
		candidates = append(candidates, linePart[idx+2:])
	}

	for _, topicLine := range candidates {
		p30700Key := enterprise + "/" + site + "/" + area + "/" + topicLine + "/Status/Parameter30700"
		csvVal, ok := state.Strings(p30700Key)
		if !ok || len(csvVal) == 0 {
			// Parameter30700 not set for this line — skip.
			continue
		}
		firstMachine := csvVal[0]
		lastMachine := csvVal[len(csvVal)-1]

		enterpriseToLine := enterprise + "/" + site + "/" + area + "/" + topicLine

		// Line-level ProdDefectiveCount reset (Phase 2 reset branch propagation).
		if resetLineScrap {
			lineDefKey := enterpriseToLine + "/Admin/ProdDefectiveCount"
			lineDefPrevKey := enterpriseToLine + "/Admin/ProdDefectiveCount___PREVIOUS"
			appendResetMutation(dec, lineDefKey, "line.defective.reset")
			appendResetMutation(dec, lineDefPrevKey, "line.defective.previous.reset")
		}

		var scrapLineNet int64
		var scrapLineGross int64

		// First-machine: contribute to LINE Consumed + bump Defective counter.
		if prodConsumedSet && machineIdx == firstMachine {
			metric := Metric{
				Timestamp: timestampMs,
				Name:      enterpriseToLine + "/Admin/ProdConsumedCount",
				Value:     consIncr,
				Type:      "int32",
				Counter:   curConsumed,
				Timezone:  msg.SparkPlugTimezone,
				Extra:     msg.SparkPlugAddMetrics,
			}
			if !stateSpeedThis {
				metric.CurSpeed = round1(prodSpeed)
			}
			dec.Metrics = append(dec.Metrics, metric)

			// Read current line-Defective, add ConsumedIncr, write back.
			lineDefKey := enterpriseToLine + "/Admin/ProdDefectiveCount"
			curDef, _ := state.Int(lineDefKey)
			newDef := curDef + consIncr
			appendIntMutation(dec, lineDefKey, newDef, "line.defective.add_consumed")

			scrapLineGross = consIncr
		}

		// Last-machine: contribute to LINE Processed + decrement Defective counter.
		if prodProcessedSet && machineIdx == lastMachine {
			metric := Metric{
				Timestamp: timestampMs,
				Name:      enterpriseToLine + "/Admin/ProdProcessedCount",
				Value:     procIncr,
				Type:      "int32",
				Counter:   curProcessed,
				Timezone:  msg.SparkPlugTimezone,
				Extra:     msg.SparkPlugAddMetrics,
			}
			dec.Metrics = append(dec.Metrics, metric)

			lineDefKey := enterpriseToLine + "/Admin/ProdDefectiveCount"
			curDef, _ := state.Int(lineDefKey)
			newDef := curDef - procIncr
			appendIntMutation(dec, lineDefKey, newDef, "line.defective.sub_processed")

			scrapLineNet = -procIncr
		}

		// Debounced line-Defective emission: fires when either scrap side moved
		// AND >20 ms elapsed since the last line-Defective emission.
		// NOTE: preserving JS's literal "20" (millis) — likely a bug but
		// behavior-parity comes first. See state-machine doc §4.3.
		if scrapLineNet != 0 || scrapLineGross != 0 {
			lineDefTsKey := enterpriseToLine + "/Admin/ProdDefectiveCount___TS"
			lineDefTs, tsSet := state.TimeMs(lineDefTsKey)
			if !tsSet {
				// First observation — seed the timestamp for the next tick.
				appendTimeMsMutation(dec, lineDefTsKey, timestampMs, "line.defective.ts_first")
				continue
			}
			if lineDefTs+20 > timestampMs {
				continue
			}

			lineDefKey := enterpriseToLine + "/Admin/ProdDefectiveCount"
			lineDefPrevKey := enterpriseToLine + "/Admin/ProdDefectiveCount___PREVIOUS"

			curDef, _ := state.Int(lineDefKey)
			prevDef, _ := state.Int(lineDefPrevKey)

			// Persist current as previous, then update timestamp.
			appendIntMutation(dec, lineDefPrevKey, curDef, "line.defective.previous")
			appendTimeMsMutation(dec, lineDefTsKey, timestampMs, "line.defective.ts")

			metric := Metric{
				Timestamp: timestampMs,
				Name:      lineDefKey,
				Value:     curDef - prevDef,
				Type:      "int32",
				Counter:   curDef,
				Timezone:  msg.SparkPlugTimezone,
				Extra:     msg.SparkPlugAddMetrics,
			}
			dec.Metrics = append(dec.Metrics, metric)
		}
	}
}

// appendIntMutation records a State.SetInt mutation on the Decision.
func appendIntMutation(dec *Decision, key string, v int64, kind string) {
	keyC, vC := key, v
	dec.StateUpdates = append(dec.StateUpdates, StateMutation{
		Kind: kind, Key: keyC, IntValue: vC,
		Setter: func(s State) error { return s.SetInt(keyC, vC) },
	})
}

// appendTimeMsMutation records a State.SetTimeMs mutation.
func appendTimeMsMutation(dec *Decision, key string, v int64, kind string) {
	keyC, vC := key, v
	dec.StateUpdates = append(dec.StateUpdates, StateMutation{
		Kind: kind, Key: keyC, TimeMs: vC,
		Setter: func(s State) error { return s.SetTimeMs(keyC, vC) },
	})
}

// appendResetMutation records a SetInt(0) reset mutation.
func appendResetMutation(dec *Decision, key, kind string) {
	keyC := key
	dec.StateUpdates = append(dec.StateUpdates, StateMutation{
		Kind: kind, Key: keyC, IntValue: 0,
		Setter: func(s State) error { return s.SetInt(keyC, 0) },
	})
}
