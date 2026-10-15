// render-box-instance.mts — the PRODUCTION reader bundle for a factory box that already runs the STAGING bundle
// (Bispharma go-live, docs/runbooks/go-live-bispharma.md §5). Two independent readers on one VM.
//
//   node --experimental-strip-types scripts/promotion/bispharma/render-box-instance.mts \
//     --edge-api <edge-api checkout> --descriptor descriptor.json --helper-flow reader_flow.json --out <dir> \
//     [--instance prod] [--ingest-url https://ingest.prod.packiot.app:8449/v1/tags] [--helper-port 1890] [--poll 5]
//
// WHY: edge-api's generator (src/usecases/edge-ssm/shared/reader-bundle.ts, ADR-0049) renders ONE instance per box: fixed
// container names (packiot-edge-reader, packiot-nodered-helper), the helper on 127.0.0.1:1880, and — for an on-prem
// (fat-edge) tenant like Bispharma — a best-effort tee to the box's local agent on 127.0.0.1:9104. A second, production
// instance rendered as-is would (a) collide on both container names, so `docker compose up` fails, or, deployed into the
// staging directory, REPLACE the staging reader; (b) tee its batches into the STAGING helper and the STAGING fat-edge
// agent. Prod edge-api has no SSM box access (decision B6), so the go-live installs this bundle by hand over SSM.
//
// This script calls the generator UNCHANGED (same descriptor, same code as the box's staging bundle), then applies one
// explicit, asserted instance overlay:
//   - compose project `packiot-<instance>` (top-level `name:`), container names suffixed `-<instance>`;
//   - the helper published on 127.0.0.1:<helper-port> and the reader's helper tee pointed there;
//   - the local fat-edge tee REMOVED: the staging instance keeps the box's outage dashboard; a second fat-edge is a
//     follow-up when staging's box instance is retired;
//   - .env without AGENT_INGEST_API_KEY (no local tee) and with INGEST_KEY=__SET_ME__ (set on the box, never echoed).
// Durable follow-up: the same as generator options in edge-api (instance suffix + helper port), so a prod edge-api with
// SSM access renders it natively.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { gzipSync } from 'node:zlib';

const { values: a } = parseArgs({
  options: {
    'edge-api': { type: 'string' }, descriptor: { type: 'string' }, 'helper-flow': { type: 'string' }, out: { type: 'string' },
    instance: { type: 'string', default: 'prod' }, 'ingest-url': { type: 'string', default: 'https://ingest.prod.packiot.app:8449/v1/tags' },
    'helper-port': { type: 'string', default: '1890' }, poll: { type: 'string', default: '5' },
    'reader-image': { type: 'string', default: 'python:3.12-slim' },
  },
});
for (const k of ['edge-api', 'descriptor', 'out']) if (!a[k]) throw new Error(`--${k} is required`);
const inst = a.instance!;
if (!/^[a-z][a-z0-9]{1,15}$/.test(inst)) throw new Error(`--instance must be a short lowercase word, got ${inst}`);
const port = Number(a['helper-port']);
if (!Number.isInteger(port) || port === 1880 || port < 1024) throw new Error('--helper-port must be a free port other than 1880');

const gen = await import(resolve(a['edge-api']!, 'src/usecases/edge-ssm/shared/reader-bundle.ts'));
const descriptor = JSON.parse(readFileSync(a.descriptor!, 'utf8'));
const helperFlow = a['helper-flow'] ? readFileSync(a['helper-flow'], 'utf8') : undefined;
const bundle = gen.generateReaderBundle(descriptor, {
  noderedHelper: descriptor.nodered_helper === true,
  helperFlow,
  ingestUrl: a['ingest-url'],
  group: descriptor.tenant,
  pollIntervalSec: Number(a.poll),
  readerImage: a['reader-image'],
  ingestKey: '',                                  // never rendered: set on the box
  onpremOffline: descriptor.onprem_offline === true,
  agentIngestKey: '',
});
const f: Record<string, string> = { ...bundle.files };

// ── the instance overlay (every substitution must hit exactly the expected number of times) ─────────────────────────
function sub(file: string, from: string, to: string, n = 1) {
  const parts = f[file].split(from);
  if (parts.length - 1 !== n) throw new Error(`${file}: expected ${n}× ${JSON.stringify(from)}, found ${parts.length - 1}`);
  f[file] = parts.join(to);
}
const helper = descriptor.nodered_helper === true;
sub('compose.edge.yml', 'container_name: packiot-edge-reader\n', `container_name: packiot-edge-reader-${inst}\n`);
if (helper) {
  sub('compose.edge.yml', 'container_name: packiot-nodered-helper\n', `container_name: packiot-nodered-helper-${inst}\n`);
  sub('compose.edge.yml', '"127.0.0.1:1880:1880"', `"127.0.0.1:${port}:1880"`);
}
f['compose.edge.yml'] = `# INSTANCE ${inst.toUpperCase()} — rendered by scripts/promotion/bispharma/render-box-instance.mts from edge-api's\n` +
  `# generator; runs NEXT TO the staging bundle in /opt/packiot. Own project, names, helper port; no fat-edge tee.\n` +
  `name: packiot-${inst}\n` + f['compose.edge.yml'];

