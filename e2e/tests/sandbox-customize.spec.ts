import { test, expect } from '@playwright/test';
import { csadminLogin } from '../fixtures/auth';

/**
 * Sandbox customize (ent 2000003) — Tier-1 derive-rule AUTHORING, a real write to the
 * twin's client_descriptor. Moved here from customize.spec.ts: the default suite is
 * read-only. Reset: ops.sandbox_reflect re-derives the descriptor from CPACK's
 * (remapped), dropping authored rules while preserving the sandbox-only capabilities.
 */
const USER = process.env.CUSTOMIZE_USER || process.env.CSADMIN_USER || '';
const PASS = process.env.CUSTOMIZE_PASSWORD || process.env.CSADMIN_PASSWORD || '';

test.describe('sandbox customize (mutate ent 2000003)', () => {
  test.skip(!USER || !PASS, 'CUSTOMIZE/CSADMIN creds not set');

  test('derive-rule authoring: author a rule + SAVE persists to the descriptor', async ({ page, baseURL }) => {
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
