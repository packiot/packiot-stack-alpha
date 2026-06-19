import axios from 'axios';
import { PoolClient } from 'pg';
import { config } from '../config';
import { log } from '../log';
import { ProdUserLog, prodSelectOne } from '../db/prod';
import { insertMapping } from '../db/staging';
import { getStagingApiToken } from '../runtime';
import { translateEquipmentEventId, translateEquipmentId } from '../translate';

// Prod payload shape captured from session 55 inspection:
//   {
//     idle, cdMachine, cdCategory, descCategory,
//     cdSubcategory, descSubcategory, changeOver, plannedDowntime,
//     idEquipment: <prod>,
//     idEquipmentEvent: <prod>,
//     txtDowntimeNotes
//   }
//
// Staging's edit-manual-event DTO requires `start` and `end` as NOT-NULL
// body fields (prod's older API accepts the payload without them — either
// the UI passes them as query params, or prod's controller defaults to
// existing-event boundaries). We derive start/end from the prod
// equipment_event row that translation already fetches, so the operator's
// intent — "keep the existing boundaries, just update metadata" — is
// preserved.
//
// Output: POST /api/downtimes/edit-manual-event
interface EditPayload {
  idle?: string;
  cdMachine?: string;
  cdCategory: string;
  descCategory: string;
  cdSubcategory?: string;
  descSubcategory?: string;
  changeOver?: boolean;
  plannedDowntime?: boolean;
  idEquipment: number;
  idEquipmentEvent: number;
  txtDowntimeNotes?: string;
}

export async function replayEventEdited(
  client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as EditPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('event-edited payload missing or not an object');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('event-edited payload missing idEquipment');
  }
  if (typeof payload.idEquipmentEvent !== 'number') {
    throw new Error('event-edited payload missing idEquipmentEvent');
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

  // Derive start/end from prod's row — preserves the operator's apparent
  // intent of "keep the existing boundaries, change metadata only". If
  // prod ever surfaces a payload variant with explicit start/end, prefer
  // those (none observed in the 24h sample for CPACK).
  const prodTimes = await prodSelectOne<{ ts_event: Date; ts_end: Date | null }>(
    `SELECT ts_event, ts_end
       FROM equipment_events
      WHERE id_equipment_event = $1 AND id_enterprise = $2`,
    [payload.idEquipmentEvent.toString(), config.prodEnterpriseId],
  );
  if (!prodTimes) {
    throw new Error(
      `prod equipment_event ${payload.idEquipmentEvent} disappeared between translation and replay`,
    );
  }
  const start = prodTimes.ts_event.toISOString();
  const end = (prodTimes.ts_end ?? new Date()).toISOString();

  // Cache the equipment_event mapping after the first business-key resolution
  // so future operations on the same prod event don't repeat the SELECT.
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
    start,
    end,
  };

  const url = `${config.stagingApi.baseUrl}/api/downtimes/edit-manual-event`;
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
      `staging /api/downtimes/edit-manual-event returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  log.info(
    {
      sourceLogId: row.id_user_logs,
      prodEventId: payload.idEquipmentEvent,
      stagingEventId: stagingEventId.toString(),
      status: res.status,
    },
    'replayed event-edited',
  );
}
