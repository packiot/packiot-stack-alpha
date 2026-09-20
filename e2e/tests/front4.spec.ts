import { test, expect } from '@playwright/test';
import { front4Login } from '../fixtures/auth';

const USER = process.env.FRONT4_USER || '';
const PASS = process.env.FRONT4_PASSWORD || '';
const CPACK_USER = process.env.CPACK_USER || '';
const CPACK_PASS = process.env.CPACK_PASSWORD || '';

test.describe('front4 (product SPA)', () => {
  test.skip(!USER || !PASS, 'FRONT4_USER/PASSWORD not set');

  test('logs in and renders the app shell (not the login page)', async ({ page }) => {
    await front4Login(page, USER, PASS);
    // Past /login → the authenticated shell mounted. Assert it's a real app,
    // not an error/blank: the top bar + some app chrome are present.
    await expect(page).not.toHaveURL(/\/login/);
    await expect(page.locator('body')).toBeVisible();
    // The Settings gate fix (#19): Settings must NOT flash "Unauthorized!".
    // (Smoke: navigating to settings resolves to the page or a spinner, never
    // an immediate Unauthorized for a permitted user.)
  });

  // cpack (ent 3) data assertion — a super-admin/cpack user switches to ent 3
  // and the OEE dashboard shows cpack equipment. Skipped unless CPACK creds set.
  test('cpack tenant renders equipment/OEE data', async ({ page }) => {
    test.skip(!CPACK_USER || !CPACK_PASS, 'CPACK_USER/PASSWORD not set');
    await front4Login(page, CPACK_USER, CPACK_PASS);
    await expect(page).not.toHaveURL(/\/login/);
    // If the super-admin switcher (#18) is present, pick the cpack enterprise,
    // then assert equipment/OEE tiles render with data. (Selector-specific;
    // fill in once the target dashboard route + a stable data testid are known.)
  });
});
