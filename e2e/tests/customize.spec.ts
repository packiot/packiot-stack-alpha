import { test, expect } from '@playwright/test';

test.describe('customize (Customization Hub SPA)', () => {
  test('serves the SPA shell (smoke) with no-store index', async ({ page }) => {
    const resp = await page.goto('/');
    await expect(page.locator('body')).toBeVisible();
    // index.html must be no-store (the stale-SPA fix) — verify the served
    // entry document is not long-cached.
    if (resp) {
      const cc = resp.headers()['cache-control'] || '';
      expect(cc.toLowerCase()).toContain('no-store');
    }
  });
});
