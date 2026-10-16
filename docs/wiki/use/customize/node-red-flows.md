---
title: Node-RED flows
layer: guide
owner_area: frontends
last_verified: 2026-10-13
---
# Node-RED flows

> For the **automation team**. Add Node-RED logic that runs on a client's factory box, and
> connect it to the PLC data. Up: [Customizing a client](index.md)

## Which boxes can run flows

| The factory box reads its PLCs with… | Flows? |
|---|---|
| **Node-RED** (the PLC reader Packiot generates) | Yes, with all five connection points below |
| the **Python reader** (for example Bispharma) | Yes, after you turn on the **Node-RED helper**. The helper gets only **Normalized tags** and **Publish extra tags** |

**Turning on the Node-RED helper:** on **Node-RED flows**, the card **Live editor on the
box** says "This box reads its PLCs with the Python reader". Press **Turn on the Node-RED
helper**, then in CS Admin run **Onboarding → Install on the factory box** again. That adds
Node-RED next to the PLC reader. The helper gets a **copy** of every batch the reader sends;
if the helper breaks, the reader and the data are not affected.

## How your flow gets the data: connection points

The PLC reader on the box has five **connection points**. Your flow plugs into one of them.

| Connection point | Direction | What your flow gets / sends |
|---|---|---|
| **PLC reads (raw)** | Receive | Every raw read from the PLCs |
| **Normalized tags** | Receive | The values sent to Packiot: `{ endpoint, scan_ts, tags: [{ metric, value, ts }] }` (the box's key is removed; on a helper box there is also `group`) |
| **Agent response** | Receive | Packiot's answer to every send |
| **Agent errors** | Receive | Only the answers that are errors |
| **Publish extra tags** | Send | You send `{ "<full machine topic>/…": number }` and it goes to Packiot like a PLC value |

**Receive** points give your flow a **copy**. If your flow is slow or broken, the PLC data
still reaches Packiot.

On a **helper** box, values you send with **Publish extra tags** are not kept while the box
has no internet; they are lost, not sent later. (The PLC values themselves are kept and
sent later, as usual.)

## Step by step

1. Build or copy the flow in any Node-RED and **Export** it (JSON).
2. **Node-RED flows → Insert a flow**: paste it. Under **What you pasted** the page shows what
   it contains and checks it. It refuses:
    - a network call inside a **function** node (use an **http request** node instead);
    - a function with more than 200 lines;
    - `eval`, `new Function` or `vm`.
3. Tick **Insert as a copy** if the page says ids already exist (it gives the nodes new ids).
4. **Lands on**: **The customizations tab (shared)**, or **Its own tab** if your paste has a
   tab.
5. **Connect to the PLC reader**: pick a connection point (**Receive: …** or **Send: …**),
   or **Not connected (standalone)**. Then tick the node(s) it feeds (**Feed these nodes with
   it**) or sends from (**Send from these nodes' first output**).
6. **Insert**, then **Save to descriptor**. Saving never changes the client's setup status.
7. In **Apply to the running box**, keep **Customizations only (reader untouched)** and press
   **Preview changes**. You see what will be added, updated and removed on the box.
   **Apply to box** installs it; only changed nodes restart.

The **Apply to the running box** card appears only when the box runs Node-RED (with the
generated reader or the helper). The box refuses the apply, and tells you why, if: the box
changed since your preview (preview again), or a node type isn't installed on the box (it
would stop **all** flows, including the PLC reader; ask the platform team to add it).

**If someone else saved first**, Save says so. Reloading the page **loses** your unsaved
nodes, so first copy them with **Edit JSON** (in **Customizations on the descriptor**), then
reload and paste them again.

## Worked example: alert when Packiot rejects data

Paste this, choose **Lands on: Its own tab (Ingest alerts)**, **Receive: Agent errors**, and
tick **shape alert**. Replace the webhook address. (This needs a box with the generated
Node-RED reader; a helper box has no **Agent errors** point.)

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

In **Live editor on the box**, **Open Node-RED view** opens the box's own Node-RED inside the
page. Changes made there are **not saved in Packiot**. The next **Preview changes** lists
them, and you can press **Keep them: adopt into the descriptor**, then **Save to descriptor**
and preview again, so they are not lost.

If the card says "No reachable box", the box is not connected; check it in CS Admin →
**Factory box & PLC → Factory box**.
