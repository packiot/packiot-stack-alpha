import { PoolClient } from 'pg';
import { ProdUserLog } from '../db/prod';
import { replayEventJustified } from './event-justified';

export type Replayer = (client: PoolClient, row: ProdUserLog) => Promise<void>;

// Per-category dispatch. Categories absent from this map are no-ops on
// purpose — we want the cursor to advance past unknown rows rather than
// piling them all into the DLQ.
//
// Phase A4: only event-justified is wired. Phase A5 expansion is mechanical
// once each event-type's payload + endpoint + translation are codified.
const handlers: Record<string, Replayer> = {
  'event-justified': replayEventJustified,
};

export function lookupReplayer(category: string | null): Replayer | undefined {
  if (!category) return undefined;
  return handlers[category];
}

export const handledCategories = Object.keys(handlers);
