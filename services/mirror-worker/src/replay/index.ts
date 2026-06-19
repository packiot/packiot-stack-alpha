import { PoolClient } from 'pg';
import { ProdUserLog } from '../db/prod';
import { replayEventEdited } from './event-edited';
import { replayEventJustified } from './event-justified';
import { replayOrderChanged } from './order-changed';

export type Replayer = (client: PoolClient, row: ProdUserLog) => Promise<void>;

// Per-category dispatch. Categories absent from this map are no-ops on
// purpose — we want the cursor to advance past unknown rows rather than
// piling them all into the DLQ.
//
// downtime-event-created is deliberately skipped: those rows come from the
// factory edge-NR auto-publishing PLC state changes, and the SparkPlug AMQP
// mirror (real-client-data Step 4) already brings those into staging via
// equipment_values + triggers. Replaying them would create duplicates.
const handlers: Record<string, Replayer> = {
  'event-justified': replayEventJustified,
  'event-edited': replayEventEdited,
  'order-changed': replayOrderChanged,
};

export function lookupReplayer(category: string | null): Replayer | undefined {
  if (!category) return undefined;
  return handlers[category];
}

export const handledCategories = Object.keys(handlers);
