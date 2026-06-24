import { PoolClient } from 'pg';
import { ProdUserLog } from '../db/prod';
import { replayEventEdited } from './event-edited';
import { replayEventJustified } from './event-justified';
import { replayEventSplitted } from './event-splitted';
import { replayOrderChanged } from './order-changed';
import { replayOrderCreated } from './order-created';
import { replayOrderCreatedStarted } from './order-created-started';
import { replayOrderReplaced } from './order-replaced';
import { replayOrderStarted } from './order-started';
import { replayOrderStatusChanged } from './order-status-changed';
import { replayOrderStopped } from './order-stopped';

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
  'event-splitted': replayEventSplitted,
  // PO lifecycle handlers — added 2026-06-22 to close Gap 1 of the mirror.
  // order-changed maps to edge-api's /api/production-orders/setup (which
  // semantically stops the previous PO when prod swaps to a new one). The
  // 6 below are the rest of the PO event surface:
  //   order-started         operator/frontend started a pre-existing PO
  //   order-stopped         explicit stop endpoint (separate from setup)
  //   order-created         created without starting (status=1 available)
  //   order-created-started create-and-start in one shot — the operator's
  //                         "New PO" button; this is the keystone handler
  //                         for new prod POs auto-appearing on staging
  //   order-replaced        swap current PO with a pre-existing one
  //   order-status-changed  manually advance status (e.g. mark finished)
  //
  // Deliberately NOT replayed (yet):
  //   order-time-changed    needs production_order_runtime ID translation
  //                         which mirror_id_map doesn't have an entity_type
  //                         for. Adding it requires a translateRuntimeId
  //                         helper plus runtime-row business-key lookup.
  //   downtime-event-created                  factory edge-NR auto-emits;
  //                                           AMQP mirror covers it
  //   current-order-fetched, *-listed         read-only, no replay needed
  //   sample-*, label-*                       different domain; lower
  //                                           priority — add when needed
  'order-changed': replayOrderChanged,
  'order-started': replayOrderStarted,
  'order-stopped': replayOrderStopped,
  'order-created': replayOrderCreated,
  'order-created-started': replayOrderCreatedStarted,
  'order-replaced': replayOrderReplaced,
  'order-status-changed': replayOrderStatusChanged,
};

export function lookupReplayer(category: string | null): Replayer | undefined {
  if (!category) return undefined;
  return handlers[category];
}

export const handledCategories = Object.keys(handlers);
