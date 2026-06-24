import { PoolClient } from 'pg';

export interface DlqEntry {
  source: string;
  sourceLogId: bigint;
  category: string | null;
  subcategory: string | null;
  payload: unknown;
  error: string;
}

export async function writeDlq(
  client: PoolClient,
  e: DlqEntry,
): Promise<void> {
  await client.query(
    `INSERT INTO mirror_replay_dlq
       (source, source_log_id, category, subcategory, payload, error)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [
      e.source,
      e.sourceLogId.toString(),
      e.category,
      e.subcategory,
      e.payload,
      e.error,
    ],
  );
}
