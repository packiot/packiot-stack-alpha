import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';

/**
 * Playwright globalSetup — self-heal the sandbox twin (ent 2000003) BEFORE the
 * mutating suite runs, so every `npm run test:sandbox` starts from a clean,
 * reproducible ent-3 reflection no matter how a prior run messed it up.
 *
 * Only wired in when E2E_SELFHEAL is set (see playwright.config.ts), so the
 * default read-only suite never triggers an SSM reset. Delegates to the single
 * source of truth: scripts/provision-sandbox-tenant.sh --heal (config re-clone
 * from ent 3 + transactional test-data wipe). Requires AWS creds with SSM access
 * on the runner (same as the nightly cron).
 *
 * Set E2E_SELFHEAL_SKIP=1 to keep the flag on (projects still run) but skip the
 * actual reset — useful when iterating on the tests themselves.
 */
export default async function globalSetup() {
  if (process.env.E2E_SELFHEAL_SKIP) {
    console.log('[sandbox self-heal] skipped (E2E_SELFHEAL_SKIP set)');
    return;
  }
  const script = resolve(__dirname, '../scripts/provision-sandbox-tenant.sh');
  console.log('[sandbox self-heal] running provision-sandbox-tenant.sh --heal …');
  try {
    const out = execFileSync('bash', [script, '--heal'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 600_000, // analytics reflection ~2-3 min (config + 14d events + all POs/manual events)
    });
    // Surface the parity + wipe status lines the script prints.
    out
      .split('\n')
      .filter((l) => /SANDBOX-CPACK|equipments|targets|pos_left|data wiped/.test(l))
      .forEach((l) => console.log('[sandbox self-heal]', l.trim()));
    console.log('[sandbox self-heal] done — twin reset to ent-3 reflection.');
  } catch (err: any) {
    console.error('[sandbox self-heal] FAILED — mutating tests may be non-reproducible.');
    console.error(err?.stdout?.toString?.() || err?.message || err);
    throw err; // fail fast: a non-reset sandbox invalidates the run's premise
  }
}
