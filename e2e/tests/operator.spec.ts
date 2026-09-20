import { test, expect } from '@playwright/test';
import { cognitoFormLogin } from '../fixtures/auth';

const USER = process.env.OPERATOR_USER || '';
const PASS = process.env.OPERATOR_PASSWORD || '';

test.describe('operator (shop-floor SPA)', () => {
  test('reaches the app / login gate (smoke)', async ({ page }) => {
    await page.goto('/');
    // Unauthenticated: either its own login or a Cognito hosted-UI redirect.
    await expect(page).toHaveURL(/.+/);
    await expect(page.locator('body')).toBeVisible();
  });

  test('logs in and renders', async ({ page, baseURL }) => {
    test.skip(!USER || !PASS, 'OPERATOR_USER/PASSWORD not set');
    await cognitoFormLogin(page, baseURL!, USER, PASS);
    await expect(page.locator('body')).toBeVisible();
    // Fill in a real post-login assertion (line picker / PO header) once a
    // stable selector is chosen.
  });
});
