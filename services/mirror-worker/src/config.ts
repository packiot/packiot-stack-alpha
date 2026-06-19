function reqEnv(name: string): string {
  const v = process.env[name];
  if (!v || v.length === 0) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return v;
}

function optInt(name: string, fallback: number): number {
  const v = process.env[name];
  if (!v) return fallback;
  const n = Number.parseInt(v, 10);
  if (Number.isNaN(n)) {
    throw new Error(`Env var ${name} must be an integer, got: ${v}`);
  }
  return n;
}

export const config = {
  // Polling cadence and batch sizing.
  pollIntervalSec: optInt('POLL_INTERVAL_SEC', 60),
  batchSize: optInt('BATCH_SIZE', 50),
  perPostDelayMs: optInt('PER_POST_DELAY_MS', 50),

  // Source identity — embedded in DLQ / cursor / mirror_id_map rows.
  sourceName: process.env.SOURCE_NAME ?? 'cpack-prod',
  prodEnterpriseId: optInt('PROD_ENTERPRISE_ID', 1),
  stagingEnterpriseId: optInt('STAGING_ENTERPRISE_ID', 3),

  // ts_event drift between prod and staging on the equipment_event business
  // key match. Empirically ~60s because prod rolls some events up to
  // round-minute boundaries (CPAC 5-min aggregation start times) while
  // staging keeps the raw PLC transition time. 90s leaves headroom; widen
  // further only if monitoring shows persistent misses.
  eventMatchWindowSec: optInt('EVENT_MATCH_WINDOW_SEC', 90),

  // Prod DB — creds resolved from Secrets Manager at startup.
  awsRegion: process.env.AWS_REGION ?? 'us-east-1',
  prodDbSecretId: process.env.PROD_DB_SECRET_ID ?? 'databaseCredentials',

  // Staging DB — routed through pgbouncer in compose.
  stagingDb: {
    host: process.env.STAGING_DB_HOST ?? 'pgbouncer',
    port: optInt('STAGING_DB_PORT', 5432),
    user: reqEnv('STAGING_DB_USER'),
    password: reqEnv('STAGING_DB_PASSWORD'),
    database: reqEnv('STAGING_DB_NAME'),
  },

  // Staging edge-api — reached on the packiot-net docker network, bypassing
  // the host nginx. `?token=` auth still applies via edge-api AuthMiddleware.
  // The token is the api_key of the staging mirrored enterprise; it's resolved
  // from the DB at startup (see fetchStagingApiToken) so rotations don't need
  // a redeploy.
  stagingApi: {
    baseUrl: process.env.STAGING_API_URL ?? 'http://edge-api:8080',
  },
};

export type Config = typeof config;
