import { test, expect } from '@playwright/test';
import { operatorLogin } from '../fixtures/auth';

/**
 * Sandbox operator journeys (ent 2000003) — the MUTABLE twin. operator-sbx writes
 * land on the twin via the sandbox api-key; the self-healing globalSetup resets it
 * first (config re-clone + operational wipe + analytics PO-runtime clear, so a
 * fresh PO can be started without a stale RANGE_CONFLICT window).
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
    // The full shop-floor write path: SelectPo → "Create a Production Order" →
    // order + quantity → CONFIRM → edge-api create-and-start (sandbox api-key →
    // ent 2000003). We assert the write (201) + the success toast; the running-PO
    // then appears after the pipeline sync (the toast literally says so), which is
    // async, so we don't gate the UI refresh on it.
    const created = page.waitForResponse(
      (r) => /production-orders\/create-and-start/.test(r.url()) && r.request().method() === 'POST',
      { timeout: 25_000 },
    );
    await operatorLogin(page, baseURL!, USER, PASS);
    await page.waitForTimeout(1500);
    await page.locator('[aria-haspopup="listbox"], [role="combobox"]').first().click();
    await page.getByRole('option', { name: /create a production order/i }).click();
    await page.getByPlaceholder(/number of the new production order/i).fill('990777');
    await page.getByPlaceholder(/enter the quantity/i).fill('500');
    await page.getByRole('button', { name: /confirm/i }).click();
    expect((await created).status()).toBe(201);
    await expect(page.getByText(/success/i).first()).toBeVisible({ timeout: 10_000 });
  });

  test('events surface renders (downtime justification lives here)', async ({ page, baseURL }) => {
    await operatorLogin(page, baseURL!, USER, PASS);
    await page.getByRole('tab', { name: /events?/i }).first().click();
    await page.waitForTimeout(2500);
    // Pending / Historic downtime sections render (empty on a freshly-healed twin
    // until PLC events replay — justify/split are exercised once events exist).
    await expect(page.getByText(/pending|historic|no events/i).first()).toBeVisible({ timeout: 15_000 });
  });
});
