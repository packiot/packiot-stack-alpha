// Capture a tenant's front4 screens as a super-admin via the enterprise switcher.
//   DEVPASS_FILE=<file> SHOTS_DIR=<dir> [TENANT=bispharma] [FRONT4_URL=...] node scripts/capture-tenant-screens.mjs
// Password is read from DEVPASS_FILE (never hardcoded / never printed).
import { chromium } from '@playwright/test';
import { readFileSync } from 'node:fs';

const BASE = process.env.FRONT4_URL || 'https://staging.packiot.com';
const USER = process.env.CAPTURE_USER || 'dev@packiot.com';
const PASS = readFileSync(process.env.DEVPASS_FILE, 'utf8').trim();
const OUT  = process.env.SHOTS_DIR;
const TENANT = process.env.TENANT || 'bispharma';
const TARGET = new RegExp(TENANT, 'i');

const log = (...a) => console.log('[capture]', ...a);
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1680, height: 1050 } });
const page = await ctx.newPage();

log('login', USER);
await page.goto(BASE + '/login');
await page.fill('#outlined-adornment-email', USER);
await page.fill('#outlined-adornment-password', PASS);
await page.press('#outlined-adornment-password', 'Enter');
await page.waitForURL(/\/home/, { timeout: 35_000 });
log('logged in, at', page.url());

// --- discover + operate the enterprise switcher ---
async function switchToTenant() {
  const btn = page.getByRole('button', { name: /select enterprise/i });
  await btn.first().click({ timeout: 10000 });
  log('clicked Select enterprise');
  await page.waitForTimeout(1500);
  // dropdown may have a search box
  const search = page.locator('input[type="text"], input[type="search"], input:not([type="password"])').last();
  if (await search.count().catch(()=>0)) { try { await search.fill(TENANT, {timeout:3000}); log('typed', TENANT); await page.waitForTimeout(1200);} catch {} }
  const opt = page.getByRole('option', { name: TARGET }).or(page.getByRole('menuitem',{name:TARGET})).or(page.getByText(TARGET));
  await opt.first().click({ timeout: 10000 });
  log('selected', TENANT);
  await page.waitForTimeout(4500);
  return true;
}
const switched = await switchToTenant();
log('switched:', switched, 'now enterprise ctx:', page.url());

for (const [path, name] of [['/mission-control','01-mission-control'],['/downtimes','02-downtimes'],['/production-orders','03-production-orders'],['/OEE','04-oee']]) {
  await page.goto(BASE + path);
  await page.waitForTimeout(6500);
  await page.screenshot({ path: `${OUT}/${name}.png`, fullPage: true });
  log('shot', name);
}
await browser.close();
log('done');
