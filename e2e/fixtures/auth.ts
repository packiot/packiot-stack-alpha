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
 * Cognito Hosted-UI login for the *.staging.packiot.app SPAs (operator, csadmin,
 * customize). These sit behind oauth2-proxy → the shared AWS Cognito managed
 * login UI at auth.staging.packiot.app (app-client "oauth2-proxy-staging", same
 * pool as front4). Navigating to the app while unauthenticated redirects there;
 * on success Cognito bounces back through the oauth2-proxy /callback to the app
 * origin. We wait for that bounce (URL host == the app host) as the success gate.
 */
export async function cognitoFormLogin(page: Page, url: string, email: string, password: string) {
  const appHost = new URL(url).host;
  await page.goto(url);

  // Some oauth2-proxy configs show an interstitial "Sign in" button before the
  // Cognito redirect — click it if present (best-effort, short timeout).
  const proxyStart = page.getByRole('button', { name: /^sign in$/i }).or(page.getByRole('link', { name: /^sign in$/i }));
  await proxyStart.first().click({ timeout: 3_000 }).catch(() => {});

  // The Cognito classic Hosted UI renders the sign-in form TWICE (a visible copy
  // + a hidden duplicate for the panel toggle), so scope to the :visible instance
  // — .first() alone grabs the hidden one and hangs on fill.
  const emailField = page.locator('input[name="username"]:visible, #signInFormUsername:visible, input[type="email"]:visible').first();
  await emailField.waitFor({ timeout: 25_000 });
  await emailField.fill(email);

  const passField = page.locator('input[name="password"]:visible, #signInFormPassword:visible, input[type="password"]:visible').first();
  await passField.fill(password);

  const submit = page.locator('input[name="signInSubmitButton"]:visible, button[type="submit"]:visible').first();
  await submit.click().catch(() => passField.press('Enter'));

  // Success = Cognito → oauth2-proxy /callback → back to the app origin.
  await page.waitForURL((u) => u.host === appHost, { timeout: 30_000 });
}
