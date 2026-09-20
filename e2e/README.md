# packiot-e2e — cross-frontend Playwright suite

One Playwright project per deployed SPA (**front4, operator, csadmin, customize**),
run against **staging**. Chosen over Cypress: native headless (no xvfb), multi-browser,
one suite for all apps, `storageState` auth reuse, trace viewer.

## Setup
```bash
cd e2e
npm install
npm run install:browsers      # playwright install chromium (bundled, no system Chrome)
cp .env.example .env          # fill URLs + test creds (gitignored)
```

## Run
```bash
npm test                      # all four apps, headless
npm run test:front4           # one app
npm run report                # open the HTML report / trace viewer
```
Headless by default — works in CI and on a display-less box (unlike Cypress).

## What each project covers
- **front4** — Cognito form login (`front4Login`), asserts the app shell renders
  (not `/login`); optional **cpack (ent 3)** data assertion when `CPACK_*` creds
  are set (super-admin switch → OEE tiles).
- **operator** — smoke (gate reachable) + login scaffold (fill in the post-login
  assertion for a stable line/PO selector).
- **csadmin** — oauth2-proxy/Cognito gate smoke + login scaffold.
- **customize** — SPA serves + `index.html` is `no-store` (the stale-SPA fix).

## Auth model
`fixtures/auth.ts` fills each SPA's Cognito form (front4 has its own form; the
`*.staging.packiot.app` apps go via oauth2-proxy → Cognito hosted UI). For faster
runs, add a `globalSetup` that logs in once and saves `storageState` per app/tenant.

## Creds
Use throwaway staging Cognito users. For the **cpack** assertion, either a
super_user (dev@packiot.com, via the #18 enterprise switcher) or a dedicated
ent-3 user. Never commit real credentials — `.env` is gitignored.
