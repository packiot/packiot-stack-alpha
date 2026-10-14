// node --test — token enforcement + header handling of the edge-session-broker.
// No session-manager-plugin needed: the /p/ data plane is pointed at a local fake
// "box" HTTP server by registering a forward directly in the exported map.
import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, describe, test } from 'node:test';
import WebSocket from 'ws';
import {
  boxRequestHeaders,
  createBroker,
  forwards,
  frameAncestorsCsp,
  requireToken,
  tokenMatches,
} from './server.mjs';

const TOKEN = 'a'.repeat(40);
const ANCESTORS = "'self' https://csadmin.example.test";

function listen(srv) {
  return new Promise((r) => srv.listen(0, '127.0.0.1', () => r(srv.address().port)));
}

function request(port, { method = 'GET', path = '/', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path, headers }, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: b }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

describe('startup', () => {
  test('refuses to start without a token', () => {
    assert.throws(() => createBroker({ token: undefined }), /BROKER_TOKEN/);
    assert.throws(() => createBroker({ token: '' }), /BROKER_TOKEN/);
  });
  test('refuses the old guessable fallback / any short token', () => {
    assert.throws(() => requireToken('esb-internal-staging'), /at least 32/);
    assert.equal(requireToken(`  ${TOKEN}  `), TOKEN);
  });
  test('frame-ancestors is a single directive, defaults to self', () => {
    assert.equal(frameAncestorsCsp(undefined), "frame-ancestors 'self'");
    assert.equal(frameAncestorsCsp(ANCESTORS), `frame-ancestors ${ANCESTORS}`);
    assert.throws(() => frameAncestorsCsp("'self'; script-src *"), /source list/);
  });
  test('tokenMatches is exact', () => {
    assert.equal(tokenMatches(TOKEN, TOKEN), true);
    assert.equal(tokenMatches(TOKEN.slice(1), TOKEN), false);
    assert.equal(tokenMatches(undefined, TOKEN), false);
    assert.equal(tokenMatches('', TOKEN), false);
    assert.equal(tokenMatches(['x'], TOKEN), false);
  });
});

