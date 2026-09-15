// edge-session-broker (ADR-0057 Phase 2) — the data-plane bridge for
// platform-mediated box access. edge-api holds the AWS role and calls
// ssm:StartSession (control plane); this sidecar takes the resulting handle and
// runs the AWS `session-manager-plugin` (a glibc binary edge-api's alpine image
// can't run), bridging the plugin's stdio to a WebSocket. The browser terminal
// (xterm.js) rides that WS via edge-api's authenticated relay.
//
// Trust model: this sidecar is INTERNAL (never exposed past the compose
// network). It authenticates its one caller — edge-api — with a shared
// BROKER_TOKEN, and receives the SSM handle (StreamUrl/TokenValue) from edge-api
// over the control frame, never from the browser. It holds NO AWS credentials:
// the plugin authenticates to AWS with the short-lived TokenValue edge-api
// already obtained. On WS close it kills the plugin; a plugin exit closes the WS.

import { spawn } from 'node:child_process';
import http from 'node:http';
import net from 'node:net';
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.BROKER_PORT || 8090);
const HTTP_PORT = Number(process.env.BROKER_HTTP_PORT || 8091);
const BROKER_TOKEN = process.env.BROKER_TOKEN || '';
const REGION = process.env.AWS_REGION || 'us-east-1';
const SSM_ENDPOINT = process.env.SSM_ENDPOINT || `https://ssm.${REGION}.amazonaws.com`;

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
const forwards = new Map(); // sessionId -> { localPort, plugin, lastSeen }
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

const httpSrv = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  // Control plane (edge-api only): start a port-forward.
  if (req.method === 'POST' && url.pathname === '/forward') {
    if (req.headers['x-broker-token'] !== BROKER_TOKEN) {
      res.writeHead(401);
      return res.end('unauthorized');
    }
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
      startForward(j)
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
        headers: { ...req.headers, host: `127.0.0.1:${f.localPort}` },
      },
      (pres) => {
        const h = { ...pres.headers };
        // Strip framing blockers so edge-api can iframe the UI.
        delete h['x-frame-options'];
        delete h['content-security-policy'];
        res.writeHead(pres.statusCode || 502, h);
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
httpSrv.listen(HTTP_PORT, () => log(`http reverse-proxy on :${HTTP_PORT}`));

// Reap idle port-forwards.
setInterval(() => {
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

const wss = new WebSocketServer({ port: PORT, path: '/shell' });
log(`listening on :${PORT}/shell`);

wss.on('connection', (ws, req) => {
  // AuthN: shared-secret with edge-api. Anyone else is dropped immediately.
  const url = new URL(req.url, 'http://localhost');
  if (!BROKER_TOKEN || url.searchParams.get('token') !== BROKER_TOKEN) {
    log('rejected unauthenticated connection');
    ws.close(1008, 'unauthorized');
    return;
  }

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
});

process.on('SIGTERM', () => {
  log('SIGTERM — closing');
  wss.close(() => process.exit(0));
});
