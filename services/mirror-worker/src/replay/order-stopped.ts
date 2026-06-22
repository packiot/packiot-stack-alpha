import axios from 'axios';
import { PoolClient } from 'pg';
import { config } from '../config';
import { log } from '../log';
import { ProdUserLog } from '../db/prod';
import { getStagingApiToken } from '../runtime';
import {
  translateEquipmentId,
  translateProductionOrderId,
} from '../translate';

// order-stopped is the explicit stop endpoint (separate from order-changed,
// which is the setup endpoint that also writes a stop semantically). Expected
// payload mirrors StopProductionOrderDto.
//
// Output: POST /api/production-orders/stop
interface OrderStoppedPayload {
  timestamp: string;
  stopType: string;
  idEquipment: number;
  idEnterprise: number;
  idProductionOrder: number;
  productionOrderQuantity: number | string;
}

export async function replayOrderStopped(
  _client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as OrderStoppedPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('order-stopped payload missing or not an object');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('order-stopped payload missing idEquipment');
  }
  if (typeof payload.idProductionOrder !== 'number') {
    throw new Error('order-stopped payload missing idProductionOrder');
  }

  const stagingEquipmentId = await translateEquipmentId(payload.idEquipment);
  const stagingPoId = await translateProductionOrderId(
    BigInt(payload.idProductionOrder),
  );
  if (stagingPoId === undefined) {
    throw new Error(
      `production_order ${payload.idProductionOrder} unmapped`,
    );
  }

  const body = {
    timestamp: payload.timestamp,
    stopType: payload.stopType,
    idEnterprise: config.stagingEnterpriseId,
    idEquipment: stagingEquipmentId,
    idProductionOrder: Number(stagingPoId),
    productionOrderQuantity: Number(payload.productionOrderQuantity),
  };

  const res = await axios.post(
    `${config.stagingApi.baseUrl}/api/production-orders/stop`,
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
      `staging /api/production-orders/stop returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  log.info(
    {
      sourceLogId: row.id_user_logs,
      prodPoId: payload.idProductionOrder,
      stagingPoId: stagingPoId.toString(),
      stopType: payload.stopType,
      status: res.status,
    },
    'replayed order-stopped',
  );
}