const cfg = JSON.parse(f['reader.config.json']);
const before = cfg.targets.map((t: { name: string }) => t.name).join(',');
cfg.targets = cfg.targets.filter((t: { name: string }) => t.name !== 'local');
for (const t of cfg.targets) if (t.name === 'nodered') t.url = t.url.replace('127.0.0.1:1880', `127.0.0.1:${port}`);
f['reader.config.json'] = JSON.stringify(cfg, null, 2) + '\n';
f['.env'] = f['.env'].split('\n').filter((l) => !l.startsWith('AGENT_INGEST_API_KEY=')).join('\n');

// ── assertions: nothing of the staging instance's footprint survives ────────────────────────────────────────────────
const all = Object.values(f).join('\n');
for (const bad of ['127.0.0.1:9104', '127.0.0.1:1880/', '"127.0.0.1:1880:', 'container_name: packiot-edge-reader\n', 'container_name: packiot-nodered-helper\n']) {
  if (all.includes(bad)) throw new Error(`instance overlay incomplete: ${bad} still present`);
}
if (cfg.targets[0].name !== 'cloud' || cfg.targets[0].url !== a['ingest-url']) throw new Error('primary target is not the requested ingest URL');

mkdirSync(a.out!, { recursive: true });
for (const [name, body] of Object.entries(f)) writeFileSync(join(a.out!, name), body);

// install.sh / uninstall.sh — what the go-live runs ON THE BOX over SSM (prod edge-api has no box access, B6). Pure text,
// one RunShellScript, like edge-api's own Go-live push. The ingest key is NEVER in the bundle: the CS engineer puts it in
// a root-only file first; install.sh moves it into .env without echoing it. The staging instance is never touched.
const dir = `/opt/packiot-${inst}`;
const b64 = (s: string) => Buffer.from(s, 'utf8').toString('base64');
const install = [
  '#!/bin/sh', `# install.sh — Packiot ${inst.toUpperCase()} reader instance next to the staging one (render-box-instance.mts). Idempotent.`,
  'set -eu', `D=${dir}; K=/root/.packiot-${inst}-ingest-key`,
  '[ "$D" != /opt/packiot ] || { echo "refusing: that is the staging instance dir"; exit 2; }',
  '[ -s "$K" ] || { echo "missing $K (the production ingest key, root-only, one line) — see runbook"; exit 2; }',
  'mkdir -p "$D/spool" && cd "$D"',
  // gzip'd: an SSM RunShellScript parameter is size-capped. nodered-flow.json is NOT shipped when the box has its own.
  ...Object.entries(f).filter(([n]) => n !== '.env' && !(helper && n === 'nodered-flow.json'))
    .map(([n, body]) => `printf '%s' '${gzipSync(Buffer.from(body, 'utf8')).toString('base64')}' | base64 -d | gunzip > "${n}"`),
  // seed the prod helper with the box's OWN helper flow (the stored artifact is the reader flow, not the helper flow)
  ...(helper ? ['if [ -s /opt/packiot/nodered-flow.json ]; then cp /opt/packiot/nodered-flow.json nodered-flow.json; else echo "[]" > nodered-flow.json; fi'] : []),
  `printf '%s' '${b64(f['.env'])}' | base64 -d > .env.new`,
  '{ grep -v "^INGEST_KEY=" .env.new; printf "INGEST_KEY=%s\\n" "$(head -n1 "$K" | tr -d "\\r\\n")"; } > .env && rm -f .env.new && chmod 600 .env',
  `docker compose -p packiot-${inst} -f compose.edge.yml up -d`,
  `docker ps --filter label=com.docker.compose.project=packiot-${inst} --format '{{.Names}} {{.Status}} {{.Ports}}'`,
  "docker ps --filter label=com.docker.compose.project=packiot --format 'staging untouched: {{.Names}} {{.Status}}'",
].join('\n') + '\n';
const uninstall = ['#!/bin/sh', `# uninstall.sh — remove ONLY the ${inst} instance (rollback); staging's /opt/packiot is never touched`, 'set -eu',
  `cd ${dir} && docker compose -p packiot-${inst} -f compose.edge.yml down`, `echo "${inst} instance stopped; ${dir} kept (spool, .env) for inspection"`].join('\n') + '\n';
writeFileSync(join(a.out!, '..', `install-${inst}.sh`), install);
writeFileSync(join(a.out!, '..', `uninstall-${inst}.sh`), uninstall);
console.log(JSON.stringify({
  instance: inst, project: `packiot-${inst}`, files: Object.keys(f).sort(), endpoints: bundle.endpointCount, tags: bundle.tagCount,
  targets_before: before, targets_after: cfg.targets.map((t: { name: string; url: string }) => `${t.name}=${t.url}`),
  gaps: bundle.gaps,
}, null, 1));
