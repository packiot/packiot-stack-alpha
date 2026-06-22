import http from 'node:http';
import { log } from './log';
import { stagingSelectOne, readCursor } from './db/staging';
import { config } from './config';

// In-memory state updated by the main loop. Health server reads these
// snapshots cheaply — DB hits only when /health is actually called.
interface HealthState {
  lastTickAt: number | null;        // epoch ms — when the loop last completed a tick
  lastTickError: string | null;     // last tick error message (cleared on next success)
  startedAt: number;                // epoch ms — process start
}

const state: HealthState = {
  lastTickAt: null,
  lastTickError: null,
  startedAt: Date.now(),
};

export function recordTickSuccess(): void {
  state.lastTickAt = Date.now();
  state.lastTickError = null;
}

export function recordTickError(err: Error): void {
  state.lastTickAt = Date.now();
  state.lastTickError = err.message;
}

interface HealthBody {
  status: 'healthy' | 'degraded' | 'unhealthy';
  uptimeSec: number;
  lastTickAgeMs: number | null;
  lastTickError: string | null;
  cursor: string | null;
  dlqDepth: number | null;
  reason?: string;
}

// Thresholds (in ms). pollIntervalSec drives the natural beat; we tolerate
// roughly 3 intervals before flagging degraded, 10 before unhealthy.
const degradedAfterMs = config.pollIntervalSec * 1_000 * 3;
const unhealthyAfterMs = config.pollIntervalSec * 1_000 * 10;

async function buildBody(): Promise<HealthBody> {
  const now = Date.now();
  const uptimeSec = Math.floor((now - state.startedAt) / 1_000);
  const lastTickAgeMs = state.lastTickAt === null ? null : now - state.lastTickAt;

  let cursor: string | null = null;
  let dlqDepth: number | null = null;

  try {
    cursor = (await readCursor(config.sourceName)).toString();
  } catch (err) {
    log.warn({ err: (err as Error).message }, 'health: readCursor failed');
  }
  try {
    const row = await stagingSelectOne<{ c: string }>(
      `SELECT COUNT(*)::text AS c FROM mirror_replay_dlq WHERE resolved_at IS NULL`,
      [],
    );
    dlqDepth = row ? Number(row.c) : null;
  } catch (err) {
    log.warn({ err: (err as Error).message }, 'health: dlq count failed');
  }

  // Classification: start with healthy, downgrade as signals worsen. We treat
  // the DB read failures above as soft signals (dlqDepth=null doesn't tip
  // unhealthy on its own — the cursor read or tick freshness would catch a
  // real outage).
  let status: HealthBody['status'] = 'healthy';
  let reason: string | undefined;

  if (state.lastTickAt === null && uptimeSec > config.pollIntervalSec * 2) {
    status = 'unhealthy';
    reason = 'no successful tick yet, past startup grace window';
  } else if (lastTickAgeMs !== null && lastTickAgeMs > unhealthyAfterMs) {
    status = 'unhealthy';
    reason = `last tick was ${lastTickAgeMs}ms ago (>${unhealthyAfterMs}ms)`;
  } else if (lastTickAgeMs !== null && lastTickAgeMs > degradedAfterMs) {
    status = 'degraded';
    reason = `last tick was ${lastTickAgeMs}ms ago (>${degradedAfterMs}ms)`;
  } else if (state.lastTickError) {
    status = 'degraded';
    reason = `last tick errored: ${state.lastTickError}`;
  } else if (dlqDepth !== null && dlqDepth > 0) {
    status = 'degraded';
    reason = `${dlqDepth} unresolved DLQ rows`;
  }

  return {
    status,
    uptimeSec,
    lastTickAgeMs,
    lastTickError: state.lastTickError,
    cursor,
    dlqDepth,
    ...(reason ? { reason } : {}),
  };
}

export function startHealthServer(port: number): http.Server {
  const server = http.createServer((req, res) => {
    if (req.url !== '/health') {
      res.statusCode = 404;
      res.end();
      return;
    }
    buildBody()
      .then((body) => {
        // 200 for healthy + degraded, 503 for unhealthy. Degraded stays 200
        // so a single missed tick doesn't page on-call — Grafana watches
        // the `status` field for the warning level.
        res.statusCode = body.status === 'unhealthy' ? 503 : 200;
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify(body));
      })
      .catch((err) => {
        log.error({ err: (err as Error).message }, '/health build failed');
        res.statusCode = 500;
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify({ status: 'unhealthy', error: (err as Error).message }));
      });
  });
  server.listen(port, '0.0.0.0', () => {
    log.info({ port }, 'health server listening');
  });
  return server;
}
