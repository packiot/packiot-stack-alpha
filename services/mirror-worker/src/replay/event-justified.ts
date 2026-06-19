import axios from 'axios';
import { PoolClient } from 'pg';
import { config } from '../config';
import { log } from '../log';
import { ProdUserLog } from '../db/prod';
import { insertMapping } from '../db/staging';
import { getStagingApiToken } from '../runtime';
import { translateEquipmentEventId, translateEquipmentId } from '../translate';

// Prod payload shape captured from session 55 inspection:
//   {
//     idle: 'no', cdMachine, cdCategory, descCategory,
//     cdSubcategory, descSubcategory, changeOver, plannedDowntime,
//     idEquipment: <prod>,
//     idEquipmentEvent: <prod>,
//     txtDowntimeNotes
//   }
//
// Translation:
//   idEquipment      -> via packml_topic
//   idEquipmentEvent -> via business key (id_equipment + ts_event + status)
//                       cached in mirror_id_map after first hit
//
// Output: POST /api/downtimes/justify with idEnterprise added
// (operator UI passes it as a query param on prod; we send it in the body
// for consistency with the worker pipeline).
interface JustifyPayload {
  idle: string;
  cdMachine?: string;
  cdCategory?: string;
  descCategory?: string;
  cdSubcategory?: string;
  descSubcategory?: string;
  changeOver?: boolean;
  plannedDowntime?: boolean;
  idEquipment: number;
  idEquipmentEvent: number;
  txtDowntimeNotes?: string;
}

export async function replayEventJustified(
  client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as JustifyPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('event-justified payload missing or not an object');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('event-justified payload missing idEquipment');
  }
  if (typeof payload.idEquipmentEvent !== 'number') {
    throw new Error('event-justified payload missing idEquipmentEvent');
  }

  const stagingEquipmentId = await translateEquipmentId(payload.idEquipment);
  const stagingEventId = await translateEquipmentEventId(
    BigInt(payload.idEquipmentEvent),
  );
  if (stagingEventId === undefined) {
    throw new Error(
      `equipment_event ${payload.idEquipmentEvent} unmapped (no business-key match within 5s window)`,
    );
  }

  // Cache the equipment_event mapping after the first business-key resolution
  // so future event-edited / event-splitted for the same event don't repeat
  // the lookup.
  await insertMapping(client, {
    entityType: 'equipment_event',
    source: config.sourceName,
    prodId: BigInt(payload.idEquipmentEvent),
    stagingId: stagingEventId,
    sourceLogId: BigInt(row.id_user_logs),
  });

  const body = {
    ...payload,
    idEquipment: stagingEquipmentId,
    idEquipmentEvent: Number(stagingEventId),
    idEnterprise: config.stagingEnterpriseId,
  };

  const url = `${config.stagingApi.baseUrl}/api/downtimes/justify`;
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
      `staging /api/downtimes/justify returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  log.info(
    {
      sourceLogId: row.id_user_logs,
      prodEventId: payload.idEquipmentEvent,
      stagingEventId: stagingEventId.toString(),
      status: res.status,
    },
    'replayed event-justified',
  );
}