describe('HTTP :8091', () => {
  let box, boxPort, broker, httpPort, lastBoxReq;
  const forwardCalls = [];

  before(async () => {
    box = http.createServer((req, res) => {
      lastBoxReq = { headers: req.headers, url: req.url };
      res.writeHead(200, {
        'content-type': 'text/html',
        'x-frame-options': 'DENY',
        'content-security-policy': "default-src 'self'; frame-ancestors 'none'",
        'content-security-policy-report-only': "script-src 'none'",
        'x-box': 'yes',
      });
      res.end('<html><head></head><body>box</body></html>');
    });
    boxPort = await listen(box);
    broker = createBroker({
      token: TOKEN,
      frameAncestors: ANCESTORS,
      startForwardFn: async (j) => {
        forwardCalls.push(j);
      },
    });
    httpPort = await listen(broker.httpSrv);
    forwards.set('sess-1', { localPort: boxPort, plugin: { kill() {} }, lastSeen: 0 });
  });

  after(() => {
    forwards.clear();
    broker.httpSrv.close();
    box.close();
  });

  test('/p/ without a token → 401, box never reached', async () => {
    lastBoxReq = undefined;
    const r = await request(httpPort, { path: '/p/sess-1/' });
    assert.equal(r.status, 401);
    assert.equal(lastBoxReq, undefined);
  });

  test('/p/ with a wrong token → 401', async () => {
    const r = await request(httpPort, { path: '/p/sess-1/', headers: { 'x-broker-token': 'b'.repeat(40) } });
    assert.equal(r.status, 401);
  });

  test('/p/ unknown session (authorized) → 404', async () => {
    const r = await request(httpPort, { path: '/p/nope/', headers: { 'x-broker-token': TOKEN } });
    assert.equal(r.status, 404);
  });

  test('/forward without a token → 401 and no forward started', async () => {
    const r = await request(httpPort, { method: 'POST', path: '/forward', body: '{}' });
    assert.equal(r.status, 401);
    // empty header value must not match (old code compared against an empty BROKER_TOKEN)
    const r2 = await request(httpPort, {
      method: 'POST',
      path: '/forward',
      headers: { 'x-broker-token': '' },
      body: '{}',
    });
    assert.equal(r2.status, 401);
    assert.equal(forwardCalls.length, 0);
  });

  test('/forward with the token → 200', async () => {
    const r = await request(httpPort, {
      method: 'POST',
      path: '/forward',
      headers: { 'x-broker-token': TOKEN, 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId: 's' }),
    });
    assert.equal(r.status, 200);
    assert.equal(forwardCalls.length, 1);
  });

  test('/p/ proxies: box framing headers replaced by our frame-ancestors CSP', async () => {
    const r = await request(httpPort, { path: '/p/sess-1/ui?x=1', headers: { 'x-broker-token': TOKEN } });
    assert.equal(r.status, 200);
    assert.equal(r.body, '<html><head></head><body>box</body></html>');
    assert.equal(r.headers['x-box'], 'yes');
    assert.equal(r.headers['x-frame-options'], undefined);
    assert.equal(r.headers['content-security-policy-report-only'], undefined);
    assert.equal(r.headers['content-security-policy'], `frame-ancestors ${ANCESTORS}`);
    assert.equal(lastBoxReq.url, '/ui?x=1');
  });

  test('/p/ never forwards platform secrets to the box', async () => {
    await request(httpPort, {
      path: '/p/sess-1/',
      headers: {
        'x-broker-token': TOKEN,
        cookie: '_oauth2_proxy=sekrit; pk_webui_sess-1=ticket; nr-session=keep',
        'x-auth-request-access-token': 'jwt',
        'x-forwarded-access-token': 'jwt',
        'x-amzn-oidc-data': 'jwt',
        authorization: 'Bearer node-red-own-token',
      },
    });
    const h = lastBoxReq.headers;
    assert.equal(h['x-broker-token'], undefined);
    assert.equal(h.cookie, 'nr-session=keep');
    assert.equal(h['x-auth-request-access-token'], undefined);
    assert.equal(h['x-forwarded-access-token'], undefined);
    assert.equal(h['x-amzn-oidc-data'], undefined);
    // the box UI's own auth (Node-RED adminAuth bearer) still works
    assert.equal(h.authorization, 'Bearer node-red-own-token');
    assert.equal(h.host, `127.0.0.1:${boxPort}`);
  });

  test('boxRequestHeaders drops the cookie header entirely when only platform cookies', () => {
    const h = boxRequestHeaders({ cookie: '_oauth2_proxy_csrf=a; pk_webui_x=b' }, 'h');
    assert.equal(h.cookie, undefined);
  });
});

describe('WS :8090/shell', () => {
  let broker, wsPort;
  before(async () => {
    broker = createBroker({ token: TOKEN });
    wsPort = await listen(broker.wsSrv);
  });
  after(() => {
    broker.wss.close();
    broker.wsSrv.close();
  });

  function closeCode(url) {
    return new Promise((resolve) => {
      const ws = new WebSocket(url);
      ws.on('close', (code) => resolve(code));
      ws.on('error', () => {});
    });
  }

  test('no token → closed 1008', async () => {
    assert.equal(await closeCode(`ws://127.0.0.1:${wsPort}/shell`), 1008);
  });

  test('wrong token → closed 1008', async () => {
    assert.equal(await closeCode(`ws://127.0.0.1:${wsPort}/shell?token=${'b'.repeat(40)}`), 1008);
  });

  test('right token → accepted (a bad handle then closes 1003, proving auth passed)', async () => {
    const code = await new Promise((resolve) => {
      const ws = new WebSocket(`ws://127.0.0.1:${wsPort}/shell?token=${TOKEN}`);
      ws.on('open', () => ws.send('not json'));
      ws.on('close', (c) => resolve(c));
    });
    assert.equal(code, 1003);
  });

  test('other paths are not upgraded', async () => {
    const err = await new Promise((resolve) => {
      const ws = new WebSocket(`ws://127.0.0.1:${wsPort}/other?token=${TOKEN}`);
      ws.on('error', (e) => resolve(e));
      ws.on('open', () => resolve(null));
    });
    assert.ok(err, 'expected the upgrade to be refused');
  });
});
