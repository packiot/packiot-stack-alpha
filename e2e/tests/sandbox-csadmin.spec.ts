import { test, expect } from '@playwright/test';
import { csadminLogin } from '../fixtures/auth';

/**
 * Sandbox csadmin journeys — mutate the twin (ent 2000003) cross-tenant. Select
 * SANDBOX-CPACK then create entities / edit onboarding. Safe: the self-healing
 * globalSetup re-clones the twin from ent 3 first (and wipes anything created).
 */
const USER = process.env.CSADMIN_USER || '';
const PASS = process.env.CSADMIN_PASSWORD || '';

async function selectSandbox(page: any, baseURL: string) {
  await csadminLogin(page, USER, PASS);
  await expect(page.getByText(/SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 20_000 });
  await page.getByText(/SANDBOX-CPACK/i).first().click();
  await page.waitForTimeout(1500);
}

test.describe('sandbox csadmin (mutate ent 2000003 cross-tenant)', () => {
  test.skip(!USER || !PASS, 'CSADMIN_USER/PASSWORD not set');

  test('cs-admin loads the enterprises list (incl. the sandbox twin)', async ({ page }) => {
    await csadminLogin(page, USER, PASS);
    // /api/enterprises must return data (the Cognito-enable + users-row fix) —
    // the sandbox twin is selectable.
    await expect(page.getByText(/SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 20_000 });
  });

  test('entity CRUD: create an area on the twin (real mutation)', async ({ page, baseURL }) => {
    await selectSandbox(page, baseURL!);
    await page.goto(baseURL! + '/app/area');
    await page.waitForTimeout(2500);
    const NAME = 'E2E-AREA-SBX';
    await page.getByRole('button', { name: /new area/i }).click();
    await page.waitForTimeout(1200);
    await page.getByRole('textbox').first().fill(NAME); // site/week/day default to SC/Monday
    await page.getByRole('button', { name: /^create area/i }).click();
    // The new area appears in the twin's area list (self-heal wipes it next run).
    await expect(page.getByText(NAME).first()).toBeVisible({ timeout: 20_000 });
  });

  test('onboarding config: reach the twin onboarding surface', async ({ page, baseURL }) => {
    await selectSandbox(page, baseURL!);
    await page.goto(baseURL! + '/app/onboarding');
    await page.waitForTimeout(2500);
    await expect(page.locator('body')).not.toBeEmpty();
    await expect(page.getByText(/onboarding|factory|sensor|tag|plc/i).first()).toBeVisible({ timeout: 15_000 });
  });
});
