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

// order-replaced replaces the current running PO on an equipment with a
// pre-existing one (different from create-and-start which makes a new PO).
//
// Sample prod payload:
//   { idEquipment, idEnterprise, equipmentSetup, unitMultiplier,
//     idProductionOrder (prod surrogate) }
//
// Output: POST /api/production-orders/replace (ReplaceProductionOrderDto)
//   { idEnterprise, idEquipment, idProductionOrder }
interface OrderReplacedPayload {
  idEquipment: number;
  idEnterprise: number;
  idProductionOrder: number;
}

export async function replayOrderReplaced(
  _client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as OrderReplacedPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('order-replaced payload missing or not an object');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('order-replaced payload missing idEquipment');
  }
  if (typeof payload.idProductionOrder !== 'number') {
    throw new Error('order-replaced payload missing idProductionOrder');
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
    idEnterprise: config.stagingEnterpriseId,
    idEquipment: stagingEquipmentId,
    idProductionOrder: Number(stagingPoId),
  };

  const res = await axios.post(
    `${config.stagingApi.baseUrl}/api/production-orders/replace`,
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
      `staging /api/production-orders/replace returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  log.info(
    {
      sourceLogId: row.id_user_logs,
      prodPoId: payload.idProductionOrder,
      stagingPoId: stagingPoId.toString(),
      status: res.status,
    },
    'replayed order-replaced',
  );
}
