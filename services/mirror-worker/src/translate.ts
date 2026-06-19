import { config } from './config';
import { prodSelectOne } from './db/prod';
import { lookupMapping, stagingSelectOne } from './db/staging';
import { log } from './log';

// CPACK SparkPlug topics are remapped during the AMQP mirror (Step 4 of the
// real-client-data initiative): every leading `C-PACK/` becomes `CPACK/` on
// staging so the topic namespace doesn't collide with prod literals. The
// equipment translator follows the same convention.
export function remapTopic(prodTopic: string): string {
  return prodTopic.replace(/^C-PACK\//, 'CPACK/');
}

// Enterprise and site are hardcoded: CPACK is id 1 on prod, 3 on staging, and
// has a single site. Bake the map here rather than do an extra lookup per call.
export function translateEnterpriseId(prodId: number): number {
  if (prodId !== config.prodEnterpriseId) {
    throw new Error(
      `unexpected prod enterprise ${prodId}, only ${config.prodEnterpriseId} is mirrored`,
    );
  }
  return config.stagingEnterpriseId;
}

export async function translateEquipmentId(
  prodEquipmentId: number,
): Promise<number> {
  // Resolve prod's equipment to its SparkPlug topic, remap to staging-space,
  // and re-resolve via staging packml_register. This is the business-key path
  // — both sides share `packml_topic` as the stable identifier.
  const prodRow = await prodSelectOne<{ packml_topic: string }>(
    `SELECT pr.packml_topic
       FROM packml_register pr
      WHERE pr.id_equipment = $1
        AND pr.id_enterprise = $2
      ORDER BY pr.active DESC NULLS LAST
      LIMIT 1`,
    [prodEquipmentId, config.prodEnterpriseId],
  );
  if (!prodRow) {
    throw new Error(
      `no prod packml_register row for id_equipment=${prodEquipmentId}`,
    );
  }
  const stagingTopic = remapTopic(prodRow.packml_topic);
  const stagingRow = await stagingSelectOne<{ id_equipment: number }>(
    `SELECT id_equipment
       FROM packml_register
      WHERE packml_topic = $1
        AND id_enterprise = $2
      ORDER BY active DESC NULLS LAST
      LIMIT 1`,
    [stagingTopic, config.stagingEnterpriseId],
  );
  if (!stagingRow) {
    throw new Error(
      `no staging packml_register row for topic=${stagingTopic} (remapped from ${prodRow.packml_topic})`,
    );
  }
  return stagingRow.id_equipment;
}

export async function translateAreaId(prodAreaId: number): Promise<number> {
  const prodRow = await prodSelectOne<{ nm_area: string }>(
    `SELECT nm_area FROM areas WHERE id_area = $1 AND id_enterprise = $2`,
    [prodAreaId, config.prodEnterpriseId],
  );
  if (!prodRow) {
    throw new Error(`no prod area row for id_area=${prodAreaId}`);
  }
  const stagingRow = await stagingSelectOne<{ id_area: number }>(
    `SELECT id_area FROM areas WHERE nm_area = $1 AND id_enterprise = $2`,
    [prodRow.nm_area, config.stagingEnterpriseId],
  );
  if (!stagingRow) {
    throw new Error(
      `no staging area with nm_area=${prodRow.nm_area} for enterprise ${config.stagingEnterpriseId}`,
    );
  }
  return stagingRow.id_area;
}

export async function translateSiteId(prodSiteId: number): Promise<number> {
  const prodRow = await prodSelectOne<{ nm_site: string }>(
    `SELECT nm_site FROM sites WHERE id_site = $1 AND id_enterprise = $2`,
    [prodSiteId, config.prodEnterpriseId],
  );
  if (!prodRow) {
    throw new Error(`no prod site row for id_site=${prodSiteId}`);
  }
  const stagingRow = await stagingSelectOne<{ id_site: number }>(
    `SELECT id_site FROM sites WHERE nm_site = $1 AND id_enterprise = $2`,
    [prodRow.nm_site, config.stagingEnterpriseId],
  );
  if (!stagingRow) {
    throw new Error(
      `no staging site with nm_site=${prodRow.nm_site} for enterprise ${config.stagingEnterpriseId}`,
    );
  }
  return stagingRow.id_site;
}

// Production-order translation prefers the cached mapping; falls back to a
// business-key (nu_production_order + enterprise) match for entities created
// before the worker started — those mappings get cached on first hit.
export async function translateProductionOrderId(
  prodPoId: bigint,
): Promise<bigint | undefined> {
  const mapped = await lookupMapping(
    'production_order',
    config.sourceName,
    prodPoId,
  );
  if (mapped !== undefined) return mapped;

  const prodRow = await prodSelectOne<{ nu_production_order: string }>(
    `SELECT nu_production_order::text
       FROM production_orders
      WHERE id_production_order = $1
        AND id_enterprise = $2`,
    [prodPoId.toString(), config.prodEnterpriseId],
  );
  if (!prodRow) return undefined;

  const stagingRow = await stagingSelectOne<{ id_production_order: string }>(
    `SELECT id_production_order::text
       FROM production_orders
      WHERE nu_production_order = $1
        AND id_enterprise = $2
      ORDER BY id_production_order DESC
      LIMIT 1`,
    [prodRow.nu_production_order, config.stagingEnterpriseId],
  );
  return stagingRow ? BigInt(stagingRow.id_production_order) : undefined;
}

// Equipment-event translation: cached mapping → business key
// (id_equipment + ts_event + status), recorded into mirror_id_map on first
// hit so subsequent justify/edit operations don't repeat the SELECT.
export async function translateEquipmentEventId(
  prodEventId: bigint,
): Promise<bigint | undefined> {
  const mapped = await lookupMapping(
    'equipment_event',
    config.sourceName,
    prodEventId,
  );
  if (mapped !== undefined) return mapped;

  const prodRow = await prodSelectOne<{
    id_equipment: number;
    ts_event: Date;
    status: number;
  }>(
    `SELECT id_equipment, ts_event, status
       FROM equipment_events
      WHERE id_equipment_event = $1
        AND id_enterprise = $2`,
    [prodEventId.toString(), config.prodEnterpriseId],
  );
  if (!prodRow) return undefined;

  const stagingEquipmentId = await translateEquipmentId(prodRow.id_equipment);

  // Match on (id_equipment, status, ts_event ± window). Prod aggregates some
  // events to round-minute marks (CPAC 5-min algorithm) while staging carries
  // the raw transition timestamp — empirical drift is ~1 minute, so we accept
  // a wider window than the obvious "few seconds" guess. status as a hard
  // filter is the dedup safety net when two events land close.
  const stagingRow = await stagingSelectOne<{
    id_equipment_event: string;
    drift_seconds: number;
  }>(
    `SELECT id_equipment_event::text,
            abs(extract(epoch FROM (ts_event - $4::timestamptz)))::int AS drift_seconds
       FROM equipment_events
      WHERE id_equipment = $1
        AND id_enterprise = $2
        AND status = $3
        AND ts_event BETWEEN $4::timestamptz - ($5 || ' seconds')::interval
                         AND $4::timestamptz + ($5 || ' seconds')::interval
      ORDER BY abs(extract(epoch FROM (ts_event - $4::timestamptz))) ASC
      LIMIT 1`,
    [
      stagingEquipmentId,
      config.stagingEnterpriseId,
      prodRow.status,
      prodRow.ts_event.toISOString(),
      config.eventMatchWindowSec,
    ],
  );
  if (stagingRow) {
    log.debug(
      {
        prodEventId: prodEventId.toString(),
        stagingEventId: stagingRow.id_equipment_event,
        driftSeconds: stagingRow.drift_seconds,
      },
      'equipment_event business-key match',
    );
    return BigInt(stagingRow.id_equipment_event);
  }

  // Diagnostic: how far off is the closest same-equipment same-status event?
  // Helps us catch calibration drift early without sifting through DLQ payloads.
  const closest = await stagingSelectOne<{ drift_seconds: number }>(
    `SELECT abs(extract(epoch FROM (ts_event - $3::timestamptz)))::int AS drift_seconds
       FROM equipment_events
      WHERE id_equipment = $1
        AND id_enterprise = $2
        AND status = $4
        AND ts_event BETWEEN $3::timestamptz - interval '1 hour'
                         AND $3::timestamptz + interval '1 hour'
      ORDER BY abs(extract(epoch FROM (ts_event - $3::timestamptz))) ASC
      LIMIT 1`,
    [
      stagingEquipmentId,
      config.stagingEnterpriseId,
      prodRow.ts_event.toISOString(),
      prodRow.status,
    ],
  );
  log.warn(
    {
      prodEventId: prodEventId.toString(),
      stagingEquipmentId,
      prodTs: prodRow.ts_event.toISOString(),
      prodStatus: prodRow.status,
      windowSec: config.eventMatchWindowSec,
      closestDriftSeconds: closest?.drift_seconds ?? null,
    },
    'no equipment_event business-key match (closest same-status candidate noted)',
  );
  return undefined;
}
