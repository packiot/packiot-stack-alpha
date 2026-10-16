# Demo aids

## `po-replayer.sh` — rotate production orders so a demo/staging tenant looks alive

Keeps a fresh PO running on each configured line (`create-and-start → run → finish → next`)
so the **Orders view shows live production flowing** during a demo, without a human driving
the PO lifecycle by hand.

This is a **demonstration/rehearsal aid, not a client workflow** — real clients create real
POs from the Orders UI. For line-metered tenants (e.g. Bispharma `ent5`) the POs carry real
production only once the per-PO line-counter attribution fix (PR #1387) is deployed; before
that, line-POs capture `gross=net=0` (see
`docs/clients/bispharma-per-po-line-counter-reconciliation.md`).

### Run

```bash
# resolve each line's site/area once:
#   SELECT id_equipment, id_site, id_area FROM core.equipments
#    WHERE tp_equipment = 3 AND id_enterprise = 5;
export EDGE_API_KEY="…"        # do NOT hardcode — fetch from your secret store / DB
export LINES="2000224:2000009:2000020 2000226:2000009:2000020"

./po-replayer.sh               # loop: keep every line carrying a fresh PO, rotate at CYCLE_SECONDS
./po-replayer.sh --once        # one PO per line, run one cycle, finish, exit
./po-replayer.sh --cleanup     # finish every running DEMO PO on the configured lines, exit
./po-replayer.sh --dry-run     # print the calls it would make (no mutation)
```

### Knobs (env)

| var | default | meaning |
|-----|---------|---------|
| `API_BASE` | `http://127.0.0.1:8080` | edge-api base (run on the app box, or tunnel) |
| `ID_ENTERPRISE` | `5` | tenant |
| `CYCLE_SECONDS` | `600` | how long each PO runs before it's finished + rotated |
| `POLL_SECONDS` | `30` | loop cadence |
| `PO_QUANTITY` | `50000` | order target quantity |
| `ID_ORDER_BASE` | `990000000` | reserved `idOrder` band for demo POs |
| `LINES` | *(required)* | `idEquipment:idSite:idArea` triples, whitespace-separated |

### Safety

- Mutates a **live tenant** via edge-api — only run against an environment you're authorized to.
- Every PO is named `DEMO-<line>-<idOrder>` with `idOrder` in the reserved band, so `--cleanup`
  can find and finish them.
- On `Ctrl-C`/`SIGTERM` it finishes the POs it opened — never leaves a line stuck running.
- The API key is only read from `EDGE_API_KEY`; it is never written to disk or logged.
