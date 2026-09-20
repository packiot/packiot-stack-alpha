import { defineConfig, devices } from '@playwright/test';
import 'dotenv/config';

/**
 * Cross-frontend E2E for the Packiot stack. One suite, four deployed SPAs — each
 * a Playwright "project" with its own baseURL. Native headless (no xvfb, unlike
 * Cypress), Chromium by default; add firefox/webkit projects if a cross-browser
 * gate is wanted. Traces + screenshots retained on failure for the trace viewer.
 *
 * URLs + test creds come from .env (see .env.example) so nothing secret is
 * committed. Each project maps to tests/<app>.spec.ts via testMatch.
 */
const staging = {
  front4: process.env.FRONT4_URL || 'https://staging.packiot.com',
  operator: process.env.OPERATOR_URL || 'https://operator.staging.packiot.app',
  csadmin: process.env.CSADMIN_URL || 'https://csadmin.staging.packiot.app',
  customize: process.env.CUSTOMIZE_URL || 'https://customize.staging.packiot.app',
};

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    ignoreHTTPSErrors: true,
  },
  projects: [
    {
      name: 'front4',
      testMatch: /front4\.spec\.ts/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.front4 },
    },
    {
      name: 'operator',
      testMatch: /operator\.spec\.ts/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.operator },
    },
    {
      name: 'csadmin',
      testMatch: /csadmin\.spec\.ts/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.csadmin },
    },
    {
      name: 'customize',
      testMatch: /customize\.spec\.ts/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.customize },
    },
  ],
});
