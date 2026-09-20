import { Page, expect } from '@playwright/test';

/**
 * front4 product login — the SPA renders its OWN Cognito email/password form
 * (amplify SRP under the hood), so we fill the form rather than hit a hosted UI.
 * Selectors mirror the committed Cypress login spec
 * (#outlined-adornment-email / #outlined-adornment-password). On success the
 * router leaves /login. Reusable for any tenant's user (cpack switch reuses it).
 */
export async function front4Login(page: Page, email: string, password: string) {
  await page.goto('/login');
  await page.fill('#outlined-adornment-email', email);
  await page.fill('#outlined-adornment-password', password);
  await page.press('#outlined-adornment-password', 'Enter');
  // Auth + bootstrap: the AuthGuard waits for the refdata bootstrap; give it room.
  await expect(page).not.toHaveURL(/\/login/, { timeout: 30_000 });
}

/**
 * Generic Cognito form login for the *.staging.packiot.app SPAs (operator etc.).
 * These sit behind oauth2-proxy → a Cognito Hosted UI, OR render their own form.
 * We try the common shapes; a project overrides this if its login differs.
 */
export async function cognitoFormLogin(page: Page, url: string, email: string, password: string) {
  await page.goto(url);
  // Hosted-UI or app form — match by input type, resilient to id changes.
  const emailField = page.locator('input[type="email"], input[name="username"], #outlined-adornment-email').first();
  const passField = page.locator('input[type="password"], input[name="password"], #outlined-adornment-password').first();
  await emailField.waitFor({ timeout: 20_000 });
  await emailField.fill(email);
  await passField.fill(password);
  await passField.press('Enter');
}
