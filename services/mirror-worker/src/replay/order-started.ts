import axios from 'axios';
import { PoolClient } from 'pg';
import { config } from '../config';
import { log } from '../log';
import { ProdUserLog } from '../db/prod';
import { getStagingApiToken } from '../runtime';
import {
  translateAreaId,
  translateEquipmentId,
  translateProductionOrderId,
  translateSiteId,
} from '../translate';

// Sample prod payload:
//   {
//     idArea, idSite, timestamp,
//     idEquipment, idEnterprise,
//     unitMultiplier,
//     idProductionOrder: <prod surrogate — needs translation>
//   }
//
// Output: POST /api/production-orders/start (StartProductionOrderDto)
//   { timestamp, idEnterprise, idSite, idArea, idEquipment, idProductionOrder }
interface OrderStartedPayload {
  idArea: number;
  idSite: number;
  timestamp: string;
  idEquipment: number;
  idEnterprise: number;
  idProductionOrder: number;
}

export async function replayOrderStarted(
  _client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as OrderStartedPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('order-started payload missing or not an object');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('order-started payload missing idEquipment');
  }
  if (typeof payload.idProductionOrder !== 'number') {
    throw new Error('order-started payload missing idProductionOrder');
  }

  const stagingEquipmentId = await translateEquipmentId(payload.idEquipment);
  const stagingSiteId = await translateSiteId(payload.idSite);
  const stagingAreaId = await translateAreaId(payload.idArea);
  const stagingPoId = await translateProductionOrderId(
    BigInt(payload.idProductionOrder),
  );
  if (stagingPoId === undefined) {
    throw new Error(
      `production_order ${payload.idProductionOrder} unmapped (run backfill-pos or replay order-created/order-created-started first)`,
    );
  }

  const body = {
    timestamp: payload.timestamp,
    idEnterprise: config.stagingEnterpriseId,
    idSite: stagingSiteId,
    idArea: stagingAreaId,
    idEquipment: stagingEquipmentId,
    idProductionOrder: Number(stagingPoId),
  };

  const res = await axios.post(
    `${config.stagingApi.baseUrl}/api/production-orders/start`,
    body,
    {
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
    },
  );

  if (res.status >= 400) {
    throw new Error(
      `staging /api/production-orders/start returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  log.info(
    {
      sourceLogId: row.id_user_logs,
      prodPoId: payload.idProductionOrder,
      stagingPoId: stagingPoId.toString(),
      status: res.status,
    },
    'replayed order-started',
  );
}
