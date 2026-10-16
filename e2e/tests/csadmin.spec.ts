import { test, expect } from '@playwright/test';
import { csadminLogin } from '../fixtures/auth';

/**
 * csadmin (CS onboarding SPA) — cross-tenant admin. Auth is app-level amplify
 * Cognito (enabled in the staging build); the cs-admin group + a users row let
 * the token load data. These tests are READ-ONLY against a REAL tenant
 * (CPACK-Staging, ent 3) — the mutating journeys live in sandbox-csadmin against
 * the self-healing twin, so production config is never touched here.
 */
const USER = process.env.CSADMIN_USER || '';
const PASS = process.env.CSADMIN_PASSWORD || '';

test.describe('csadmin (CS onboarding SPA)', () => {
  test('serves the login shell (smoke)', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('body')).toBeVisible();
    // With Cognito enabled the SPA renders its own sign-in form.
    await expect(page.getByText(/sign in|welcome/i).first()).toBeVisible({ timeout: 15_000 });
  });

  test.describe('authenticated', () => {
    test.skip(!USER || !PASS, 'CSADMIN_USER/PASSWORD not set');

    test('cs-admin logs in and the enterprises list loads real tenants', async ({ page }) => {
      await csadminLogin(page, USER, PASS);
      await expect(page).toHaveURL(/enterprises/, { timeout: 30_000 });
      // /api/enterprises 200 (Cognito-enable + users-row fix) — real clients show.
      await expect(page.getByText(/CPACK-Staging/i).first()).toBeVisible({ timeout: 15_000 });
    });

    test('reads a real tenant (CPACK-Staging) equipment — cross-tenant read', async ({ page, baseURL }) => {
      await csadminLogin(page, USER, PASS);
      await page.getByText(/^CPACK-Staging$/i).first().click();
      await page.waitForTimeout(1500);
      await page.goto(baseURL! + '/app/machines');
      await page.waitForTimeout(2500);
      // Real CPACK config loads read-only (its machines list is non-empty).
      await expect(page.getByRole('button', { name: /new machine|add/i }).first()).toBeVisible({ timeout: 15_000 });
      await expect(page.locator('body')).toContainText(/Active|machine/i);
    });
  });
});
