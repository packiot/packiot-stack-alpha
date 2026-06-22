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

// order-created creates a PO without starting it (status stays as 1=available).
// Used by CS Admin / frontend when batching multiple POs ahead of time.
//
// Sample prod payload:
//   {
//     idArea, idSite,
//     idOrder: "<biz key>",
//     idEquipment, idEnterprise,
//     equipmentSetup: [{ id, position }],
//     unitMultiplier,
//     productionOrderQuantity: "<number-as-string>"
//   }
//
// Output: POST /api/production-orders/create (CreateProductionOrderDto)
//   { idEnterprise, idSite, idArea, idEquipment, idOrder, productionOrderQuantity }
//
// Idempotency: payload doesn't carry prod's id_production_order, so we resolve
// it after the fact by querying prod for the PO matching (idEnterprise, idOrder)
// created around row.ts_event. If mapping already exists, skip.
interface OrderCreatedPayload {
  idArea: number;
  idSite: number;
  idOrder: number | string;
  idEquipment: number;
  idEnterprise: number;
  productionOrderQuantity: number | string;
}

export async function replayOrderCreated(
  _client: PoolClient,
  row: ProdUserLog,
): Promise<void> {
  const payload = row.payload as OrderCreatedPayload;
  if (!payload || typeof payload !== 'object') {
    throw new Error('order-created payload missing or not an object');
  }
  if (typeof payload.idEquipment !== 'number') {
    throw new Error('order-created payload missing idEquipment');
  }
  if (payload.idOrder === undefined || payload.idOrder === null) {
    throw new Error('order-created payload missing idOrder');
  }

  const idOrderNum = Number(payload.idOrder);

  const stagingEquipmentId = await translateEquipmentId(payload.idEquipment);
  const stagingSiteId = await translateSiteId(payload.idSite);
  const stagingAreaId = await translateAreaId(payload.idArea);

  // Resolve prod's surrogate id_production_order for this row so we can map it.
  // The user_logs row was written right after edge-api created the PO, so the
  // most recent prod PO matching (id_enterprise, id_order) is ours.
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

  // Already mapped? Skip (idempotent re-run).
  const existing = await lookupMapping('production_order', config.sourceName, prodPoId);
  if (existing !== undefined) {
    log.info(
      { sourceLogId: row.id_user_logs, prodPoId: prodPoId.toString(), stagingPoId: existing.toString() },
      'order-created already mapped, skipping',
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
  };

  const res = await axios.post(
    `${config.stagingApi.baseUrl}/api/production-orders/create`,
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
      `staging /api/production-orders/create returned ${res.status}: ${JSON.stringify(res.data)}`,
    );
  }

  // Look up the new staging PO by business key and record mapping.
  const created = await stagingSelectOne<{ id_production_order: string }>(
    `SELECT id_production_order::text
       FROM production_orders
      WHERE id_enterprise = $1 AND id_order = $2
      ORDER BY id_production_order DESC LIMIT 1`,
    [config.stagingEnterpriseId, idOrderNum],
  );
  if (!created) {
    throw new Error(
      `create returned ${res.status} but staging PO with idOrder=${idOrderNum} not found`,
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
    'replayed order-created',
  );
}
