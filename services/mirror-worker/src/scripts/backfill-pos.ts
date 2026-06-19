// One-shot backfill: create staging POs matching prod CPACK's currently
// running set, then record the (prod_id, staging_id) mapping.
//
// Idempotent: re-runnable. Per prod PO:
//   1. mirror_id_map already has mapping → skip (done)
//   2. Staging already has a PO with same id_order + enterprise →
//      record mapping, skip create (recovers from a half-done prior run)
//   3. Otherwise → POST /api/production-orders/create-and-start on
//      staging, look up the new staging PO by (idEnterprise, idOrder),
//      record mapping
//
// Run via: `docker exec mirror-worker node dist/scripts/backfill-pos.js`
// On the staging EC2.

import axios from 'axios';
import { config } from '../config';
import { log } from '../log';
import { loadProdDbCreds } from '../secrets';
import { initProdPool, prodSelectMany } from '../db/prod';
import {
  fetchStagingApiToken,
  insertMapping,
  lookupMapping,
  stagingSelectOne,
  withStagingTx,
} from '../db/staging';
import { setStagingApiToken, getStagingApiToken } from '../runtime';
import {
  translateAreaId,
  translateEnterpriseId,
  translateEquipmentId,
  translateSiteId,
} from '../translate';

interface ProdPo {
  id_production_order: string; // bigint -> string
  id_order: number;
  id_enterprise: number;
  id_site: number;
  id_area: number;
  id_equipment: number;
  status: number;
  production_programmed: string; // bigint -> string
  ts_start: Date | null;
}

interface Stats {
  prodPos: number;
  alreadyMapped: number;
  rematched: number;
  created: number;
  skippedNoEquipment: number;
  skippedNoArea: number;
  skippedNoSite: number;
  errors: number;
}

async function fetchProdActivePos(): Promise<ProdPo[]> {
  // status=2 (running). 7-day window is generous; CPACK POs are typically
  // long-running so this catches everything an operator might still act on.
  // Use prodSelectMany rather than the json_agg trick so pg's native Date
  // type is preserved on ts_start (json_agg serialises it to a string).
  return prodSelectMany<ProdPo>(
    `SELECT id_production_order::text AS id_production_order,
            id_order,
            id_enterprise,
            id_site,
            id_area,
            id_equipment,
            status,
            production_programmed::text AS production_programmed,
            ts_start
       FROM production_orders
      WHERE id_enterprise = $1
        AND status = 2
        AND last_update > now() - interval '7 days'
      ORDER BY id_production_order`,
    [config.prodEnterpriseId],
  );
}

