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
 * csadmin / customize amplify login — with Cognito enabled (VITE_AUTH_COGNITO_ENABLED),
 * these SPAs render their OWN email/password form (amplify signIn), NOT the
 * oauth2-proxy hosted UI. On success the router leaves /login (→ /enterprises).
 * The cs-admin user also needs a users-table row (edge-api resolves the tenant by
 * cognito sub for no-target reads like GET /api/enterprises).
 */
export async function csadminLogin(page: Page, email: string, password: string) {
  await page.goto('/login');
  const emailField = page.locator('input[type="email"], #outlined-adornment-email, input[name="email"]').first();
  await emailField.waitFor({ timeout: 20_000 });
  await emailField.fill(email);
  await page.locator('input[type="password"], #outlined-adornment-password').first().fill(password);
  await page.getByRole('button', { name: /sign ?in|log ?in|entrar/i }).first().click();
  await expect(page).not.toHaveURL(/\/login/, { timeout: 30_000 });
}

/**
 * operator (+ operator-sbx) TWO-STAGE login:
 *   1. the oauth2-proxy edge gate (shared Cognito hosted UI) — shell access.
 *   2. operator's OWN internal login form ("Welcome Back!") — amplify cognitoSignIn
 *      → POST /session, which resolves the operator account by users.user_name =
 *      the email and returns the entity scope. The user therefore needs a users
 *      row whose user_name IS the email (not a display string) or /session 401s
 *      "No operator account for this identity".
 * On success the router lands on /home. Same creds drive both stages.
 */
export async function operatorLogin(page: Page, url: string, email: string, password: string) {
  await cognitoFormLogin(page, url, email, password);
  // Stage 2 — operator's internal form. Username is the first text input; the
  // password field carries the MUI id. Submit → /home once /session resolves.
  const userField = page.locator('input[type="email"], input:not([type="password"])').first();
  await userField.waitFor({ timeout: 20_000 });
  await userField.fill(email);
  await page.locator('#outlined-adornment-password, input[type="password"]').first().fill(password);
  await page.getByRole('button', { name: /login|sign ?in|entrar/i }).first().click();
  await expect(page).toHaveURL(/\/home/, { timeout: 30_000 });
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
