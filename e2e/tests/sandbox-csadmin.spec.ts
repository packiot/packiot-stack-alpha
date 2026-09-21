import { test, expect } from '@playwright/test';
import { csadminLogin } from '../fixtures/auth';

/**
 * Sandbox csadmin journeys — mutate the twin (ent 2000003) cross-tenant. Select
 * SANDBOX-CPACK then exercise the full entity lifecycle. Safe: the self-healing
 * globalSetup re-clones the twin from ent 3 first (and wipes anything created).
 */
const USER = process.env.CSADMIN_USER || '';
const PASS = process.env.CSADMIN_PASSWORD || '';

async function selectSandbox(page: any) {
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
    await selectSandbox(page);
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
    await selectSandbox(page);
    await page.goto(baseURL! + '/app/onboarding');
    await page.waitForTimeout(2500);
    await expect(page.locator('body')).not.toBeEmpty();
    await expect(page.getByText(/onboarding|factory|sensor|tag|plc/i).first()).toBeVisible({ timeout: 15_000 });
  });

  // Regression for the equipment edit path (csadmin#107 + #109). Two migration
  // defects made editing a line silently un-saveable: the create-time superRefine
  // required overview_version (#107), and cd_equipment was NULL for whole tenants
  // → mapper "" → schema min(1) failed with NO visible error and NO POST (#109).
  // The sandbox lines are cloned from ent 3 (both NULL), so a Save here must now
  // actually fire the edit POST and succeed.
  test('equipment edit: a line saves (edit-block #107 + null cd_equipment #109)', async ({ page, baseURL }) => {
    await selectSandbox(page);
    await page.goto(baseURL! + '/app/lines');
    await page.waitForTimeout(2500);
    await page.locator('button[title="Edit"]').first().click();
    await page.waitForTimeout(1500);
    const save = page.getByRole('button', { name: /save changes/i });
    await expect(save).toBeVisible({ timeout: 10_000 });
    const edited = page.waitForResponse(
      (r) => /\/api\/equipments\/edit/.test(r.url()) && r.request().method() === 'POST',
      { timeout: 15_000 },
    );
    await save.click();
    // no create-time structural wall (#107) …
    await expect(page.getByText(/select an overview version/i)).toHaveCount(0);
    // … and the edit POST now actually fires + succeeds (#109 unblocked the submit)
    expect((await edited).status()).toBeLessThan(300);
  });

  // Guarantees the new Downtime Reasons editor (csadmin#108) end to end: load an
  // equipment's taxonomy, add a category, save → the operator-readable tree persists.
  test('downtime reasons: load, add a category, save', async ({ page, baseURL }) => {
    await selectSandbox(page);
    await page.goto(baseURL! + '/app/downtime-reasons');
    await page.waitForTimeout(2000);
    // pick an equipment (first real option) → the tree loads
    await page.locator('select').first().selectOption({ index: 1 });
    await page.waitForTimeout(2500);
    // existing categories render (the sandbox is a CPACK clone with a full tree)
    await expect(page.getByPlaceholder('Category code').first()).toBeVisible({ timeout: 15_000 });
    // add a distinctive category
    await page.getByRole('button', { name: /^\+ category$/i }).click();
    const CODE = 'E2E_DTR';
    await page.getByPlaceholder('Category code').last().fill(CODE);
    await page.getByPlaceholder('Category name').last().fill('E2E Downtime Category');
    // save → sonner success toast
    const saved = page.waitForResponse(
      (r) => /downtime-reasons/.test(r.url()) && r.request().method() === 'POST',
      { timeout: 15_000 },
    );
    await page.getByRole('button', { name: /^save$/i }).click();
    expect((await saved).status()).toBe(200);
    await expect(page.getByText(/saved/i).first()).toBeVisible({ timeout: 10_000 });
  });
});
