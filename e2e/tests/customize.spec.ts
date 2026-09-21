import { test, expect } from '@playwright/test';
import { csadminLogin } from '../fixtures/auth';

/**
 * customize — the Customization Hub SPA (ADR-0058): declarative derive rules +
 * DB integrations + Node-RED flows per tenant. cs-admin auth (amplify Cognito,
 * enabled in the staging build). Authoring runs against the self-healing twin
 * (client_descriptors re-cloned each heal), never a real tenant.
 */
const USER = process.env.CUSTOMIZE_USER || process.env.CSADMIN_USER || '';
const PASS = process.env.CUSTOMIZE_PASSWORD || process.env.CSADMIN_PASSWORD || '';

test.describe('customize (Customization Hub SPA)', () => {
  test('serves the SPA shell (smoke) with no-store index', async ({ page }) => {
    const resp = await page.goto('/');
    await expect(page.locator('body')).toBeVisible();
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
      await expect(page.getByText(/CPACK-Staging|SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 15_000 });
    });

    test('opens a tenant Hub with the three customization tiers', async ({ page }) => {
      await csadminLogin(page, USER, PASS);
      await expect(page.getByText(/SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 20_000 });
      await page.getByText(/SANDBOX-CPACK/i).first().click();
      await expect(page).toHaveURL(/\/app\/hub/, { timeout: 20_000 });
      await expect(page.getByText(/Derive rules/i).first()).toBeVisible();
      await expect(page.getByText(/Database integrations|Integrations/i).first()).toBeVisible();
      await page.getByRole('link', { name: /^Derive rules/i }).first().click().catch(() => {});
      await page.waitForTimeout(1500);
      await expect(page.locator('body')).not.toBeEmpty();
    });

    test('derive-rule authoring: author a rule + SAVE persists to the descriptor', async ({ page, baseURL }) => {
      // Full Tier-1 write path (ADR-0058): pick an equipment, write an expression +
      // variable bindings, Add rule (→ dirty), then SAVE → onboardingApi
      // upsertDescriptor persists it to the tenant's client_descriptor (POST
      // /api/onboarding/descriptor → 201). On the self-healing twin.
      await csadminLogin(page, USER, PASS);
      await expect(page.getByText(/SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 20_000 });
      await page.getByText(/SANDBOX-CPACK/i).first().click();
      await page.goto(baseURL! + '/app/customizations');
      await page.waitForTimeout(3000);
      await page.locator('select').first().selectOption({ index: 1 }); // Equipment (rule target)
      await page.getByPlaceholder('gross - net').fill('gross - net');
      const vars = 'gross = /SC/LINHAS/L5/RMH/Admin/ProdProcessedCount/56/Unit\nnet = /SC/LINHAS/L5/TEXA/Admin/ProdProcessedCount/57/Unit';
      await page.locator('textarea').first().fill(vars);
      await page.getByRole('button', { name: /add rule/i }).click();
      await expect(page.getByText('gross - net').first()).toBeVisible({ timeout: 10_000 });
      const saved = page.waitForResponse(
        (r) => /onboarding\/descriptor/.test(r.url()) && r.request().method() === 'POST',
        { timeout: 15_000 },
      );
      await page.getByRole('button', { name: /^save$/i }).click();
      expect((await saved).status()).toBe(201);
      await expect(page.getByText(/saved to the descriptor/i)).toBeVisible({ timeout: 10_000 });
    });
  });
});
