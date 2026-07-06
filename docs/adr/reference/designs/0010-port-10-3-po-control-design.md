# Port 10.3 design — PO control (30800-899) + 30700 line-order unit

Verbatim node capture: `0010-port-10-3-po-control-capture.txt`
(4 nodes: Prep 30700-30701 [36L], Prep 30800-30899 [361L],
Build packml Config 30700 [61L], Build PO Commands [190L]).

## Parameter inventory (what each does)

| Param | Action | Writes |
|---|---|---|
| 30700 | line order config | SELECT first/last unit → packml_register line_unit_seq + EV topology rows (id_equipment_line_connected, position_in_equipment_line) + historical infeed/outfeed zeroing |
| 30701 | ideal speed | ✅ ALREADY PORTED (po_parameter.go) |
| 30800/30802 | start/resume PO | 6-stmt tx: close open runtime range → new runtime row → prior running PO → prev_status(3/4)+ts_end → target PO status 2 (+notes, ts_start; UNIQUE-on-running juggle via temp status 4) → EV PO-marker row (tp=3) → re-stamp later EV rows. If a PO was already running: RE-DISPATCH as 30801/30803 to close it first |
| 30801/30803 | end/pause PO | close runtime range, PO → 3/4 + ts_end, EV marker |
| 30805 | create PO | product_families/products/clients upserts (CTE chain) → SELECT ids → PO insert |
| 30810 | justify downtime | UPDATE equipment_events (category/planned/change_over/idle...) + user_logs entry |
| 30811/30812 | manual event create/update | equipment_events_man insert-if-not-exists / update + user_logs |
| 30813+ | trim event first part | UPDATE equipment_events ts ranges |
| 30850 | analogs | ✅ ALREADY PORTED (#230) |
| 30861+ | setup counters | UPDATE uns_equipment_current_job setup times |

## Key insight: shadow-mirror is this port's twin

shadow-mirror's handlers (order-created-started, order-stopped,
manual-event-created, event-justified...) implement the SAME business
actions keyed by user_logs replay. 10.3 is the LIVE-ingest twin keyed
by Sparkplug params. On the consolidated stack BOTH entry points
exist (factory buttons vs operator UI). The Go port should share
command builders with shadow-mirror's handlers where shapes align —
one business-action library, two entry points.

## Architecture for the port

- `oeecloud-worker/internal/pocontrol/`: dispatcher keyed by param id;
  each handler = (SELECT-decide) pure decision fn + command tx builder.
  Decision fns take the SELECT rows as input → testable without DB.
- SELECT-then-decide MUST be one pgx.Tx with the commands (nodered did
  two round-trips through separate nodes — a race window we do NOT
  port; same-tx is strictly better and output-identical).
- Re-dispatch (start-over-running → synthesize end) = in-process loop,
  not message re-queue.
- Flag: PO_CONTROL_ENABLED=false until synthetic-inject verified.

## Verification strategy (staging has NO live 30800 traffic)

CPACK's edge sends 30800s to PROD's pipeline; staging's copies arrive
via shadow-mirror replay. So: synthetic Sparkplug injects through
Mosquitto (session-72 pattern) per parameter, asserting the exact row
states; then diff against shadow-mirror's replay effects for the same
logical action (twin-consistency check).

## Sequencing

1. Slice 1: 30800/30802 + 30801/30803 (the lifecycle core)
2. Slice 2: 30700 topology unit (includes 10.2's zeroing writes)
3. Slice 3: 30805 create-PO (product/client upsert chain)
4. Slice 4: 30810-30813 event justify family (align with
   shadow-mirror handler shapes)
5. Slice 5: 30861+ setup counters (needs uns_equipment_current_job —
   P3c dependency)
