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
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.BROKER_PORT || 8090);
const BROKER_TOKEN = process.env.BROKER_TOKEN || '';
const SSM_ENDPOINT =
  process.env.SSM_ENDPOINT || `https://ssm.${process.env.AWS_REGION || 'us-east-1'}.amazonaws.com`;

function log(...a) {
  console.log(new Date().toISOString(), '[broker]', ...a);
}

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
