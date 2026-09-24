import { test, expect, Page } from '@playwright/test';
import { front4Login, operatorLogin } from '../fixtures/auth';
import { mkdirSync } from 'node:fs';

/**
 * Bispharma (ent 5) DEMO REHEARSAL — the client's view, in pt-BR, READ-ONLY.
 * Run the morning of a demo:  npm run demo:bispharma   (screenshots → demo-shots/bispharma/)
 *
 * Every assertion is a defect found while preparing the 2026-09-24 demo:
 *  - front4 MUST be opened at front.staging.packiot.app: Superset (bi.staging.packiot.app)
 *    is same-site there; from staging.packiot.com the embed is cross-site, the session
 *    cookie is dropped (3rd-party cookie blocking) and EVERY chart 400s "CSRF session token
 *    is missing".
 *  - Home greeted pt-BR users in English on first render (front4 #282).
 *  - 17 pt-BR keys were missing → English leaked (t-i18n-ptbr-missing-desktop-keys).
 *  - Downtimes showed "running 114%" on the month view (pre-fix history) → demo uses the WEEK.
 * Timing: the current shift is built from HOURLY buckets — avoid the first hour after a
 * shift change (SP 05:00/13:30/22:00, BISNAGO 06:00/14:20/22:35 BRT) or it reads 0.
 */
const FRONT4 = 'https://front.staging.packiot.app';
const OPERATOR = process.env.OPERATOR_URL || 'https://operator.staging.packiot.app';
const USER = process.env.BISPHARMA_USER || '';
const PASS = process.env.BISPHARMA_PASSWORD || '';
const SHOTS = 'demo-shots/bispharma';
const ENGLISH_LEAKS = /Good (morning|afternoon|evening)|There aren't any|This is the status of your operation|Couldn't load/i;

// The realistic presenter path: log in, land on Home in pt-BR (the pack has loaded), THEN
// navigate. Deep-linking a page milliseconds after the first-ever login still renders
// English on pages that read the pack non-reactively (getLanguage) — known front4 gap.
async function login(page: Page) {
  await front4Login(page, USER, PASS);
  await expect(page.getByRole('heading', { name: /Bom dia|Boa tarde|Boa noite/i }).first()).toBeVisible({ timeout: 20_000 });
}

async function shot(page: Page, name: string) {
  mkdirSync(SHOTS, { recursive: true });
  await page.screenshot({ path: `${SHOTS}/${name}.png` });
}

test.describe.serial('Bispharma demo rehearsal (pt-BR, read-only)', () => {
  test.skip(!USER || !PASS, 'BISPHARMA_USER/PASSWORD not set (npm run creds)');
  test.use({ baseURL: FRONT4, viewport: { width: 1600, height: 1000 } });
  test.describe.configure({ timeout: 120_000 });

  test('1. Home greets in Portuguese on the FIRST render after login', async ({ page }) => {
    await login(page);
    await expect(page.locator('body')).not.toContainText(ENGLISH_LEAKS);
    await shot(page, '1-home');
  });

  test('2. Mission Control lists the lines, live speed, no English leaks', async ({ page }) => {
    await login(page);
    await page.goto('/mission-control');
    await expect(page.getByText(/Torre de Controle/i).first()).toBeVisible({ timeout: 25_000 });
    await expect(page.getByText(/\d+\/min/).first()).toBeVisible({ timeout: 25_000 });
    await expect(page.locator('body')).not.toContainText(ENGLISH_LEAKS);
    await shot(page, '2-mission-control');
  });

  test('3. OEE (this week): real A/P/Q, Performance not pinned at 100%', async ({ page }) => {
    await login(page);
    await page.goto('/OEE');
    await page.getByText(/Essa Semana/i).first().click();
    await expect(page.getByText(/OEE score total/i).first()).toBeVisible({ timeout: 25_000 });
    const body = await page.locator('body').innerText();
    const perf = body.match(/Performance\s+([\d.]+)%/);
    expect(perf, 'Performance figure present').not.toBeNull();
    expect(Number(perf![1]), 'Performance must not be clamped at 100% (mock speeds are gone)').toBeLessThan(100);
    await shot(page, '3-oee-week');
  });

  test('4. Downtimes (this week): running share is a real percentage (≤100%)', async ({ page }) => {
    await login(page);
    await page.goto('/downtimes');
    await page.getByText(/Essa Semana/i).first().click();
    await expect(page.getByText(/Tempo executando/i).first()).toBeVisible({ timeout: 25_000 });
    await page.waitForTimeout(3000);
    const pcts = [...(await page.locator('body').innerText()).matchAll(/(-?\d+(?:\.\d+)?)%/g)].map((m) => Number(m[1]));
    expect(pcts.every((p) => p >= 0 && p <= 100), `percentages in range: ${pcts.join(',')}`).toBeTruthy();
    await shot(page, '4-downtimes-week');
  });

  test('5. Reports: pt-BR Superset dashboard, every chart loads (no CSRF 400)', async ({ page }) => {
    const bad: string[] = [];
    page.on('response', (r) => { if (/\/api\/v1\/chart\/data/.test(r.url()) && r.status() >= 400) bad.push(`${r.status()} ${r.url()}`); });
    await login(page);
    await page.goto('/reports');
    const frame = page.frameLocator('iframe').first();
    await expect(frame.getByText(/Visão Geral de OEE/i).first()).toBeVisible({ timeout: 40_000 });
    await page.waitForTimeout(8000);
    expect(bad, 'chart data requests failing').toEqual([]);
    await expect(frame.getByText(/CSRF|Unexpected error/i)).toHaveCount(0);
    await shot(page, '5-reports');
  });

  test('6. Operator: Bispharma user logs in and sees its lines (no writes)', async ({ page }) => {
    await operatorLogin(page, OPERATOR, USER, PASS);
    await expect(page.locator('body')).toContainText(/L0\d|L1\d|L5\d|L7\d|BISNAGO|LINHAS/i, { timeout: 30_000 });
    await shot(page, '6-operator');
  });

  test('7. Justify dialog: machine → pt-BR category → subcategory, EDITAR enabled (cancelled, no write)', async ({ page }) => {
    // Found 2026-09-24: ent5 had NO equipments.downtime_reasons JSON → empty dropdowns → no
    // stop could be justified (t-ent5-downtime-reasons-json). The save itself was proven once
    // via POST /api/downtimes/justify (200, reverted). This check never saves.
    await login(page);
    await page.goto('/downtimes');
    await page.getByText(/Essa Semana/i).first().click();
    await page.getByRole('menuitem', { name: 'Editar', exact: true }).first().click({ timeout: 30_000 });
    const dlg = page.getByRole('dialog').first();
    const pick = async (i: number) => {
      await dlg.getByRole('combobox').nth(i).click();
      const n = await page.getByRole('option').count();
      if (n) await page.getByRole('option').nth(n > 1 ? 1 : 0).click();
      return n;
    };
    expect(await pick(0), 'machines').toBeGreaterThan(0);
    await pick(1);
    await expect(dlg.getByRole('combobox').nth(1)).toHaveValue(/Falha|Parada|Problema|Ociosidade|Troca/);
    await pick(2);
    await expect(dlg.getByRole('button', { name: /editar/i })).toBeEnabled();
    await shot(page, '7-justify-dialog');
    await dlg.getByRole('button', { name: /cancelar/i }).click();
  });
});
