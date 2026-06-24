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

// order-status-changed advances a PO's status manually (e.g. operator marks a
// PO as finished without going through stop).
//
// Sample prod payload:
//   { idEquipment, idProductionOrder }
//
// Output: POST /api/production-orders/change-status (ChangeStatusProductionOrderDto)
//   { idProductionOrder, idEquipment }
interface OrderStatusChangedPayload {
  idEquipment: number;
  idProductionOrder: number;
}

export async function replayOrderStatusChanged(
  _client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as OrderStatusChangedPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('order-status-changed payload missing or not an object');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('order-status-changed payload missing idEquipment');
  }
  if (typeof payload.idProductionOrder !== 'number') {
    throw new Error('order-status-changed payload missing idProductionOrder');
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
    idProductionOrder: Number(stagingPoId),
    idEquipment: stagingEquipmentId,
  };

  const res = await axios.post(
    `${config.stagingApi.baseUrl}/api/production-orders/change-status`,
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
      `staging /api/production-orders/change-status returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  log.info(
    {
      sourceLogId: row.id_user_logs,
      prodPoId: payload.idProductionOrder,
      stagingPoId: stagingPoId.toString(),
      status: res.status,
    },
    'replayed order-status-changed',
  );
}
