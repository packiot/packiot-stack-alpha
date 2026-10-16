// edge-session-broker (ADR-0057 Phase 2) — the data-plane bridge for
// platform-mediated box access. edge-api holds the AWS role and calls
// ssm:StartSession (control plane); this sidecar takes the resulting handle and
// runs the AWS `session-manager-plugin` (a glibc binary edge-api's alpine image
// can't run), bridging the plugin's stdio to a WebSocket. The browser terminal
// (xterm.js) rides that WS via edge-api's authenticated relay.
//
// Trust model: this sidecar is INTERNAL (never exposed past the compose
// network). It authenticates its one caller — edge-api — with a shared
// BROKER_TOKEN on EVERY route (WS ?token=, HTTP x-broker-token; required ≥32
// chars at startup, no fallback), and receives the SSM handle (StreamUrl/TokenValue) from edge-api
// over the control frame, never from the browser. It holds NO AWS credentials:
// the plugin authenticates to AWS with the short-lived TokenValue edge-api
// already obtained. On WS close it kills the plugin; a plugin exit closes the WS.

import { spawn } from 'node:child_process';
import { createHash, timingSafeEqual } from 'node:crypto';
import http from 'node:http';
import net from 'node:net';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.BROKER_PORT || 8090);
const HTTP_PORT = Number(process.env.BROKER_HTTP_PORT || 8091);
const REGION = process.env.AWS_REGION || 'us-east-1';
const SSM_ENDPOINT = process.env.SSM_ENDPOINT || `https://ssm.${REGION}.amazonaws.com`;

// The token is the ONLY thing between "a process on packiot-net" and "a root
// shell / web UI on any client box": no fallback, no short values.
export const MIN_TOKEN_LEN = 32;
export function requireToken(t) {
  const v = String(t || '').trim();
  if (v.length < MIN_TOKEN_LEN) {
    throw new Error(
      `BROKER_TOKEN must be set to a secret of at least ${MIN_TOKEN_LEN} characters ` +
        `(got ${v.length}); refusing to start`,
    );
  }
  return v;
}

// Constant-time compare (hash both sides so lengths never leak or throw).
export function tokenMatches(got, want) {
  if (typeof got !== 'string' || !got || !want) return false;
  const a = createHash('sha256').update(got).digest();
  const b = createHash('sha256').update(want).digest();
  return timingSafeEqual(a, b);
}

// Framing policy for proxied box UIs. csadmin/customize embed the UI in an
// iframe (customize/src/components/edge/box-webui.tsx), so the box's own
// X-Frame-Options / CSP must not block that — but stripping them left the UI
// frameable by ANY site (clickjacking a CS engineer's live box session). We
// drop the box's headers (its CSP would also block edge-api's injected <base> +
// path shim) and send our own CSP whose only directive is frame-ancestors.
export function frameAncestorsCsp(list) {
  const v = String(list || "'self'").trim() || "'self'";
  if (/[;,\r\n]/.test(v)) throw new Error('BROKER_FRAME_ANCESTORS must be a space-separated source list');
  return `frame-ancestors ${v}`;
}

// Request headers that must never reach a client box: our own auth, the CS
// engineer's platform cookies, and identity/token headers oauth2-proxy or the
// ALB may add. A box is customer-premise hardware — treat it as untrusted.
const DROP_REQ_HEADERS = new Set(['x-broker-token']);
const DROP_REQ_PREFIXES = ['x-auth-request-', 'x-amzn-oidc-', 'x-forwarded-access-token', 'x-forwarded-id-token'];
const PLATFORM_COOKIE = /^(pk_webui_|_oauth2_proxy)/;
export function boxRequestHeaders(inHeaders, host) {
  const out = {};
  for (const [k, v] of Object.entries(inHeaders)) {
    const key = k.toLowerCase();
    if (DROP_REQ_HEADERS.has(key) || DROP_REQ_PREFIXES.some((p) => key.startsWith(p))) continue;
    if (key === 'cookie') {
      const kept = String(v)
        .split(';')
        .map((c) => c.trim())
        .filter((c) => c && !PLATFORM_COOKIE.test(c));
      if (kept.length) out.cookie = kept.join('; ');
      continue;
    }
    out[key] = v;
  }
  out.host = host;
  return out;
}

export function boxResponseHeaders(inHeaders, csp) {
  const h = { ...inHeaders };
  delete h['x-frame-options'];
  delete h['content-security-policy'];
  delete h['content-security-policy-report-only'];
  h['content-security-policy'] = csp;
  return h;
}

function log(...a) {
  console.log(new Date().toISOString(), '[broker]', ...a);
}

