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

// Prod payload shape captured from session 55 inspection:
//   {
//     idArea, idSite,
//     idOrder: <string biz key>,
//     stopType: 'pause' | 'finish',
//     timestamp: ISO,
//     idEquipment: <prod>,
//     idEnterprise: <prod>,
//     equipmentSetup: [{ id, position }],
//     shouldCreatePo, shouldOpenNewPo, unitMultiplier,
//     idProductionOrder: <string biz key, same as idOrder>,
//     oldIdProductionOrder: <prod surrogate — needs translation>,
//     productionOrderQuantity: <string>,
//     oldProductionOrderProdFinal
//   }
//
// Translation:
//   idEquipment            -> via packml_topic
//   oldIdProductionOrder   -> via mirror_id_map (entity_type='production_order')
//                             populated by Phase A6 backfill for pre-existing
//                             prod POs and by future order-created-started
//                             replays for any new ones
//
// Output: POST /api/production-orders/stop with the StopProductionOrderDto
// shape (timestamp, stopType, idEnterprise, idEquipment, idProductionOrder,
// productionOrderQuantity). Extra fields the operator sent that don't appear
// in the Stop DTO are ignored on staging — class-validator doesn't reject
// non-whitelisted fields by default.
interface OrderChangedPayload {
  stopType: string;
  timestamp: string;
  idEquipment: number;
  idEnterprise: number;
  oldIdProductionOrder: number;
  productionOrderQuantity: number | string;
}

export async function replayOrderChanged(
  _client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as OrderChangedPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('order-changed payload missing or not an object');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('order-changed payload missing idEquipment');
  }
  if (typeof payload.oldIdProductionOrder !== 'number') {
    throw new Error('order-changed payload missing oldIdProductionOrder');
  }
  if (!payload.stopType) {
    throw new Error('order-changed payload missing stopType');
  }

  const stagingEquipmentId = await translateEquipmentId(payload.idEquipment);
  const stagingPoId = await translateProductionOrderId(
    BigInt(payload.oldIdProductionOrder),
  );
  if (stagingPoId === undefined) {
    throw new Error(
      `production_order ${payload.oldIdProductionOrder} unmapped (no mirror_id_map row and no nu_production_order business-key match — run backfill-pos for currently-running prod POs)`,
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

  const url = `${config.stagingApi.baseUrl}/api/production-orders/stop`;
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
      `staging /api/production-orders/stop returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  log.info(
    {
      sourceLogId: row.id_user_logs,
      prodPoId: payload.oldIdProductionOrder,
      stagingPoId: stagingPoId.toString(),
      stopType: payload.stopType,
      status: res.status,
    },
    'replayed order-changed',
  );
}
