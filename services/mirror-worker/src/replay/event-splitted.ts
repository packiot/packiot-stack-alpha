import axios from 'axios';
import { PoolClient } from 'pg';
import { config } from '../config';
import { log } from '../log';
import { ProdUserLog } from '../db/prod';
import { insertMapping } from '../db/staging';
import { getStagingApiToken } from '../runtime';
import { translateEquipmentEventId, translateEquipmentId } from '../translate';

// Prod payload shape (sampled session 55):
//   {
//     events: [
//       { startTime, endTime, note, type, machineCode, categoryCode,
//         subcategoryCode, descCategory, descSubcategory, idle, changeOver,
//         plannedDowntime }, ...
//     ],
//     eventType: 'downtime' | 'manual' | 'low_speed',
//     idEquipment: <prod>,
//     idEquipmentEvent: <prod>
//   }
//
// Translation: same chain as event-justified / event-edited
//   idEquipment      -> packml_topic
//   idEquipmentEvent -> interval-overlap (mirror_id_map cached)
//
// The events array passes through verbatim — operator-set metadata only,
// no IDs to translate. Prod's EventDto has a `type` field that staging's
// EventDto doesn't declare; class-validator's default behavior keeps it.
//
// Output: POST /api/downtimes/split
interface SplitPayload {
  events: unknown[];
  eventType: string;
  idEquipment: number;
  idEquipmentEvent: number;
}

export async function replayEventSplitted(
  client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as SplitPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('event-splitted payload missing or not an object');
  }
  if (!Array.isArray(payload.events) || payload.events.length === 0) {
    throw new Error('event-splitted payload missing non-empty events array');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('event-splitted payload missing idEquipment');
  }
  if (typeof payload.idEquipmentEvent !== 'number') {
    throw new Error('event-splitted payload missing idEquipmentEvent');
  }
  if (!payload.eventType) {
    throw new Error('event-splitted payload missing eventType');
  }

  const stagingEquipmentId = await translateEquipmentId(payload.idEquipment);
  const stagingEventId = await translateEquipmentEventId(
    BigInt(payload.idEquipmentEvent),
  );
  if (stagingEventId === undefined) {
    throw new Error(
      `equipment_event ${payload.idEquipmentEvent} unmapped (no staging interval overlap; see WARN log)`,
    );
  }

  // Cache the mapping so subsequent operations on the same prod event skip
  // the SELECT — same pattern as event-justified / event-edited.
  await insertMapping(client, {
    entityType: 'equipment_event',
    source: config.sourceName,
    prodId: BigInt(payload.idEquipmentEvent),
    stagingId: stagingEventId,
    sourceLogId: BigInt(row.id_user_logs),
  });

  const body = {
    idEquipment: stagingEquipmentId,
    idEquipmentEvent: Number(stagingEventId),
    eventType: payload.eventType,
    events: payload.events,
  };

  const url = `${config.stagingApi.baseUrl}/api/downtimes/split`;
  const res = await axios.post(url, body, {
    params: {
      token: getStagingApiToken(),
      idEnterprise: config.stagingEnterpriseId,
    },
    headers: {
      'x-user': row.nm_user ?? 'mirror-worker',
      'X-Mirror-Source': config.sourceName,
    },
    validateStatus: () => true,
    timeout: 15_000,
  });

  if (res.status >= 400) {
    throw new Error(
      `staging /api/downtimes/split returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  log.info(
    {
      sourceLogId: row.id_user_logs,
      prodEventId: payload.idEquipmentEvent,
      stagingEventId: stagingEventId.toString(),
      splitInto: payload.events.length,
      status: res.status,
    },
    'replayed event-splitted',
  );
}