// Build the session-manager-plugin argv+env for a StartSession handle. The
// SENSITIVE response goes via env var (never argv → not in `ps`); argv[1] is its
// NAME, argv[4] is an empty profile, argv[5] the ORIGINAL request params.
function pluginArgs(response, requestParams) {
  return {
    args: [
      'AWS_SSM_START_SESSION_RESPONSE',
      REGION,
      'StartSession',
      '',
      JSON.stringify(requestParams),
      SSM_ENDPOINT,
    ],
    env: {
      ...process.env,
      AWS_SSM_START_SESSION_RESPONSE: JSON.stringify(response),
    },
  };
}

// ── Phase 2b: HTTP reverse-proxy through a port-forward ──────────────────────
// One port-forward per web-UI session. edge-api obtains the port-forward
// StartSession handle (it holds the AWS role) and POSTs it here; we run the
// plugin binding 127.0.0.1:<localPort> IN THIS container, then reverse-proxy
// HTTP to it. edge-api reverse-proxies the browser to us. Idle forwards reaped.
export const forwards = new Map(); // sessionId -> { localPort, plugin, lastSeen }
const FORWARD_IDLE_MS = Number(process.env.BROKER_FORWARD_IDLE_MS || 10 * 60 * 1000);

function startForward({ sessionId, response, target, boxPort, localPort }) {
  return new Promise((resolve, reject) => {
    const requestParams = {
      Target: target,
      DocumentName: 'AWS-StartPortForwardingSession',
      Parameters: {
        portNumber: [String(boxPort)],
        localPortNumber: [String(localPort)],
      },
    };
    const { args, env } = pluginArgs(response, requestParams);
    const plugin = spawn('session-manager-plugin', args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      env,
    });
    plugin.stderr.on('data', (b) => log(`pf[${sessionId}] stderr: ${b}`));
    plugin.on('exit', (c) => {
      log(`pf[${sessionId}] plugin exit ${c}`);
      forwards.delete(sessionId);
    });
    forwards.set(sessionId, { localPort, plugin, lastSeen: Date.now() });
    // Wait until the forwarded local port is actually accepting connections.
    let tries = 0;
    const iv = setInterval(() => {
      const s = net.connect(localPort, '127.0.0.1');
      s.on('connect', () => {
        s.destroy();
        clearInterval(iv);
        resolve();
      });
      s.on('error', () => {
        s.destroy();
        if (++tries > 40) {
          clearInterval(iv);
          try {
            plugin.kill('SIGKILL');
          } catch {
            /* noop */
          }
          reject(new Error('port-forward did not come up'));
        }
      });
    }, 250);
  });
}

function unauthorized(res) {
  res.writeHead(401);
  res.end('unauthorized');
}

// Both listeners, wired to a token + framing policy. Exported for the tests;
// main() below is the production entrypoint.
export function createBroker({ token, frameAncestors, startForwardFn = startForward } = {}) {
  const BROKER_TOKEN = requireToken(token);
  const CSP = frameAncestorsCsp(frameAncestors);

  const httpSrv = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    // Every route on :8091 is edge-api-only — the /p/ data plane included (it
    // was unauthenticated: any process on packiot-net that learned a SessionId
    // could drive a box's Node-RED admin API / dashboard).
    if (!tokenMatches(req.headers['x-broker-token'], BROKER_TOKEN)) {
      return unauthorized(res);
    }
    // Control plane: start a port-forward.
    if (req.method === 'POST' && url.pathname === '/forward') {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        let j;
        try {
          j = JSON.parse(body);
        } catch {
          res.writeHead(400);
          return res.end('bad json');
        }
        startForwardFn(j)
          .then(() => {
            res.writeHead(200);
            res.end('ok');
          })
          .catch((e) => {
            log(`forward failed: ${String(e)}`);
            res.writeHead(502);
            res.end(String(e));
          });
      });
      return;
    }
    // Data plane: /p/:sessionId/* → the box web UI via the forward.
    const m = url.pathname.match(/^\/p\/([^/]+)(\/.*)?$/);
    if (m) {
      const f = forwards.get(m[1]);
      if (!f) {
        res.writeHead(404);
        return res.end('no active forward');
      }
      f.lastSeen = Date.now();
      const preq = http.request(
        {
          host: '127.0.0.1',
          port: f.localPort,
          method: req.method,
          path: (m[2] || '/') + url.search,
          headers: boxRequestHeaders(req.headers, `127.0.0.1:${f.localPort}`),
        },
        (pres) => {
          res.writeHead(pres.statusCode || 502, boxResponseHeaders(pres.headers, CSP));
          pres.pipe(res);
        },
      );
      preq.on('error', (e) => {
        res.writeHead(502);
        res.end(String(e));
      });
      req.pipe(preq);
      return;
    }
    res.writeHead(404);
    res.end('not found');
  });

  const wss = new WebSocketServer({ noServer: true });
  const wsSrv = http.createServer((req, res) => {
    res.writeHead(426);
    res.end('websocket only');
  });
  wsSrv.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname !== '/shell') {
      socket.end('HTTP/1.1 404 Not Found\r\n\r\n');
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  });

  wss.on('connection', (ws, req) => {
    // AuthN: shared-secret with edge-api (query param — edge-api's relay sends
    // ?token=). Anyone else is dropped immediately.
    const url = new URL(req.url, 'http://localhost');
    if (!tokenMatches(url.searchParams.get('token'), BROKER_TOKEN)) {
      log('rejected unauthenticated connection');
      ws.close(1008, 'unauthorized');
      return;
    }
    handleShell(ws);
  });

  return { httpSrv, wsSrv, wss };
}

