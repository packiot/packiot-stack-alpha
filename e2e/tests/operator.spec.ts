import { test, expect } from '@playwright/test';
import { cognitoFormLogin } from '../fixtures/auth';

/**
 * operator (shop-floor SPA) — the REAL-tenant instance (ent 3). Read-only here:
 * we verify the oauth2-proxy edge gate + that operator's own app is served, but
 * do NOT complete operator's internal login or drive any write — the full
 * 2-stage login + PO/downtime journeys run against the self-healing twin in
 * sandbox-operator, so production is never mutated.
 */
const USER = process.env.OPERATOR_USER || '';
const PASS = process.env.OPERATOR_PASSWORD || '';

test.describe('operator (shop-floor SPA)', () => {
  test('unauthenticated hits the login gate (smoke)', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('body')).toBeVisible();
    // A gate of some form (Cognito hosted UI or the app's own sign-in) renders a
    // visible credential field. (:visible — the classic hosted UI double-renders
    // its form, so a bare locator can resolve to the hidden copy.)
    await expect(
      page.locator('input[type="email"]:visible, input[type="password"]:visible, input[name="username"]:visible').first(),
    ).toBeVisible({ timeout: 20_000 });
  });

  test('passes the oauth2 edge gate and serves the operator app', async ({ page, baseURL }) => {
    test.skip(!USER || !PASS, 'OPERATOR_USER/PASSWORD not set');
    await cognitoFormLogin(page, baseURL!, USER, PASS);
    // Past the shared oauth2-proxy gate → operator's OWN login shell is served
    // (real app chrome on the app origin, not a 403/blank).
    await expect(page).toHaveURL(new RegExp(new URL(baseURL!).host.replace(/\./g, '\\.')));
    await expect(page.getByText(/welcome|sign in|login/i).first()).toBeVisible({ timeout: 20_000 });
  });
});
