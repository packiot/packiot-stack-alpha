# CPACK twin re-point (legacy :1881 → new-stack :1880) — Phase-2 COMPLETE ✅

**Date:** 2026-08-25 · **Outcome:** twin **cut over to :1880** and validated live during
active production. Legacy `:1881` blackholed at the cloud edge. Twin OEE lines match the
packiot40 oracle; previously-dark member tiles now flow; prod branch untouched.

## Final live state

- **Reader `:1880`** runs the corrected #907 flow + a **staging-tee** 2nd branch that
  POSTs the rawtag envelope to `https://cpack-ingest.staging.packiot.app:8447/v2/tags`
  (cloud key `pk_cpack_af247745…`). Prod branch (→ local agent → `ssl://ingest.prod:8883`)
  untouched. (`cpack-reader-flow.twin.json`)
- **Cloud `sparkplug-agent-cpack`** runs `cpack-agent.twin.yaml` (330-entry map,
  `packml_topic: CPACK/SC`, internal-mosquitto uplink). **Drops 0.**
- **nginx** `cpack-ingest.staging:8447`: `/v1/tags → return 444` (legacy blackholed);
  `/v2/tags → 172.18.0.38:9104/v1/tags`. (`cpack-ingest.cutover.conf`)

## Validation (live, during production)

| Line | Twin (:1880) gross/net | Oracle gross/net | |
|---|---|---|---|
| L5 (47/60) | 737,806 / 108,935 | 737,816 / 108,944 | ✓ exact |
| L6 (50/90) | 291,920,192 / 266,162,960 | 291,920,229 / 266,162,982 | ✓ exact |
| L3 (48/75) | idle | idle | ✓ both idle |

- **L5 net IMPROVED**: under legacy the twin showed net 246,774 vs oracle 106,128 (wrong);
  under :1880 it's 108,935 vs oracle 108,944 (correct) — the twin-map topic resolution
  fixed a net miscompute.
- **Member gains** (previously dark on legacy, now flowing): **L8/DXL**, L4 members,
  L10 members, and even **CELULA/CER400**. 26 distinct equipments writing; drops 0.
- Prod uplink stayed connected throughout (outbox 0).

## Root cause of the two earlier failed cut attempts (the key lesson)

The agent builds each published SparkPlug topic as **`packml_topic` + the INCOMING metric
suffix** (NOT the map's `metric_suffix`). The two readers emit different suffixes:

| reader | emits | needs packml_topic | published topic |
|---|---|---|---|
| legacy :1881 | `/L5/…` | `CPACK/SC/LINHAS` | `CPACK/SC/LINHAS/L5/…` ✓ |
| new :1880 | `/LINHAS/L5/…` | `CPACK/SC` | `CPACK/SC/LINHAS/L5/…` ✓ |

The old map (`packml_topic: CPACK/SC/LINHAS`) turns :1880's `/LINHAS/L5/…` into
`CPACK/SC/LINHAS/**LINHAS**/L5/…` (double LINHAS) → the decoder/packml_register can't
resolve it → **agent 202-accepts but nothing reaches F3** (this is why the first two cuts
looked like ":1880 accepted but no F3 writes", even during active production).

**Consequence for sequencing:** the twin map (`packml_topic: CPACK/SC`) is correct for
:1880 but breaks legacy (legacy's `/L5/…` → `CPACK/SC/L5/…`, missing `/LINHAS`). The two
maps are **mutually exclusive**, so the twin map must be deployed **together with the
`/v1` cut** — NOT before it (a "deploy new map, then cut later" sequence regresses legacy
during the overlap; observed + reverted). The winning sequence:
1. nginx `/v2` add + reader tee on (both readers coexist, old map).
2. **Atomically**: install `cpack-agent.twin.yaml` + restart agent + flip `/v1 → 444`.
3. Verify :1880 → F3 (drops 0, lines match oracle).

## Still open (SEPARATE from the cutover — downstream OEE config)

L4/L8/L10 **lines** (49/51/52) still don't compute their line-level rollup even though
members flow — an ent-3 OEE line-config / count-index→id resolution gap (net values
cross-wire vs oracle). This was 0/broken on legacy too, so it is **not a cutover
regression** — it needs its own fix (lead_machine / infeed-outfeed linkage +
packml_register count-index resolution for L4/L8/L10).

## Armed revert (still available on the box)

- nginx: `/etc/nginx/conf.d/cpack-ingest.conf.bak.step1.*` (pre-cutover) — restore +
  `nginx -s reload` puts the twin back on legacy in one reload.
- cloud map: `…/docs/clients/cpack-agent.yaml.bak.pretwin.*` (old 102-entry legacy map).
- reader flow: `~/flows.json.bak.1787667400` (original dup-id flow) on the factory box.

## Files in this PR

- `cpack-agent.twin.yaml` — the deployed cloud-twin map (330 entries, `packml_topic:
  CPACK/SC`, internal-mosquitto uplink).
- `cpack-ingest.cutover.conf` — the applied nginx cutover config.
- `cpack-reader-flow.twin.json` — the deployed reader flow (corrected #907 + staging-tee).
- `cpack-staging-tee-node.json` — the tee node in isolation.
