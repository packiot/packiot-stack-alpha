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
  // Sandbox twin (ent 2000003): the MUTABLE playground. operator-sbx writes land
  // on the twin via the sandbox api-key. csadmin mutating tests target the twin
  // cross-tenant via ?idEnterprise=2000003. These tests mess the tenant up; the
  // globalSetup self-heals it back to an ent-3 reflection first (when E2E_SELFHEAL=1).
  operatorSbx: process.env.OPERATOR_SBX_URL || 'https://operator-sbx.staging.packiot.app',
};

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  // When E2E_SELFHEAL=1 (set by `npm run test:sandbox`), globalSetup resets the
  // sandbox twin to a clean ent-3 reflection BEFORE the mutating suite runs, so
  // every run starts reproducible regardless of prior mess. No-op otherwise, so
  // the read-only suite never triggers an SSM reset.
  globalSetup: process.env.E2E_SELFHEAL ? './global-setup.ts' : undefined,
  use: {
    // Trace mode is env-overridable so you can INSPECT DATA from any run, not
    // just retries. Default `retain-on-failure` keeps a full trace (network
    // requests + responses, DOM snapshots, console) for every failing test even
    // locally where retries=0 — open it with `npm run report` then click the
    // trace, or `PW_TRACE=on npm test` to capture EVERY test's trace/data.
    trace: (process.env.PW_TRACE as 'on' | 'off' | 'retain-on-failure' | 'on-first-retry') || 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    ignoreHTTPSErrors: true,
  },
  projects: [
    // testMatch is anchored on a path separator so `operator`/`csadmin` do NOT
    // also pick up `sandbox-operator`/`sandbox-csadmin` (an unanchored
    // /operator\.spec\.ts/ matches "sandbox-operator.spec.ts" too → the mutating
    // specs would run under the regular projects, against the wrong baseURL).
    {
      name: 'front4',
      testMatch: /[/\\]front4\.spec\.ts$/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.front4 },
    },
    {
      name: 'operator',
      testMatch: /[/\\]operator\.spec\.ts$/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.operator },
    },
    {
      name: 'csadmin',
      testMatch: /[/\\]csadmin\.spec\.ts$/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.csadmin },
    },
    {
      name: 'customize',
      testMatch: /[/\\]customize\.spec\.ts$/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.customize },
    },
    // ── Sandbox MUTATING projects (ent 2000003) — run via `npm run test:sandbox` ──
    // These write to the twin; the self-healing globalSetup + nightly cron keep
    // the tenant reproducible. Kept as separate projects so the default `npm test`
    // (read-only, all tenants) never mutates anything.
    {
      name: 'sandbox-operator',
      testMatch: /sandbox-operator\.spec\.ts/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.operatorSbx },
    },
    {
      name: 'sandbox-csadmin',
      testMatch: /sandbox-csadmin\.spec\.ts/,
      use: { ...devices['Desktop Chrome'], baseURL: staging.csadmin },
    },
  ],
});
