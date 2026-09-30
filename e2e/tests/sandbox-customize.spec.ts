import { test, expect } from '@playwright/test';
import { csadminLogin } from '../fixtures/auth';

/**
 * Sandbox customize (ent 2000003) — calculation (derive-rule) AUTHORING, a real write to the
 * twin's client_descriptor. Moved here from customize.spec.ts: the default suite is
 * read-only. Reset: ops.sandbox_reflect re-derives the descriptor from CPACK's
 * (remapped), dropping authored rules while preserving the sandbox-only capabilities.
 */
const USER = process.env.CUSTOMIZE_USER || process.env.CSADMIN_USER || '';
const PASS = process.env.CUSTOMIZE_PASSWORD || process.env.CSADMIN_PASSWORD || '';

test.describe('sandbox customize (mutate ent 2000003)', () => {
  test.skip(!USER || !PASS, 'CUSTOMIZE/CSADMIN creds not set');

  // The authoring UI is the plain-language "Calculations" page (customize, 2026-09-29): pick where
  // the result goes, which values it uses (a, b, …), a formula → "Add calculation" → Save.
  test('calculation authoring: add a calculation + SAVE persists to the descriptor', async ({ page, baseURL }) => {
    await csadminLogin(page, USER, PASS);
    await expect(page.getByText(/SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 20_000 });
    await page.getByText(/SANDBOX-CPACK/i).first().click();
    await page.goto(baseURL! + '/app/customizations');
    await expect(page.getByText(/new calculation/i).first()).toBeVisible({ timeout: 20_000 });
    // 1. where the result goes (nothing is pre-selected) → the value pickers + formula appear with
    //    defaults: a = what went in, b = good parts, formula a - b (scrap)
    await page.locator('select').first().selectOption({ index: 1 });
    await expect(page.locator('#calc-formula')).toBeVisible({ timeout: 10_000 });
    await page.locator('#calc-formula').fill('a - b');
    await page.getByRole('button', { name: /add calculation/i }).click();
    await expect(page.getByText(/added\. press save/i).first()).toBeVisible({ timeout: 10_000 });
    const saved = page.waitForResponse(
      // field-scoped, version-checked save: PUT /api/onboarding/descriptor/customizations
      (r) => /onboarding\/descriptor\/customizations/.test(r.url()) && r.request().method() === 'PUT',
      { timeout: 15_000 },
    );
    await page.getByRole('button', { name: /^save$/i }).click();
    expect((await saved).status()).toBeLessThan(300);
    await expect(page.getByText(/^saved\./i).first()).toBeVisible({ timeout: 10_000 });
  });
});
