import { config } from './config';
import { log } from './log';
import { loadProdDbCreds } from './secrets';
import { fetchNewProdLogs, initProdPool, ProdUserLog } from './db/prod';
import {
  advanceCursor,
  fetchStagingApiToken,
  isAlreadyReplayed,
  readCursor,
  withStagingTx,
} from './db/staging';
import { writeDlq } from './dlq';
import { recordTickError, recordTickSuccess, startHealthServer } from './health';
import { handledCategories, lookupReplayer } from './replay';
import { setStagingApiToken } from './runtime';

async function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// One row, one transaction. The cursor advances on every outcome (success or
// DLQ) — a single bad row should not block the queue. Crash mid-transaction
// rolls everything back and we re-replay on next tick; the
// `isAlreadyReplayed` guard catches the duplicate before the API call.
async function processRow(row: ProdUserLog): Promise<void> {
  const rowId = BigInt(row.id_user_logs);
  const replayer = lookupReplayer(row.category);

  await withStagingTx(async (client) => {
    if (await isAlreadyReplayed(config.sourceName, rowId)) {
      log.debug(
        { sourceLogId: row.id_user_logs },
        'already replayed (mirror_id_map hit), advancing cursor',
      );
      await advanceCursor(client, config.sourceName, rowId);
      return;
    }

    if (!replayer) {
      log.debug(
        { sourceLogId: row.id_user_logs, category: row.category },
        'category not handled, advancing cursor',
      );
      await advanceCursor(client, config.sourceName, rowId);
      return;
    }

    try {
      await replayer(client, row);
    } catch (err) {
      // Per-row failures must NOT poison the rest of the batch. We commit a
      // DLQ row + the cursor advance in this same transaction so the next
      // tick starts at the row after this one.
      log.warn(
        {
          err: (err as Error).message,
          sourceLogId: row.id_user_logs,
          category: row.category,
        },
        'replay failed, writing DLQ row',
      );
      await writeDlq(client, {
        source: config.sourceName,
        sourceLogId: rowId,
        category: row.category,
        subcategory: row.subcategory,
        payload: row.payload,
        error: (err as Error).message,
      });
    }

    await advanceCursor(client, config.sourceName, rowId);
  });
}

async function tick(): Promise<void> {
  const cursor = await readCursor(config.sourceName);
  const rows = await fetchNewProdLogs(cursor, config.batchSize);
  if (rows.length === 0) {
    log.debug({ cursor: cursor.toString() }, 'no new rows');
    return;
  }
  log.info(
    {
      cursor: cursor.toString(),
      batch: rows.length,
      categories: rows.map((r) => r.category),
    },
    'processing batch',
  );

  for (const row of rows) {
    await processRow(row);
    if (config.perPostDelayMs > 0) {
      await sleep(config.perPostDelayMs);
    }
  }
}

async function main(): Promise<void> {
  log.info(
    {
      pollIntervalSec: config.pollIntervalSec,
      batchSize: config.batchSize,
      sourceName: config.sourceName,
      handled: handledCategories,
      stagingApi: config.stagingApi.baseUrl,
    },
    'mirror-worker starting',
  );

  const creds = await loadProdDbCreds();
  initProdPool(creds);

  // Resolve the staging api_key from enterprises.api_key once at startup.
  // Rotations require a worker restart but not a redeploy.
  const token = await fetchStagingApiToken(config.stagingEnterpriseId);
  setStagingApiToken(token);
  log.info(
    { enterpriseId: config.stagingEnterpriseId, tokenPrefix: token.slice(0, 8) },
    'fetched staging api token',
  );

  // /health on 9100. Listens for the lifetime of the process; Grafana polls
  // it via Promtail or directly. Started before the loop so the first tick
  // grace window starts ticking from listen-time.
  startHealthServer(config.healthPort);

  // Single-instance, sequential. 155 mutations/day = ~0.002/sec, polling
  // every 60s drains comfortably with the batch+delay tuning above.
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      await tick();
      recordTickSuccess();
    } catch (err) {
      log.error({ err: (err as Error).message }, 'tick failed');
      recordTickError(err as Error);
    }
    await sleep(config.pollIntervalSec * 1_000);
  }
}

main().catch((err) => {
  log.fatal({ err: (err as Error).message }, 'fatal error');
  process.exit(1);
});
