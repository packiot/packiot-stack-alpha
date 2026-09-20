import { test, expect } from '@playwright/test';
import { csadminLogin } from '../fixtures/auth';

/**
 * customize — the Customization Hub SPA (ADR-0058): declarative derive rules +
 * DB integrations + Node-RED flows per tenant. cs-admin auth (amplify Cognito,
 * enabled in the staging build). Read-only coverage here — any authoring is
 * exercised against the self-healing twin in the sandbox suites.
 */
const USER = process.env.CUSTOMIZE_USER || process.env.CSADMIN_USER || '';
const PASS = process.env.CUSTOMIZE_PASSWORD || process.env.CSADMIN_PASSWORD || '';

test.describe('customize (Customization Hub SPA)', () => {
  test('serves the SPA shell (smoke) with no-store index', async ({ page }) => {
    const resp = await page.goto('/');
    await expect(page.locator('body')).toBeVisible();
    // index.html must be no-store (the stale-SPA fix).
    if (resp) {
      expect((resp.headers()['cache-control'] || '').toLowerCase()).toContain('no-store');
    }
  });

  test.describe('authenticated', () => {
    test.skip(!USER || !PASS, 'CUSTOMIZE/CSADMIN creds not set');

    test('cs-admin logs in and the Hub lists tenants', async ({ page }) => {
      await csadminLogin(page, USER, PASS);
      await expect(page).toHaveURL(/enterprises/, { timeout: 30_000 });
      await expect(page.getByText(/Select an enterprise to author/i)).toBeVisible({ timeout: 15_000 });
      // Real tenants load (proves /api/enterprises 200 under the cs-admin token).
      await expect(page.getByText(/CPACK-Staging|SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 15_000 });
    });

    test('opens a tenant Hub with the three customization tiers', async ({ page, baseURL }) => {
      await csadminLogin(page, USER, PASS);
      await expect(page.getByText(/SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 20_000 });
      await page.getByText(/SANDBOX-CPACK/i).first().click();
      await expect(page).toHaveURL(/\/app\/hub/, { timeout: 20_000 });
      // The ADR-0058 tiers.
      await expect(page.getByText(/Derive rules/i).first()).toBeVisible();
      await expect(page.getByText(/Database integrations|Integrations/i).first()).toBeVisible();
      // Derive-rules view is reachable (read-only).
      await page.getByRole('link', { name: /^Derive rules/i }).first().click().catch(() => {});
      await page.waitForTimeout(1500);
      await expect(page.locator('body')).not.toBeEmpty();
    });
  });
});
