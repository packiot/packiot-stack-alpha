import { test, expect } from '@playwright/test';
import { operatorLogin } from '../fixtures/auth';

/**
 * Sandbox operator journeys (ent 2000003) — the MUTABLE twin. operator-sbx writes
 * land on the twin via the sandbox api-key; the self-healing globalSetup resets it
 * first (config re-clone + operational wipe + analytics PO-runtime clear + a seeded
 * pending downtime), so a fresh PO can be started and a downtime justified.
 */
const USER = process.env.SANDBOX_USER || '';
const PASS = process.env.SANDBOX_PASSWORD || '';

test.describe('sandbox operator (ent 2000003, mutable twin)', () => {
  test.skip(!USER || !PASS, 'SANDBOX_USER/PASSWORD not set');

  test('2-stage login reaches the shop-floor', async ({ page, baseURL }) => {
    await operatorLogin(page, baseURL!, USER, PASS);
    await expect(page).toHaveURL(/\/home/);
    await expect(page.getByRole('tab', { name: /production/i }).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.getByRole('tab', { name: /events?/i }).first()).toBeVisible();
  });

  test('PO write path: create + start a production order → 201', async ({ page, baseURL }) => {
    await operatorLogin(page, baseURL!, USER, PASS);
    await page.waitForTimeout(1500);
    await page.locator('[aria-haspopup="listbox"], [role="combobox"]').first().click();
    await page.getByRole('option', { name: /create a production order/i }).click();
    await page.getByPlaceholder(/number of the new production order/i).fill('990777');
    await page.getByPlaceholder(/enter the quantity/i).fill('500');
    // Set up the response wait just before the triggering click so its timeout
    // covers only the POST (not the 2-stage login) — robust under parallel load.
    const created = page.waitForResponse(
      (r) => /production-orders\/create-and-start/.test(r.url()) && r.request().method() === 'POST',
      { timeout: 20_000 },
    );
    await page.getByRole('button', { name: /confirm/i }).click();
    expect((await created).status()).toBe(201);
    await expect(page.getByText(/success/i).first()).toBeVisible({ timeout: 10_000 });
  });

  test('downtime write path: justify a pending downtime → 200', async ({ page, baseURL }) => {
    // Events tab lists pending downtimes (read-api /v1/pending-downtime, un-broken by
    // the tenant-GUC fix); the self-heal seeds one so there's always at least one.
    // Justify modal (edit icon) → machine / category / sub-category (real reasons from
    // the tenant's config) → Confirm → edge-api /api/downtimes/justify (sandbox key).
    await operatorLogin(page, baseURL!, USER, PASS);
    await page.getByRole('tab', { name: /events?/i }).first().click();
    await page.waitForTimeout(4000);
    await expect(page.getByText(/pending/i).first()).toBeVisible({ timeout: 15_000 });
    await page.locator('[data-testid="ModeEditOutlinedIcon"]').first().click();
    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible({ timeout: 10_000 });
    for (const i of [0, 1, 2]) {
      await dialog.getByRole('combobox').nth(i).click();
      await page.waitForTimeout(400);
      await page.getByRole('option').first().click().catch(() => {});
      await page.waitForTimeout(400);
    }
    const justified = page.waitForResponse(
      (r) => /downtimes\/justify/.test(r.url()) && r.request().method() === 'POST',
      { timeout: 20_000 },
    );
    await dialog.getByRole('button', { name: /confirm/i }).click();
    expect((await justified).status()).toBe(200);
    await expect(page.getByText(/success/i).first()).toBeVisible({ timeout: 10_000 });
  });
});