async function backfillOne(po: ProdPo, stats: Stats): Promise<void> {
  const prodPoId = BigInt(po.id_production_order);
  const sourceName = config.sourceName;

  // (1) Already mapped — nothing to do.
  const existing = await lookupMapping('production_order', sourceName, prodPoId);
  if (existing !== undefined) {
    stats.alreadyMapped += 1;
    log.info(
      { prodPoId: po.id_production_order, idOrder: po.id_order, stagingPoId: existing.toString() },
      'PO already mapped, skipping',
    );
    return;
  }

  // Translate the IDs the create-and-start DTO needs.
  let stagingEnterpriseId: number;
  let stagingSiteId: number;
  let stagingAreaId: number;
  let stagingEquipmentId: number;
  try {
    stagingEnterpriseId = translateEnterpriseId(po.id_enterprise);
  } catch (err) {
    stats.errors += 1;
    log.warn({ prodPoId: po.id_production_order, err: (err as Error).message }, 'enterprise translate failed');
    return;
  }
  try {
    stagingSiteId = await translateSiteId(po.id_site);
  } catch (err) {
    stats.skippedNoSite += 1;
    log.warn({ prodPoId: po.id_production_order, idSite: po.id_site, err: (err as Error).message }, 'site translate failed, skipping');
    return;
  }
  try {
    stagingAreaId = await translateAreaId(po.id_area);
  } catch (err) {
    stats.skippedNoArea += 1;
    log.warn({ prodPoId: po.id_production_order, idArea: po.id_area, err: (err as Error).message }, 'area translate failed, skipping');
    return;
  }
  try {
    stagingEquipmentId = await translateEquipmentId(po.id_equipment);
  } catch (err) {
    stats.skippedNoEquipment += 1;
    log.warn({ prodPoId: po.id_production_order, idEquipment: po.id_equipment, err: (err as Error).message }, 'equipment translate failed, skipping');
    return;
  }

  // (2) Already exists on staging by business key — recover without creating.
  const preexisting = await stagingSelectOne<{ id_production_order: string }>(
    `SELECT id_production_order::text
       FROM production_orders
      WHERE id_enterprise = $1
        AND id_order = $2
      ORDER BY id_production_order DESC
      LIMIT 1`,
    [stagingEnterpriseId, po.id_order],
  );
  if (preexisting) {
    stats.rematched += 1;
    const stagingPoId = BigInt(preexisting.id_production_order);
    await withStagingTx(async (client) => {
      await insertMapping(client, {
        entityType: 'production_order',
        source: sourceName,
        prodId: prodPoId,
        stagingId: stagingPoId,
        sourceLogId: 0n, // backfill — no source user_logs row
      });
    });
    log.info(
      { prodPoId: po.id_production_order, idOrder: po.id_order, stagingPoId: preexisting.id_production_order },
      'recovered existing staging PO mapping (no create needed)',
    );
    return;
  }

  // (3) Create-and-start on staging, then look up + map.
  //
  // ts_start = now - 5s (in the past to satisfy edge-api's "no future
  // timestamps" check, but recent enough to dodge getOrderDateConflict
  // against historical finished POs on this equipment). Prod's actual
  // ts_start would be more faithful but creates conflicts when staging
  // had prior test POs on the same equipment that covered prod's start
  // window — see Phase A6 dev notes.
  const tsStartIso = new Date(Date.now() - 5000).toISOString();
  const body = {
    idEnterprise: stagingEnterpriseId,
    idSite: stagingSiteId,
    idArea: stagingAreaId,
    idEquipment: stagingEquipmentId,
    idOrder: po.id_order,
    productionOrderQuantity: Number(po.production_programmed),
    timestamp: tsStartIso,
  };

  const res = await axios.post(
    `${config.stagingApi.baseUrl}/api/production-orders/create-and-start`,
    body,
    {
      params: { token: getStagingApiToken(), idEnterprise: stagingEnterpriseId },
      headers: { 'x-user': 'mirror-worker-backfill', 'X-Mirror-Source': sourceName },
      validateStatus: () => true,
      timeout: 20_000,
    },
  );
  if (res.status >= 400) {
    stats.errors += 1;
    log.error(
      { prodPoId: po.id_production_order, status: res.status, body: res.data },
      'create-and-start failed',
    );
    return;
  }

  // create-and-start returns 'Success!' — no body ID. Look up by business key.
  const created = await stagingSelectOne<{ id_production_order: string }>(
    `SELECT id_production_order::text
       FROM production_orders
      WHERE id_enterprise = $1
        AND id_order = $2
      ORDER BY id_production_order DESC
      LIMIT 1`,
    [stagingEnterpriseId, po.id_order],
  );
  if (!created) {
    stats.errors += 1;
    log.error(
      { prodPoId: po.id_production_order, idOrder: po.id_order },
      'create-and-start returned 2xx but no staging PO found by id_order',
    );
    return;
  }

  const stagingPoId = BigInt(created.id_production_order);
  await withStagingTx(async (client) => {
    await insertMapping(client, {
      entityType: 'production_order',
      source: sourceName,
      prodId: prodPoId,
      stagingId: stagingPoId,
      sourceLogId: 0n,
    });
  });
  stats.created += 1;
  log.info(
    {
      prodPoId: po.id_production_order,
      idOrder: po.id_order,
      stagingPoId: created.id_production_order,
      stagingEquipmentId,
    },
    'created staging PO + mapped',
  );
}

async function main(): Promise<void> {
  log.info({ sourceName: config.sourceName }, 'mirror-worker backfill starting');

  const creds = await loadProdDbCreds();
  initProdPool(creds);
  const token = await fetchStagingApiToken(config.stagingEnterpriseId);
  setStagingApiToken(token);

  const pos = await fetchProdActivePos();
  log.info({ count: pos.length }, 'prod active POs to evaluate');

  const stats: Stats = {
    prodPos: pos.length,
    alreadyMapped: 0,
    rematched: 0,
    created: 0,
    skippedNoEquipment: 0,
    skippedNoArea: 0,
    skippedNoSite: 0,
    errors: 0,
  };

  for (const po of pos) {
    try {
      await backfillOne(po, stats);
    } catch (err) {
      stats.errors += 1;
      log.error(
        { prodPoId: po.id_production_order, err: (err as Error).message },
        'backfill row failed with uncaught error',
      );
    }
    // Small pacing delay — staging edge-api is small, no need to hammer it.
    await new Promise((r) => setTimeout(r, 100));
  }

  log.info({ stats }, 'backfill done');
  // process.exit so the script terminates rather than hanging on the pool.
  process.exit(stats.errors > 0 ? 1 : 0);
}

main().catch((err) => {
  log.fatal({ err: (err as Error).message }, 'fatal error');
  process.exit(2);
});
