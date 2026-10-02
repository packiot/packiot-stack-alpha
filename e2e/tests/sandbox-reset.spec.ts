import { test, expect, APIRequestContext } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { csadminLogin } from '../fixtures/auth';

/**
 * Sandbox RESET guarantee — runs AFTER every mutating sandbox project (playwright
 * `dependencies`). Re-heals the twin (--reset-data → ops.sandbox_reflect on the
 * analytics plane) and proves the mutations those suites made are gone:
 *   * operator justify / split  → last-3-days downtimes identical to CPACK again
 *   * operator PO create        → recent PO list identical to CPACK again
 *   * csadmin area CRUD         → no E2E-* area left
 *   * csadmin downtime reasons  → the E2E category is gone
 * Skipped unless E2E_SELFHEAL is set (i.e. only under `npm run test:sandbox`).
 */
const REFDATA = process.env.REFDATA_URL || 'https://refdata.staging.packiot.app';
const KEY_CPACK = process.env.REFDATA_KEY_CPACK || 'stg-cpack-key';
const KEY_SBX = process.env.REFDATA_KEY_SBX || 'stg-sbxcpack-key';
const USER = process.env.CSADMIN_USER || '';
const PASS = process.env.CSADMIN_PASSWORD || '';

async function dataset(request: APIRequestContext, key: string, body: object) {
  const r = await request.post(`${REFDATA}/v1/query`, {
    headers: { 'X-Api-Key': key, 'Content-Type': 'application/json' },
    data: body,
    timeout: 60_000,
  });
  expect(r.status()).toBe(200);
  return (await r.json()) as any[];
}

test.describe.serial('sandbox reset guarantee', () => {
  test.describe.configure({ timeout: 150_000 });
  test.skip(!process.env.E2E_SELFHEAL || !!process.env.E2E_SELFHEAL_SKIP, 'reset runs only under npm run test:sandbox');

  test('re-heal the twin (analytics reflection)', async () => {
    test.setTimeout(660_000);
    // FORCED: the suite's own mutations just put the twin on hold (t-sandbox-grace-hold), so a
    // plain reset would be refused. The suite-START heal (global-setup) stays unforced on
    // purpose — if a person is mid-session there, the suite stops instead of wiping their work.
    const out = execFileSync('bash', [resolve(__dirname, '../../scripts/provision-sandbox-tenant.sh'), '--reset-data'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 600_000,
      env: { ...process.env, SANDBOX_HEAL_FORCE: '1' },
    });
    expect(out).toMatch(/SANDBOX analytics reflected/);
  });

  test('downtimes are identical to CPACK again (justify/split undone)', async ({ request }) => {
    const to = new Date(Date.now() - 30 * 60_000);
    const from = new Date(to.getTime() - 3 * 86_400_000);
    const body = { dataset: 'downtimes-events', window: { from: from.toISOString(), to: to.toISOString() } };
    const [c, s] = await Promise.all([dataset(request, KEY_CPACK, body), dataset(request, KEY_SBX, body)]);
    // What justify/split change is the CLASSIFICATION (category, sub-category) and the row set
    // (split adds rows) — compared EXACTLY for every event. The only tolerated difference is the
    // live edge: the reader returns events up to "now" (window shifted by day_begin), where a stop
    // that just opened/closed in CPACK reaches the twin on its own pipeline minutes later (measured
    // 2026-09-30: converged within ~10 min). So: just-opened events (null duration, within 30 min of
    // the newest) are excused from the row set, and durations are compared once settled (> 1 h).
    const newest = Math.max(...[...c, ...s].map((r) => Date.parse(r.ts_event)));
    const justOpened = (r: any) => r.duration == null && Date.parse(r.ts_event) >= newest - 30 * 60_000;
    const cls = (rows: any[]) =>
      rows.filter((r) => !justOpened(r))
        .map((r) => `${r.ts_event}|${r.cd_category ?? ''}|${r.cd_subcategory ?? ''}|${r.manual_event}`).sort();
    expect(cls(s), 'classification + row set (justify/split undone)').toEqual(cls(c));
    const settledDur = (rows: any[]) =>
      rows.filter((r) => r.duration != null && Date.parse(r.ts_event) < newest - 3_600_000)
        .map((r) => `${r.ts_event}|${r.duration}|${r.cd_category ?? ''}`).sort();
    expect(settledDur(s), 'settled durations').toEqual(settledDur(c));
  });

  test('production orders are identical to CPACK again (test POs gone)', async ({ request }) => {
    const to = new Date();
    const from = new Date(to.getTime() - 30 * 86_400_000);
    const body = { dataset: 'production-orders-with-runtimes', window: { from: from.toISOString(), to: to.toISOString() } };
    const [c, s] = await Promise.all([dataset(request, KEY_CPACK, body), dataset(request, KEY_SBX, body)]);
    const orders = (rows: any[]) => rows.map((r) => String(r.id_order)).sort().join(',');
    expect(orders(s)).toBe(orders(c));
  });

  test('csadmin: no E2E area and no E2E downtime category remain', async ({ page, baseURL }) => {
    test.skip(!USER || !PASS, 'CSADMIN creds not set');
    await csadminLogin(page, USER, PASS);
    await page.getByText(/SANDBOX-CPACK/i).first().click();
    await page.waitForTimeout(1500);
    await page.goto(baseURL! + '/app/area');
    await expect(page.getByText('LINHAS', { exact: true }).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.getByText(/^E2E-AREA/)).toHaveCount(0);
    await page.goto(baseURL! + '/app/downtime-reasons');
    await page.waitForTimeout(1500);
    // the SAME equipment the csadmin reasons test wrote E2E_DTR to: the first LINE (CPACK keeps
    // reason trees on lines; machines are empty — t-cpack-reason-catalog)
    const picker = page.locator('select').first();
    const lineLabel = (await picker.locator('option').allInnerTexts()).find((t) => /\(line\)/i.test(t));
    expect(lineLabel, 'a line is listed in the equipment picker').toBeTruthy();
    await picker.selectOption({ label: lineLabel! });
    await expect(page.getByPlaceholder('Category code').first()).toBeVisible({ timeout: 15_000 });
    const codes = await page.getByPlaceholder('Category code').evaluateAll((els) => els.map((e) => (e as HTMLInputElement).value));
    expect(codes).not.toContain('E2E_DTR');
  });
});
