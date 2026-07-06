# Golden fixtures for calc_production_counters

Each scenario directory contains:

- `input-NN.json` — **captured from live staging Sparkplug traffic** by
  `cmd/capture-fixtures/main.go`. Includes topic, payload_hex, capture
  timestamp. Do NOT hand-edit these.
- `initial_state.json` — **hand-authored**. The starting `State` snapshot
  (counters, modes, parameters) needed to make the input reproducible.
  See `../../decision_tree.go` for the State interface shape.
- `expected.json` — **hand-authored**. The expected `Decision` returned by
  `Calc()` given `input` + `initial_state`. Includes SendDownstream,
  EnrichedMsg keys/values, and the ordered StateUpdates.

## Authoring workflow

1. Run `cmd/capture-fixtures` against staging for 30 min to populate
   `input-NN.json` files across all scenarios.
2. For each scenario directory, pick ONE representative `input-NN.json`
   (the highest capture count usually — most typical shape).
3. Read `../../../../../../docs/adr/reference/designs/phase-3-calc-production-counters-state-machine.md`
   and trace the input through phases 1-11 mentally, filling in the
   `initial_state.json` with plausible prior counters and any needed
   parameters.
4. Write `expected.json` with the message enrichments + state updates
   the JS function would produce. When in doubt, run the same input
   through the actual Node-RED node in a staging debug session and
   copy the outputs verbatim.
5. Commit input + initial_state + expected as one atomic PR unit.

## Scenario catalog (from state machine doc §6)

| ID | Purpose | Captured or hand-crafted? |
|---|---|---|
| 01_processed_increment_happy | Basic Processed count > last | captured |
| 02_consumed_increment_happy | Basic Consumed count > last | captured |
| 03_defective_increment_happy | Basic Defective count > last | captured |
| 04_reset_on_counter_rollback | new < last → reset path | hand-craft (rare in prod) |
| 05_setup_mode_skips | unit_mode=6 SETUP → drop | hand-craft |
| 06_trig_cs_forces_defective | ***TRIG_CS suffix | captured (if any customer uses it) |
| 07_trig_ci_forces_consumed | ***TRIG_CI suffix | captured |
| 08_trig_c_equals_i | ***TRIG_C=I suffix | captured |
| 09_trig_co_full_reconstruction | ***TRIG_CO with prior ___IN_INCR state | captured + hand-crafted state |
| 10_speed_over_3x_machspeed_drops | glitch guard triggers | hand-craft |
| 11_line_first_machine_aggregates_consumed | Parameter30700 CSV first-match | hand-craft (needs full line topology) |
| 12_statespeed_this_variant | ***STATESPEED_THIS suffix | captured |

## Test invocation

Once the port is implemented, `calc_test.go` iterates the scenario
directories and runs each as a golden test. Failures should compare
`expected.json` against actual `Decision` output with diff highlighting.
See `../golden_test.go` (to be authored in port PR) for the harness.

## Why fixtures over pure unit tests

The JS function has 11 phases interacting through shared state. Pure
unit tests would need to mock 20+ State methods per test. Golden
fixtures pin the end-to-end behavior at the boundary the caller sees
(input msg → Decision), making the port refactor-safe: internal
restructuring doesn't invalidate the tests as long as the boundary
holds.

This is the same pattern the Linux kernel's `tools/testing/selftests/`
uses — capture real-world inputs, freeze expected outputs, verify.
