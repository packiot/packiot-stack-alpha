# CPACK edge — the 08-13 S7 "wedge" incident + self-recovery

**Date pinned:** 2026-08-21 (root-caused live on the factory box `packiot@10.135.1.173`).
**Impact window:** 2026-08-13 ~19:15–20:12 onward — ~8 days.
**Affected:** production lines **L8, L10, CELULA** (Flexo + Sleeves) — no OEE in real prod OR the staging twin. L3/L4/L5/L6 unaffected.

## Symptom
csadmin topology tree / OEE showed L8/L10/CELULA offline; `equipment_values` (F3) for those lines **frozen at exactly 2026-08-13**. All other lines live.

## Diagnostic chain (what ruled out what)
1. csadmin reads are faithful (green = data in last 5 min) — not a UI/read bug.
2. Whole staging path healthy: agent maps+births the tags, decoder registers aliases + decodes, `packml_register` fully resolves the topics. Not the cloud side.
3. Narrowed to **upstream of the agent's SparkPlug publish**: the factory Node-RED tee POSTs raw tags to staging over HTTP (`got` UA from the factory public IP); it was simply not sending L8/L10/CELULA.
4. On the factory box there are TWO node-reds — the **new SparkPlug reader is the container `edge-cpack-nodered` on `:1880`** (the host `:1881` process is LEGACY; use only as an adversarial cross-check). On the CORRECT `:1880` instance:
   - flows unchanged since Jul 23 (not a config edit), all lines wired, no nodes disabled.
   - PLCs **ping + TCP:102 reachable** (`10.135.16.26` L8, `.124` L10, `.123` Flexo, `.101` Sleeves).
   - but its log showed `[error] [s7 endpoint:S7 L10] Error: Timeout connecting to the transport` (cyclic).

## Root cause
The Node-RED **`s7 endpoint` connections wedged** — stuck failing the S7/ISO-on-TCP session setup ("timeout connecting to the transport") *above* the open TCP port, and the s7 node's own reconnect logic **never self-recovered**. TCP stays up (PLC Ethernet answers), but no S7 session ⇒ no reads ⇒ the line goes dark until manual intervention. (If it had been PLC-side connection-pool exhaustion by another client, the fix below would NOT have helped — it did, so the wedge was on the reader's side.)

## Fix (proven)
A full Node-RED **flows reload** re-establishes the S7 sessions:
```
curl -s -X POST http://localhost:1880/flows \
  -H 'Node-RED-Deployment-Type: reload' -H 'Content-Type: application/json' --data '{}'
```
Immediately after the reload, the reader processed **all** lines again (L8/L10/CELULA/Sleeves back), zero S7 timeouts. (`equipment_values` then repopulates as each machine actually produces — an idle/off-shift line stays 0 until it runs.)

## Self-recovery (deployed)
`scripts/edge/s7-nodered-watchdog.sh` — runs as user `packiot` (docker group, no root) via a 2-min user cron:
```
*/2 * * * * /home/packiot/bin/s7-nodered-watchdog.sh >/dev/null 2>&1
```
It greps `edge-cpack-nodered` logs for the exact `s7 endpoint … Timeout connecting to the transport` signature over a 6-min window; if present and >12 min since the last reload (cooldown, no reload-loops), it POSTs the flows reload above and logs to syslog (`s7-watchdog`). Reacts ONLY to the wedge signature — it will not fire on normal off-shift idleness.

**Install on a client edge box:**
```
install -m755 scripts/edge/s7-nodered-watchdog.sh ~/bin/s7-nodered-watchdog.sh
( crontab -l 2>/dev/null | grep -v s7-nodered-watchdog; \
  echo '*/2 * * * * /home/USER/bin/s7-nodered-watchdog.sh >/dev/null 2>&1' ) | crontab -
```

## Follow-ups
- **Productize:** move the watchdog into the edge docker bundle as a sidecar (needs docker-socket read or node-red admin polling) so it ships with every client deploy instead of a per-box cron.
- **Upstream:** the real defect is the `node-red-contrib-s7` reconnect not self-healing a wedged transport — worth an issue/patch or a per-endpoint auto-recycle in-flow.
- **Alerting:** page when the watchdog fires (a wedge is a real incident, not just auto-healed noise).
