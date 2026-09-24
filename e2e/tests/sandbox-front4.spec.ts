import { test, expect, APIRequestContext } from '@playwright/test';
import { front4Login } from '../fixtures/auth';

/**
 * Sandbox front4 (ent 2000003) — the sandbox must be a faithful REFLECTION of CPACK
 * staging (ent 3), history included (db/migrations/t-sandbox-reflection).
 *
 *  1. UI: the sandbox QA user (identity.users → ent 2000003) sees real data on the
 *     product pages.
 *  2. PARITY through the REAL read-api (/v1/query, the exact path front4 uses): the same
 *     dataset + window answered for the sandbox key and the CPACK key must match —
 *     including a 2023 window (history reflection) and today's downtimes (live mirror).
 * Read-only: nothing here mutates.
 */
const USER = process.env.SANDBOX_USER || '';
const PASS = process.env.SANDBOX_PASSWORD || '';
const REFDATA = process.env.REFDATA_URL || 'https://refdata.staging.packiot.app';
// Staging-only read-api tenant keys (compose.staging.yml QUERY_API_KEYS); override via env.
const KEY_CPACK = process.env.REFDATA_KEY_CPACK || 'stg-cpack-key';
const KEY_SBX = process.env.REFDATA_KEY_SBX || 'stg-sbxcpack-key';

async function dataset(request: APIRequestContext, key: string, body: object) {
  const r = await request.post(`${REFDATA}/v1/query`, {
    headers: { 'X-Api-Key': key, 'Content-Type': 'application/json' },
    data: body,
    timeout: 60_000,
  });
  expect(r.status(), `read-api ${JSON.stringify(body).slice(0, 80)} → ${r.status()}`).toBe(200);
  return (await r.json()) as any[];
}

test.describe('sandbox front4 (ent 2000003) — reflection of CPACK', () => {
  test.describe('UI', () => {
    test.skip(!USER || !PASS, 'SANDBOX_USER/PASSWORD not set');

    test('sandbox user logs in and lands on the product home', async ({ page }) => {
      await front4Login(page, USER, PASS);
      await expect(page).toHaveURL(/\/home/, { timeout: 30_000 });
      await expect(page.getByRole('button', { name: 'Operations' })).toBeVisible({ timeout: 20_000 });
    });

    test('OEE, Downtimes and Production Orders render sandbox data', async ({ page }) => {
      await front4Login(page, USER, PASS);
      await page.goto('/OEE');
      await expect(page.getByText(/OEE Score/i).first()).toBeVisible({ timeout: 25_000 });
      await expect(page.locator('body')).toContainText(/%/);
      await page.goto('/downtimes');
      await expect(page.getByText(/Downtimes|Microstops/i).first()).toBeVisible({ timeout: 25_000 });
      await page.goto('/production-orders');
      await expect(page.getByText(/Production Orders/i).first()).toBeVisible({ timeout: 25_000 });
      await expect(page.locator('body')).toContainText(/Status|Job|Client|Product|Order Size/i);
    });
  });

  test.describe('parity via read-api (sandbox key vs CPACK key)', () => {
    test('history: 2023 OEE score is identical (history reflection)', async ({ request }) => {
      const body = { dataset: 'oee-score-full', window: { from: '2023-03-01T00:00:00Z', to: '2023-04-01T00:00:00Z' } };
      const [c, s] = await Promise.all([dataset(request, KEY_CPACK, body), dataset(request, KEY_SBX, body)]);
      expect(c.length, 'CPACK has 2023 history').toBeGreaterThan(0);
      expect(s.length).toBe(c.length);
      const avg = (rows: any[]) => rows.reduce((a, r) => a + Number(r.oee ?? r.oee_score ?? 0), 0) / rows.length;
      expect(avg(s)).toBeCloseTo(avg(c), 6);
    });

    test('history: 2023 production orders are identical', async ({ request }) => {
      const body = { dataset: 'production-orders-with-runtimes', window: { from: '2023-01-01T00:00:00Z', to: '2024-01-01T00:00:00Z' } };
      const [c, s] = await Promise.all([dataset(request, KEY_CPACK, body), dataset(request, KEY_SBX, body)]);
      expect(c.length).toBeGreaterThan(1000);
      expect(s.length).toBe(c.length);
      const orders = (rows: any[]) => rows.map((r) => String(r.id_order)).sort().join(',');
      expect(orders(s)).toBe(orders(c));
    });

    test('live: last-3-days downtimes mirror CPACK (same events, same justification)', async ({ request }) => {
      const to = new Date(Date.now() - 30 * 60_000); // leave the still-open tail out
      const from = new Date(to.getTime() - 3 * 86_400_000);
      const body = { dataset: 'downtimes-events', window: { from: from.toISOString(), to: to.toISOString() } };
      const [c, s] = await Promise.all([dataset(request, KEY_CPACK, body), dataset(request, KEY_SBX, body)]);
      expect(c.length).toBeGreaterThan(0);
      const sig = (rows: any[]) =>
        rows.map((r) => `${r.ts_event}|${r.duration}|${r.cd_category ?? ''}|${r.cd_subcategory ?? ''}`).sort();
      // exact multiset equality of (start, duration, category, sub-category)
      expect(sig(s)).toEqual(sig(c));
    });
  });
});
