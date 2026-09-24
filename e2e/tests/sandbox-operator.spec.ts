import { test, expect } from '@playwright/test';
import { operatorLogin } from '../fixtures/auth';

/**
 * Sandbox operator journeys (ent 2000003) — the MUTABLE twin. operator-sbx writes
 * land on the twin via the sandbox api-key; the self-healing globalSetup resets it
 * first (config re-clone + operational wipe + analytics PO-runtime clear, so a
 * fresh PO can be started without a stale RANGE_CONFLICT window).
 */
const USER = process.env.SANDBOX_USER || '';
const PASS = process.env.SANDBOX_PASSWORD || '';

test.describe.serial('sandbox operator (ent 2000003, mutable twin)', () => {
  test.skip(!USER || !PASS, 'SANDBOX_USER/PASSWORD not set');

  test('2-stage login reaches the shop-floor', async ({ page, baseURL }) => {
    await operatorLogin(page, baseURL!, USER, PASS);
    await expect(page).toHaveURL(/\/home/);
    await expect(page.getByRole('tab', { name: /production/i }).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.getByRole('tab', { name: /events?/i }).first()).toBeVisible();
  });

  test('PO write path: create + start a production order (switching from the running one) → 2xx', async ({ page, baseURL }) => {
    // The twin reflects CPACK's LIVE state, so a line may already be running a PO. The
    // operator flow is then: change-PO button in the "PO <id>" heading → the same "choose
    // or create a Production Order" dialog → CONFIRM (finishes the running PO + starts
    // the new one). With no running PO the picker is inline. Either way we create a new
    // order and assert the production-orders write succeeds + the success toast.
    test.setTimeout(90_000);
    // running → create + REPLACE (switch); idle → create-and-start. The switch's success
    // toast only follows a successful REPLACE, so assert the LAST write of the flow.
    const finalWrite = page.waitForResponse(
      (r) => /\/api\/production-orders\/(replace|create-and-start)/.test(r.url()) && r.request().method() === 'POST',
      { timeout: 45_000 },
    );
    await operatorLogin(page, baseURL!, USER, PASS);
    // Production data loads async: wait for EITHER state before branching (a bare
    // count() raced the poll, saw neither, and waited on an inline picker that a
    // running PO never renders).
    const runningHeading = page.getByRole('heading', { name: /^PO / });
    const inlinePicker = page.locator('[aria-haspopup="listbox"], [role="combobox"]');
    await expect(runningHeading.or(inlinePicker).first()).toBeVisible({ timeout: 25_000 });
    // running PO → its heading ("PO <id>") carries the change-PO button
    const running = runningHeading.locator('button');
    let scope: any = page;
    if (await running.count()) {
      await running.first().click();
      scope = page.getByRole('dialog');
      await expect(scope).toBeVisible({ timeout: 10_000 });
    }
    await scope.locator('[aria-haspopup="listbox"], [role="combobox"]').first().click();
    await page.getByRole('option', { name: /create a production order/i }).click();
    await page.getByPlaceholder(/number of the new production order/i).fill(String(990000 + Math.floor(Math.random() * 9999)));
    await page.getByPlaceholder(/enter the quantity/i).fill('500');
    await page.getByRole('button', { name: /confirm/i }).last().click();
    const resp = await finalWrite;
    expect(resp.status(), `PO write ${resp.url()} → ${await resp.text()}`).toBeLessThan(300);
    await expect(page.getByText(/success/i).first()).toBeVisible({ timeout: 10_000 });
  });

  test('events surface renders (downtime justification lives here)', async ({ page, baseURL }) => {
    await operatorLogin(page, baseURL!, USER, PASS);
    await page.getByRole('tab', { name: /events?/i }).first().click();
    await page.waitForTimeout(2500);
    // Pending / Historic downtime sections render (empty on a freshly-healed twin
    // until PLC events replay — justify/split are exercised once events exist).
    await expect(page.getByText(/pending|historic|no events/i).first()).toBeVisible({ timeout: 15_000 });
  });

  // Pick the first option of each downtime-reason combobox (machine → category →
  // sub-category) inside a dialog; the reflection gives the twin CPACK's full taxonomy.
  async function pickReasons(page: any, dialog: any) {
    for (const i of [0, 1, 2]) {
      await dialog.getByRole('combobox').nth(i).click();
      await page.getByRole('option').first().click();
      await page.waitForTimeout(300);
    }
  }

  test('downtime JUSTIFY: pick a reason for a pending event → POST /api/downtimes/justify 2xx', async ({ page, baseURL }) => {
    test.setTimeout(90_000);
    await operatorLogin(page, baseURL!, USER, PASS);
    await page.getByRole('tab', { name: /events?/i }).first().click();
    await expect(page.getByText(/downtime reason pending/i).first()).toBeVisible({ timeout: 25_000 });
    await page.locator('[data-testid="ModeEditOutlinedIcon"]').first().click();
    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible({ timeout: 10_000 });
    await pickReasons(page, dialog);
    await dialog.getByLabel(/justification|notes/i).fill('E2E justify (sandbox)');
    const justified = page.waitForResponse(
      (r) => /\/api\/downtimes\/justify/.test(r.url()) && r.request().method() === 'POST', { timeout: 20_000 });
    await dialog.getByRole('button', { name: /confirm/i }).click();
    expect((await justified).status(), 'justify write').toBeLessThan(300);
    await expect(page.getByText(/success/i).first()).toBeVisible({ timeout: 10_000 });
  });

  test('downtime SPLIT: split a pending event into two justified halves → POST /api/downtimes/split 2xx', async ({ page, baseURL }) => {
    test.setTimeout(90_000);
    await operatorLogin(page, baseURL!, USER, PASS);
    await page.getByRole('tab', { name: /events?/i }).first().click();
    await expect(page.getByText(/downtime reason pending/i).first()).toBeVisible({ timeout: 25_000 });
    // a DIFFERENT event than the justify test (serial, but the list may not have refreshed)
    await page.locator('[data-testid="CallSplitSharpIcon"]').nth(2).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible({ timeout: 10_000 });
    await pickReasons(page, dialog); // first half (default split point)
    const next = dialog.getByRole('button', { name: /next/i });
    await expect(next).toBeEnabled({ timeout: 10_000 });
    await next.click();
    await page.waitForTimeout(800);
    await pickReasons(page, dialog); // second half
    const split = page.waitForResponse(
      (r) => /\/api\/downtimes\/split/.test(r.url()) && r.request().method() === 'POST', { timeout: 20_000 });
    const submit = dialog.getByRole('button', { name: /confirm|save|submit|^split/i }).last();
    await expect(submit).toBeEnabled({ timeout: 10_000 });
    await submit.click();
    expect((await split).status(), 'split write').toBeLessThan(300);
  });
});
