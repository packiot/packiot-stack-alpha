import { Pool, PoolClient, QueryResultRow } from 'pg';
import { config } from '../config';
import { log } from '../log';

const pool = new Pool({
  host: config.stagingDb.host,
  port: config.stagingDb.port,
  user: config.stagingDb.user,
  password: config.stagingDb.password,
  database: config.stagingDb.database,
  max: 5,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
  application_name: 'mirror-worker',
});

pool.on('error', (err) => log.error({ err }, 'staging pool error'));

export async function withStagingTx<T>(
  fn: (c: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw e;
  } finally {
    client.release();
  }
}

export async function stagingSelectOne<T extends QueryResultRow>(
  sql: string,
  params: unknown[],
): Promise<T | undefined> {
  const client = await pool.connect();
  try {
    const { rows } = await client.query<T>(sql, params);
    return rows[0];
  } finally {
    client.release();
  }
}

export async function fetchStagingApiToken(
  enterpriseId: number,
): Promise<string> {
  const row = await stagingSelectOne<{ api_key: string }>(
    `SELECT api_key FROM enterprises WHERE id_enterprise = $1`,
    [enterpriseId],
  );
  if (!row || !row.api_key) {
    throw new Error(
      `enterprises.api_key missing for id_enterprise=${enterpriseId} on staging — seed it before starting the worker`,
    );
  }
  return row.api_key;
}

export async function readCursor(source: string): Promise<bigint> {
  const row = await stagingSelectOne<{ last_log_id: string }>(
    `SELECT last_log_id::text FROM mirror_replay_cursor WHERE source = $1`,
    [source],
  );
  if (!row) {
    throw new Error(
      `cursor row for source '${source}' missing — seed it before starting`,
    );
  }
  return BigInt(row.last_log_id);
}

export async function advanceCursor(
  client: PoolClient,
  source: string,
  toId: bigint,
): Promise<void> {
  await client.query(
    `UPDATE mirror_replay_cursor
        SET last_log_id = $1, last_run_at = now()
      WHERE source = $2
        AND last_log_id < $1`,
    [toId.toString(), source],
  );
}

export interface MapInsert {
  entityType: string;
  source: string;
  prodId: bigint;
  stagingId: bigint;
  sourceLogId: bigint;
}

export async function insertMapping(
  client: PoolClient,
  m: MapInsert,
): Promise<void> {
  await client.query(
    `INSERT INTO mirror_id_map
       (entity_type, source, prod_id, staging_id, source_log_id)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (entity_type, source, prod_id) DO NOTHING`,
    [
      m.entityType,
      m.source,
      m.prodId.toString(),
      m.stagingId.toString(),
      m.sourceLogId.toString(),
    ],
  );
}

export async function lookupMapping(
  entityType: string,
  source: string,
  prodId: bigint,
): Promise<bigint | undefined> {
  const row = await stagingSelectOne<{ staging_id: string }>(
    `SELECT staging_id::text
       FROM mirror_id_map
      WHERE entity_type = $1 AND source = $2 AND prod_id = $3`,
    [entityType, source, prodId.toString()],
  );
  return row ? BigInt(row.staging_id) : undefined;
}

export async function isAlreadyReplayed(
  source: string,
  sourceLogId: bigint,
): Promise<boolean> {
  const row = await stagingSelectOne<{ exists: boolean }>(
    `SELECT EXISTS(
       SELECT 1 FROM mirror_id_map
        WHERE source = $1 AND source_log_id = $2
     ) AS exists`,
    [source, sourceLogId.toString()],
  );
  return Boolean(row?.exists);
}
