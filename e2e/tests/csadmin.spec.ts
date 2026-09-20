import { test, expect } from '@playwright/test';
import { cognitoFormLogin } from '../fixtures/auth';

const USER = process.env.CSADMIN_USER || '';
const PASS = process.env.CSADMIN_PASSWORD || '';

test.describe('csadmin (CS onboarding SPA)', () => {
  test('reaches the oauth2/login gate (smoke)', async ({ page }) => {
    // csadmin sits behind oauth2-proxy (Cognito) — unauthenticated hits the gate.
    await page.goto('/');
    await expect(page.locator('body')).toBeVisible();
  });

  test('logs in and renders the Box Ops / onboarding shell', async ({ page, baseURL }) => {
    test.skip(!USER || !PASS, 'CSADMIN_USER/PASSWORD not set');
    // oauth2-proxy → shared Cognito hosted UI → back to csadmin (cs-admin group).
    await cognitoFormLogin(page, baseURL!, USER, PASS);
    await expect(page.locator('body')).toBeVisible();
    // Authenticated shell (not the login/oauth gate): the CS-Admin app chrome
    // exposes the Enterprises/Onboarding/Box Ops surface. Assert real chrome.
    await expect(
      page.getByText(/Enterprise|Onboarding|Box Ops|Clients|Sites|Equipment/i).first(),
    ).toBeVisible({ timeout: 20_000 });
  });
});
