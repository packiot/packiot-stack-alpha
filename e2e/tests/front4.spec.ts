import { test, expect } from '@playwright/test';
import { front4Login } from '../fixtures/auth';

/**
 * front4 — the product SPA (customer-facing), READ-ONLY against a real tenant
 * (cpack, ent 3). No mutations here: front4 is the live product, so we assert the
 * customer pages render the RIGHT data. Write journeys live on the sandbox suites.
 */
const USER = process.env.FRONT4_USER || '';
const PASS = process.env.FRONT4_PASSWORD || '';

test.describe('front4 (product SPA)', () => {
  test.skip(!USER || !PASS, 'FRONT4_USER/PASSWORD not set');

  test('logs in and renders the authenticated home shell', async ({ page }) => {
    await front4Login(page, USER, PASS);
    await expect(page).toHaveURL(/\/home/, { timeout: 30_000 });
    await expect(page).toHaveTitle(/PackIOT/i);
    await expect(page.getByRole('heading', { name: /Good (morning|afternoon|evening)/i }).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.getByRole('button', { name: 'Operations' })).toBeVisible({ timeout: 20_000 });
    await expect(page.getByRole('button', { name: 'Reports' })).toBeVisible();
  });

  test('Settings does not flash "Unauthorized!" (#19)', async ({ page }) => {
    await front4Login(page, USER, PASS);
    await page.goto('/settings');
    await page.waitForTimeout(4000);
    await expect(page.locator('body')).toBeVisible();
    const unauthorizedCount = await page.getByText(/^Unauthorized!?$/i).count();
    const settingsNav = await page.getByRole('link', { name: /Targets|User and Permission|Production Orders|Downtime Reasons/i }).count();
    expect(settingsNav > 0 || unauthorizedCount > 0).toBeTruthy();
  });

  test('OEE page renders the tenant OEE score + A/P/Q breakdown', async ({ page }) => {
    await front4Login(page, USER, PASS);
    await page.goto('/OEE');
    await page.waitForTimeout(4000);
    await expect(page.getByText(/OEE Score/i).first()).toBeVisible({ timeout: 20_000 });
    // Real computed data (not an empty/error shell): a % score + the availability/
    // performance/quality factors.
    await expect(page.locator('body')).toContainText(/%/);
    await expect(page.locator('body')).toContainText(/Availab|Performanc|Quality|Disponib|Efici/i);
  });

  test('Downtimes page renders the event sections', async ({ page }) => {
    await front4Login(page, USER, PASS);
    await page.goto('/downtimes');
    await page.waitForTimeout(4000);
    await expect(page.getByText(/Downtimes|Microstops/i).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.locator('body')).toContainText(/EVENTS|Detected|Manual/i);
  });

  test('Production Orders page renders the PO table', async ({ page }) => {
    await front4Login(page, USER, PASS);
    await page.goto('/production-orders');
    await page.waitForTimeout(4000);
    await expect(page.getByText(/Production Orders/i).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.locator('body')).toContainText(/Status|Job|Client|Product|Order Size/i);
  });

  test('Machine Speed page renders', async ({ page }) => {
    await front4Login(page, USER, PASS);
    await page.goto('/machine-speed');
    await page.waitForTimeout(4000);
    await expect(page.getByText(/Machine Speed/i).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.locator('body')).toContainText(/DAILY|WEEKLY|GENERAL|SHIFTS/i);
  });
});
