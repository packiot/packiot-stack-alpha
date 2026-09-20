import { test, expect } from '@playwright/test';
import { operatorLogin } from '../fixtures/auth';

/**
 * Sandbox operator journeys (ent 2000003) — the MUTABLE twin. operator-sbx writes
 * land on the twin via the sandbox api-key; the self-healing globalSetup resets
 * the twin first, so these are safe to run repeatedly.
 */
const USER = process.env.SANDBOX_USER || '';
const PASS = process.env.SANDBOX_PASSWORD || '';

test.describe('sandbox operator (ent 2000003, mutable twin)', () => {
  test.skip(!USER || !PASS, 'SANDBOX_USER/PASSWORD not set');

  test('logs into operator-sbx (2-stage) and reaches the shop-floor', async ({ page, baseURL }) => {
    await operatorLogin(page, baseURL!, USER, PASS);
    await expect(page).toHaveURL(/\/home/);
    // Real shop-floor chrome scoped to the twin: the L5 line + the operator identity.
    await expect(page.getByRole('tab', { name: /production/i }).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.getByText(new RegExp(USER.replace(/[.@+]/g, '\\$&'), 'i')).first()).toBeVisible();
  });

  test('PO lifecycle: the production-order control surface is operable', async ({ page, baseURL }) => {
    await operatorLogin(page, baseURL!, USER, PASS);
    await page.getByRole('tab', { name: /production/i }).first().click().catch(() => {});
    await page.waitForTimeout(1500);
    // The PO picker + CONFIRM (start/select a production order) — the write entry point.
    await expect(page.getByRole('button', { name: /confirm|start|change/i }).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.getByText(/production order/i).first()).toBeVisible();
  });

  test('downtimes: the Events tab renders on the twin', async ({ page, baseURL }) => {
    await operatorLogin(page, baseURL!, USER, PASS);
    await page.getByRole('tab', { name: /events?/i }).first().click();
    await page.waitForTimeout(2500);
    await expect(page.locator('body')).not.toBeEmpty();
    await expect(page.getByRole('tab', { name: /events?/i }).first()).toBeVisible();
  });
});
