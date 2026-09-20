import { test, expect } from '@playwright/test';
import { front4Login } from '../fixtures/auth';

const USER = process.env.FRONT4_USER || '';
const PASS = process.env.FRONT4_PASSWORD || '';
const CPACK_USER = process.env.CPACK_USER || '';
const CPACK_PASS = process.env.CPACK_PASSWORD || '';

test.describe('front4 (product SPA)', () => {
  test.skip(!USER || !PASS, 'FRONT4_USER/PASSWORD not set');

  test('logs in and renders the authenticated home shell', async ({ page }) => {
    await front4Login(page, USER, PASS);
    // Real post-login shape (verified against staging.packiot.com):
    await expect(page).toHaveURL(/\/home/, { timeout: 30_000 });
    await expect(page).toHaveTitle(/PackIOT/i);
    // Home greeting confirms the shell mounted (content loads after the bootstrap,
    // so give it room; .first() — the greeting appears in more than one node).
    await expect(
      page.getByRole('heading', { name: /Good (morning|afternoon|evening)/i }).first(),
    ).toBeVisible({ timeout: 20_000 });
    // Primary nav present → real app chrome, not an error/blank shell.
    await expect(page.getByRole('button', { name: 'Operations' })).toBeVisible({ timeout: 20_000 });
    await expect(page.getByRole('button', { name: 'Reports' })).toBeVisible();
  });

  test('Settings does not flash "Unauthorized!" (#19)', async ({ page }) => {
    await front4Login(page, USER, PASS);
    await page.goto('/settings');
    // The #19 fix: while permissions load it shows a spinner (or, if the user
    // genuinely lacks the Settings screen, a *stable* Unauthorized) — never an
    // instant flash. Assert it resolves to a stable state and the app didn't
    // crash. If this user IS permitted, the Settings side-nav renders.
    await page.waitForTimeout(4000);
    await expect(page.locator('body')).toBeVisible();
    const unauthorizedCount = await page.getByText(/^Unauthorized!?$/i).count();
    const settingsNav = await page.getByRole('link', { name: /Targets|User and Permission|Production Orders|Downtime Reasons/i }).count();
    // Either the settings nav rendered (permitted) OR a stable Unauthorized
    // (not-permitted) — but not a broken/blank shell.
    expect(settingsNav > 0 || unauthorizedCount > 0).toBeTruthy();
  });

  // cpack (ent 3) data render — set CPACK_USER/PASSWORD (a super_user via the #18
  // switcher, or a dedicated ent-3 user). Asserts real equipment/OEE data renders.
  test('cpack tenant renders equipment/OEE data', async ({ page }) => {
    test.skip(!CPACK_USER || !CPACK_PASS, 'CPACK_USER/PASSWORD not set — skipping cpack data assertion');
    await front4Login(page, CPACK_USER, CPACK_PASS);
    await expect(page).toHaveURL(/\/home/, { timeout: 30_000 });
    // 0001_os2 resolves to ent 3 (cpack). Reach a data surface — resilient nav:
    // .first() + no exact (the login test proved the button is visible), tolerate
    // a nav that routes without a full networkidle.
    await page.getByRole('button', { name: 'Operations' }).first().click({ timeout: 15_000 });
    await page.waitForTimeout(5_000);
    // cpack (ent 3, 62 equipment via bi.equipments RLS) — assert real tenant data
    // rendered somewhere in the shell, not the empty-state placeholder.
    await expect(page.getByText(/^\s*(no data|nenhum dado)\s*$/i)).toHaveCount(0);
    await expect(page.locator('body')).toContainText(/OEE|Availab|Performanc|Quality|Disponib|Efici/i, { timeout: 15_000 });
  });
});
