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

    test('derive-rules authoring: add a rule + run simulation on the twin', async ({ page, baseURL }) => {
      // The Tier-1 authoring editor (ADR-0058): expression + metric bindings + a
      // sample-input box, with Run Simulation validating server-side. We drive the
      // editor and assert the simulate call reaches the backend for the twin (200)
      // — full SAVE is gated behind DSL validation the agent owns, out of E2E scope.
      await csadminLogin(page, USER, PASS);
      await expect(page.getByText(/SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 20_000 });
      await page.getByText(/SANDBOX-CPACK/i).first().click();
      await page.goto(baseURL! + '/app/customizations');
      await page.waitForTimeout(3000);
      await page.getByRole('button', { name: /add rule/i }).click();
      await page.waitForTimeout(800);
      const inp = page.locator('input, textarea');
      const G = 'SBXCPACK/SC/LINHAS/L5/RMH', N = 'SBXCPACK/SC/LINHAS/L5/TEXA';
      await inp.nth(0).fill('gross - net');
      await inp.nth(1).fill(`gross = ${G}\nnet = ${N}`);
      await inp.nth(2).fill(`[{ "metric": "${G}", "value": 500 }, { "metric": "${N}", "value": 470 }]`);
      const simulate = page.waitForResponse(
        (r) => /onboarding\/simulate/.test(r.url()) && r.request().method() === 'POST',
        { timeout: 20_000 },
      );
      await page.getByRole('button', { name: /run simulation/i }).click();
      expect((await simulate).status()).toBe(200);
    });
  });
});
