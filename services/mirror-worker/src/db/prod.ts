import { Pool, PoolClient, QueryResultRow } from 'pg';
import { config } from '../config';
import { log } from '../log';
import { ProdDbCreds } from '../secrets';

let pool: Pool | undefined;

export function initProdPool(creds: ProdDbCreds): void {
  pool = new Pool({
    host: creds.host,
    port: creds.port,
    user: creds.user,
    password: creds.password,
    database: creds.database,
    max: 3,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    application_name: 'mirror-worker',
  });
  pool.on('error', (err) => log.error({ err }, 'prod pool error'));
}

// Every read uses a READ ONLY transaction. This is belt-and-suspenders on top
// of the IAM-scoped awslambda user — the user is already SELECT-only at the
// role level, but a stray INSERT in our own code would be caught here too.
async function withReadOnly<T>(
  fn: (c: PoolClient) => Promise<T>,
): Promise<T> {
  if (!pool) throw new Error('prod pool not initialised');
  const client = await pool.connect();
  try {
    await client.query('BEGIN READ ONLY');
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

export interface ProdUserLog {
  id_user_logs: string; // bigint as string
  ts_event: Date;
  category: string | null;
  subcategory: string | null;
  id_enterprise: number;
  id_site: number | null;
  id_area: number | null;
  id_equipment: number | null;
  nm_user: string | null;
  payload: unknown;
}

export async function fetchNewProdLogs(
  cursor: bigint,
  limit: number,
): Promise<ProdUserLog[]> {
  return withReadOnly(async (c) => {
    const { rows } = await c.query<ProdUserLog>(
      `SELECT id_user_logs::text AS id_user_logs,
              ts_event, category, subcategory,
              id_enterprise, id_site, id_area, id_equipment,
              nm_user, payload
         FROM user_logs
        WHERE id_user_logs > $1
          AND id_enterprise = $2
        ORDER BY id_user_logs ASC
        LIMIT $3`,
      [cursor.toString(), config.prodEnterpriseId, limit],
    );
    return rows;
  });
}

// Used by translators to look up an entity's business key on prod by its
// prod surrogate ID (e.g. resolve idEquipmentEvent -> {id_equipment, ts_event,
// status} so we can match the equivalent staging row).
export async function prodSelectOne<T extends QueryResultRow>(
  sql: string,
  params: unknown[],
): Promise<T | undefined> {
  return withReadOnly(async (c) => {
    const { rows } = await c.query<T>(sql, params);
    return rows[0];
  });
}

export async function prodSelectMany<T extends QueryResultRow>(
  sql: string,
  params: unknown[],
): Promise<T[]> {
  return withReadOnly(async (c) => {
    const { rows } = await c.query<T>(sql, params);
    return rows;
  });
}