function handleShell(ws) {
  let plugin = null;
  let started = false;

  // First TEXT frame carries the SSM handle from edge-api. Everything after is
  // raw terminal I/O bridged to the plugin.
  ws.on('message', (data, isBinary) => {
    if (!started) {
      started = true;
      let handle;
      try {
        handle = JSON.parse(data.toString());
      } catch {
        ws.close(1003, 'bad handle');
        return;
      }
      const { SessionId, StreamUrl, TokenValue, Target, region } = handle;
      if (!SessionId || !StreamUrl || !TokenValue) {
        ws.close(1003, 'incomplete handle');
        return;
      }
      // Arg contract (captured from the AWS CLI's own invocation): the SENSITIVE
      // StartSession response is passed via an ENV VAR (never argv, so the token
      // can't leak in `ps`); argv[1] is that env var's NAME. Then region,
      // operation, the ORIGINAL request params (JSON), and the endpoint:
      //   session-manager-plugin AWS_SSM_START_SESSION_RESPONSE <region> \
      //     StartSession "<profile>" <request-params-json> <endpoint>
      // (argv verified against the AWS CLI's own /proc/<pid>/cmdline: env-var
      // NAME in argv[1], an EMPTY profile arg, then the ORIGINAL request JSON.)
      const responseJson = JSON.stringify({ SessionId, StreamUrl, TokenValue });
      const requestJson = JSON.stringify(Target ? { Target } : {});
      const args = [
        'AWS_SSM_START_SESSION_RESPONSE',
        region || process.env.AWS_REGION || 'us-east-1',
        'StartSession',
        '', // profile (empty — creds come via the env-var response token)
        requestJson,
        SSM_ENDPOINT,
      ];
      log(`starting plugin for session ${SessionId} target ${Target || '?'}`);
      plugin = spawn('session-manager-plugin', args, {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env, AWS_SSM_START_SESSION_RESPONSE: responseJson },
      });
      plugin.stdout.on('data', (buf) => {
        if (ws.readyState === ws.OPEN) ws.send(buf);
      });
      plugin.stderr.on('data', (buf) => log(`plugin stderr: ${buf}`));
      plugin.on('exit', (code) => {
        log(`plugin exited ${code} for session ${SessionId}`);
        if (ws.readyState === ws.OPEN) ws.close(1000, `plugin exit ${code}`);
      });
      return;
    }
    // Subsequent frames = terminal keystrokes → plugin stdin.
    if (plugin && !plugin.killed) {
      plugin.stdin.write(isBinary ? data : data.toString());
    }
  });

  ws.on('close', () => {
    if (plugin && !plugin.killed) {
      log('ws closed — killing plugin');
      plugin.kill('SIGKILL');
    }
  });
  ws.on('error', (e) => log(`ws error: ${e}`));
}

// Reap idle port-forwards.
function startReaper() {
  return setInterval(() => {
    const now = Date.now();
    for (const [sid, f] of forwards) {
      if (now - f.lastSeen > FORWARD_IDLE_MS) {
        log(`reaping idle forward ${sid}`);
        try {
          f.plugin.kill('SIGKILL');
        } catch {
          /* noop */
        }
        forwards.delete(sid);
      }
    }
  }, 60 * 1000).unref?.();
}

function main() {
  let broker;
  try {
    broker = createBroker({
      token: process.env.BROKER_TOKEN,
      frameAncestors: process.env.BROKER_FRAME_ANCESTORS,
    });
    // Not inherited by the session-manager-plugin children (they get ...process.env).
    delete process.env.BROKER_TOKEN;
  } catch (e) {
    console.error(new Date().toISOString(), '[broker] FATAL', e.message);
    process.exit(1);
  }
  const { httpSrv, wsSrv, wss } = broker;
  httpSrv.listen(HTTP_PORT, () => log(`http reverse-proxy on :${HTTP_PORT}`));
  wsSrv.listen(PORT, () => log(`listening on :${PORT}/shell`));
  startReaper();
  process.on('SIGTERM', () => {
    log('SIGTERM — closing');
    wss.close(() => process.exit(0));
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
