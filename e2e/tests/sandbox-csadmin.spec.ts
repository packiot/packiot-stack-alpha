import { test, expect } from '@playwright/test';
import { csadminLogin } from '../fixtures/auth';

/**
 * Sandbox csadmin journeys — mutate the twin (ent 2000003) cross-tenant. Select
 * SANDBOX-CPACK then exercise the full entity lifecycle. Safe: the self-healing
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
// The DataTable row's action button in the SAME row as a unique name.
const rowBtn = (page: any, name: string, title: string) =>
  page.getByText(name, { exact: true }).first()
    .locator(`xpath=ancestor::*[.//button[@title="${title}"]][1]//button[@title="${title}"]`);

test.describe('sandbox csadmin (mutate ent 2000003 cross-tenant)', () => {
  test.skip(!USER || !PASS, 'CSADMIN_USER/PASSWORD not set');

  test('cs-admin loads the enterprises list (incl. the sandbox twin)', async ({ page }) => {
    await csadminLogin(page, USER, PASS);
    await expect(page.getByText(/SANDBOX-CPACK/i).first()).toBeVisible({ timeout: 20_000 });
  });

  test('entity CRUD: create → edit → delete an area on the twin', async ({ page, baseURL }) => {
    page.on('dialog', (d) => d.accept()); // the delete uses window.confirm
    await selectSandbox(page, baseURL!);
    await page.goto(baseURL! + '/app/area');
    await page.waitForTimeout(2500);
    const NAME = 'E2E-AREA-CRUD', NAME2 = 'E2E-AREA-EDITED';

    // CREATE — site/week/day default to SC/Monday.
    await page.getByRole('button', { name: /new area/i }).click();
    await page.waitForTimeout(1000);
    await page.getByRole('textbox').first().fill(NAME);
    await page.getByRole('button', { name: /^create area/i }).click();
    await expect(page.getByText(NAME, { exact: true }).first()).toBeVisible({ timeout: 20_000 });

    // EDIT — rename via the row's Edit (pencil) button → reused form → Save changes.
    await rowBtn(page, NAME, 'Edit').click();
    await page.waitForTimeout(1000);
    await page.getByRole('textbox').first().fill(NAME2);
    await page.getByRole('button', { name: /save changes/i }).click();
    await expect(page.getByText(NAME2, { exact: true }).first()).toBeVisible({ timeout: 20_000 });

    // DELETE — the row's Delete (trash) button → window.confirm auto-accepted.
    await rowBtn(page, NAME2, 'Delete').click();
    await expect(page.getByText(NAME2, { exact: true })).toHaveCount(0, { timeout: 20_000 });
  });


  test('onboarding config: reach the twin onboarding surface', async ({ page, baseURL }) => {
    await selectSandbox(page, baseURL!);
    await page.goto(baseURL! + '/app/onboarding');
    await page.waitForTimeout(2500);
    await expect(page.locator('body')).not.toBeEmpty();
    await expect(page.getByText(/onboarding|factory|sensor|tag|plc/i).first()).toBeVisible({ timeout: 15_000 });
  });
});
