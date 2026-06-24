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

// Equipment-event translation: cached mapping → interval-overlap business key.
//
// Phase A4b finding: prod and staging produce STRUCTURALLY DIFFERENT
// equipment_events from the same SparkPlug stream. Prod runs CPAC 5-min
// smoothing + writes operator metadata (cd_machine, cd_category) back into
// the row, so prod events are minute-aligned, fewer, and shorter. Staging
// has the raw PLC transitions — precise-to-the-second, more events, longer
// durations. Matching by ts_event proximity therefore can't work; matching
// by interval overlap can.
//
// For prod event `[t1, t2]` with status S on equipment E:
//   pick the staging event with same (E, S) whose interval `[s1, s2]`
//   has the largest overlap with [t1, t2], requiring at least
//   EVENT_MIN_OVERLAP_SEC of overlap to count as a match.
//
// Staging events without ts_end (still running) treat ts_end as now().
// The first match gets cached in mirror_id_map so subsequent operations
// (event-edited, event-splitted) on the same prod event skip the SELECT.
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
    ts_end: Date | null;
    status: number;
  }>(
    `SELECT id_equipment, ts_event, ts_end, status
       FROM equipment_events
      WHERE id_equipment_event = $1
        AND id_enterprise = $2`,
    [prodEventId.toString(), config.prodEnterpriseId],
  );
  if (!prodRow) return undefined;

  const stagingEquipmentId = await translateEquipmentId(prodRow.id_equipment);

  // Effective prod end: if the prod event is still ongoing (ts_end NULL),
  // cap at now(). Same on the staging side via COALESCE.
  const prodStartIso = prodRow.ts_event.toISOString();
  const prodEndIso = (prodRow.ts_end ?? new Date()).toISOString();

  const stagingRow = await stagingSelectOne<{
    id_equipment_event: string;
    overlap_seconds: number;
  }>(
    `SELECT id_equipment_event::text,
            extract(epoch FROM (
              LEAST(COALESCE(ts_end, now()), $4::timestamptz)
              - GREATEST(ts_event, $3::timestamptz)
            ))::int AS overlap_seconds
       FROM equipment_events
      WHERE id_equipment = $1
        AND id_enterprise = $2
        AND status = $5
        AND ts_event < $4::timestamptz
        AND (ts_end IS NULL OR ts_end > $3::timestamptz)
      ORDER BY overlap_seconds DESC
      LIMIT 1`,
    [
      stagingEquipmentId,
      config.stagingEnterpriseId,
      prodStartIso,
      prodEndIso,
      prodRow.status,
    ],
  );
  if (stagingRow && stagingRow.overlap_seconds >= config.eventMinOverlapSec) {
    log.debug(
      {
        prodEventId: prodEventId.toString(),
        stagingEventId: stagingRow.id_equipment_event,
        overlapSeconds: stagingRow.overlap_seconds,
      },
      'equipment_event interval-overlap match',
    );
    return BigInt(stagingRow.id_equipment_event);
  }

  // Diagnostic: closest same-status event on staging (by midpoint distance)
  // when no qualifying overlap. Lets us see whether the structural mismatch
  // is "no event at all in the area" or "events but with insufficient
  // overlap" — different fixes apply to each.
  const closest = await stagingSelectOne<{
    id_equipment_event: string;
    overlap_seconds: number;
    drift_seconds: number;
  }>(
    `WITH prod_range AS (
       SELECT $3::timestamptz AS p_start, $4::timestamptz AS p_end
     )
     SELECT id_equipment_event::text,
            extract(epoch FROM (
              LEAST(COALESCE(ts_end, now()), p_end)
              - GREATEST(ts_event, p_start)
            ))::int AS overlap_seconds,
            extract(epoch FROM abs(ts_event - p_start))::int AS drift_seconds
       FROM equipment_events, prod_range
      WHERE id_equipment = $1
        AND id_enterprise = $2
        AND status = $5
        AND ts_event BETWEEN p_start - interval '1 hour'
                         AND p_end   + interval '1 hour'
      ORDER BY drift_seconds ASC
      LIMIT 1`,
    [
      stagingEquipmentId,
      config.stagingEnterpriseId,
      prodStartIso,
      prodEndIso,
      prodRow.status,
    ],
  );
  log.warn(
    {
      prodEventId: prodEventId.toString(),
      stagingEquipmentId,
      prodStart: prodStartIso,
      prodEnd: prodEndIso,
      prodStatus: prodRow.status,
      minOverlapSec: config.eventMinOverlapSec,
      candidateOverlapSec: stagingRow?.overlap_seconds ?? null,
      closestDriftSec: closest?.drift_seconds ?? null,
      closestOverlapSec: closest?.overlap_seconds ?? null,
    },
    'no equipment_event interval-overlap match (closest same-status candidate noted)',
  );
  return undefined;
}
