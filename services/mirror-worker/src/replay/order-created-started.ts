import axios from 'axios';
import { PoolClient } from 'pg';
import { config } from '../config';
import { log } from '../log';
import { ProdUserLog, prodSelectOne } from '../db/prod';
import {
  insertMapping,
  lookupMapping,
  stagingSelectOne,
  withStagingTx,
} from '../db/staging';
import { getStagingApiToken } from '../runtime';
import {
  translateAreaId,
  translateEquipmentId,
  translateSiteId,
} from '../translate';

// order-created-started is the operator's "create + start in one shot" flow.
// This is the most important replay handler for closing Gap 1 — without it,
// new POs created via the operator's New PO button never appear on staging
// until the manual backfill script runs.
//
// Sample prod payload:
//   {
//     idArea, idSite,
//     idOrder, timestamp,
//     idEquipment, idEnterprise,
//     equipmentSetup: [{id, position}, ...],
//     unitMultiplier,
//     productionOrderQuantity
//   }
//
// Output: POST /api/production-orders/create-and-start (CreateAndStartDto)
//   { idEnterprise, idSite, idArea, idEquipment, idOrder,
//     productionOrderQuantity, timestamp }
//
// We use the prod timestamp directly. This may collide with historical
// finished POs on the same equipment via getOrderDateConflict — but it
// preserves prod-faithful ts_start. The backfill script uses now-5s as
// a workaround for that specific case; for real-time replays of fresh
// prod actions, prod's timestamp is the right value.
interface OrderCreatedStartedPayload {
  idArea: number;
  idSite: number;
  idOrder: number | string;
  timestamp: string;
  idEquipment: number;
  idEnterprise: number;
  productionOrderQuantity: number | string;
}

export async function replayOrderCreatedStarted(
  _client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as OrderCreatedStartedPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('order-created-started payload missing or not an object');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('order-created-started payload missing idEquipment');
  }
  if (payload.idOrder === undefined || payload.idOrder === null) {
    throw new Error('order-created-started payload missing idOrder');
  }

  const idOrderNum = Number(payload.idOrder);

  const stagingEquipmentId = await translateEquipmentId(payload.idEquipment);
  const stagingSiteId = await translateSiteId(payload.idSite);
  const stagingAreaId = await translateAreaId(payload.idArea);

  const prodPoRow = await prodSelectOne<{ id_production_order: string }>(
    `SELECT id_production_order::text
       FROM production_orders
      WHERE id_enterprise = $1 AND id_order = $2
      ORDER BY id_production_order DESC LIMIT 1`,
    [config.prodEnterpriseId, idOrderNum],
  );
  if (!prodPoRow) {
    throw new Error(
      `no prod production_order found for idEnterprise=${config.prodEnterpriseId} idOrder=${idOrderNum}`,
    );
  }
  const prodPoId = BigInt(prodPoRow.id_production_order);

  const existing = await lookupMapping('production_order', config.sourceName, prodPoId);
  if (existing !== undefined) {
    log.info(
      { sourceLogId: row.id_user_logs, prodPoId: prodPoId.toString(), stagingPoId: existing.toString() },
      'order-created-started already mapped, skipping',
    );
    return;
  }

  const body = {
    idEnterprise: config.stagingEnterpriseId,
    idSite: stagingSiteId,
    idArea: stagingAreaId,
    idEquipment: stagingEquipmentId,
    idOrder: idOrderNum,
    productionOrderQuantity: Number(payload.productionOrderQuantity),
    timestamp: payload.timestamp,
  };

  const res = await axios.post(
    `${config.stagingApi.baseUrl}/api/production-orders/create-and-start`,
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
      `staging /api/production-orders/create-and-start returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  const created = await stagingSelectOne<{ id_production_order: string }>(
    `SELECT id_production_order::text
       FROM production_orders
      WHERE id_enterprise = $1 AND id_order = $2
      ORDER BY id_production_order DESC LIMIT 1`,
    [config.stagingEnterpriseId, idOrderNum],
  );
  if (!created) {
    throw new Error(
      `create-and-start returned ${res.status} but staging PO with idOrder=${idOrderNum} not found`,
    );
  }
  const stagingPoId = BigInt(created.id_production_order);
  await withStagingTx(async (c) => {
    await insertMapping(c, {
      entityType: 'production_order',
      source: config.sourceName,
      prodId: prodPoId,
      stagingId: stagingPoId,
      sourceLogId: BigInt(row.id_user_logs),
    });
  });

  log.info(
    {
      sourceLogId: row.id_user_logs,
      prodPoId: prodPoId.toString(),
      stagingPoId: stagingPoId.toString(),
      idOrder: idOrderNum,
      status: res.status,
    },
    'replayed order-created-started',
  );
}
