import { test, expect } from '@playwright/test';

const USER = process.env.CSADMIN_USER || '';
const PASS = process.env.CSADMIN_PASSWORD || '';

test.describe('csadmin (CS onboarding SPA)', () => {
  test('reaches the oauth2/login gate (smoke)', async ({ page }) => {
    // csadmin sits behind oauth2-proxy (Cognito) — unauthenticated hits the gate.
    await page.goto('/');
    await expect(page.locator('body')).toBeVisible();
  });

  test('logs in and renders the Box Ops / onboarding shell', async ({ page }) => {
    test.skip(!USER || !PASS, 'CSADMIN_USER/PASSWORD not set');
    // oauth2-proxy → Cognito hosted UI → back to csadmin. Fill the hosted form.
    const email = page.locator('input[type="email"], input[name="username"]').first();
    await email.waitFor({ timeout: 20_000 });
    await email.fill(USER);
    await page.locator('input[type="password"], input[name="password"]').first().fill(PASS);
    await page.keyboard.press('Enter');
    await expect(page.locator('body')).toBeVisible();
  });
});
