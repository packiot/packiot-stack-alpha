---
title: Node-RED flows
layer: guide
owner_area: frontends
last_verified: 2026-09-29
---
# Node-RED flows

> For the **automation team**. Add Node-RED logic that runs on a client's factory box, and
> connect it to the PLC data. Up: [Customizing a client](index.md)

!!! warning "Which boxes can run it today"
    Node-RED flows run on factory boxes that read their PLCs **with Node-RED** (the generated
    PLC reader). Boxes that read PLCs with the Python reader (for example Bispharma) show the
    **Edge dashboard** instead and can't run flows yet — a Node-RED helper next to the Python
    reader is **coming soon**.

## How your flow gets the data: connection points

The PLC reader on the box has five **connection points**. Your flow plugs into one of them.

| Connection point | Direction | What your flow gets / sends |
|---|---|---|
| **PLC reads (raw)** | Receive | Every raw read from the PLCs |
| **Normalized tags** | Receive | The values sent to Packiot: `{ endpoint, scan_ts, tags: [{ metric, value, ts }] }` (the secret key is removed) |
| **Agent response** | Receive | Packiot's answer to every send |
| **Agent errors** | Receive | Only the answers that are errors |
| **Publish extra tags** | Send | You send `{ "<full machine topic>/…": number }` and it goes to Packiot like a PLC value |

**Receive** points give your flow a **copy**. If your flow is slow or broken, the PLC data
still reaches Packiot.

## Step by step

1. Build or copy the flow in any Node-RED and **Export** it (JSON).
2. **Customize → Node-RED flows → Insert a flow**: paste it. The page shows what it contains
   and checks it:
    - no network calls inside a **function** node — use an **http request** node;
    - a function has at most 200 lines;
    - no `eval`.
3. **Insert as a copy** if the page says ids already exist.
4. **Lands on**: the shared customizations tab, or the flow's own tab.
5. **Connect to the PLC reader**: pick a connection point, then tick the node(s) it feeds
   (Receive) or sends from (Send).
6. **Insert**, then **Save to descriptor**.
7. **Preview changes** shows what will be added, changed and removed on the box.
   **Apply to box** installs it; only changed nodes restart.

The box refuses the apply, and tells you why, if: the box changed since your preview (preview
again), a node type isn't installed on the box (it would stop **all** flows, including the
PLC reader), or the box doesn't run the generated reader.

## Worked example: alert when Packiot rejects data

Paste this, choose **Lands on: its own tab (Ingest alerts)**, **Receive: Agent errors**, and
tick **shape alert**. Replace the webhook address.

```json
[
  {"id":"alert_tab","type":"tab","label":"Ingest alerts"},
  {"id":"alert_shape","type":"function","z":"alert_tab","name":"shape alert",
   "func":"msg.payload = { text: `Agent rejected a batch: HTTP ${msg.statusCode}`, detail: msg.payload };\nmsg.headers = { 'content-type': 'application/json' };\nreturn msg;",
   "outputs":1,"wires":[["alert_limit"]]},
  {"id":"alert_limit","type":"delay","z":"alert_tab","name":"max 1 per 5 min",
   "pauseType":"rate","rate":"1","nbRateUnits":"5","rateUnits":"minute","drop":true,
   "outputs":1,"wires":[["alert_post"]]},
  {"id":"alert_post","type":"http request","z":"alert_tab","name":"POST to webhook",
   "method":"POST","ret":"txt","url":"https://hooks.example.com/REPLACE_ME","wires":[["alert_log"]]},
  {"id":"alert_log","type":"debug","z":"alert_tab","name":"webhook reply","wires":[]}
]
```

The **delay** node sends at most one alert every 5 minutes, even if every batch fails.

## Editing on the box directly

**Live editor on the box** opens the box's own Node-RED. Changes made there are **not saved
in Packiot**. The next **Preview changes** lists them, and you can press **Keep them: adopt
into the descriptor** so they are not lost.
