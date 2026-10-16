# Testing: monitoring E2E data + code coverage

## Monitoring / inspecting E2E data

The Playwright suite records rich per-test artifacts so you can see exactly what
each test did and what data it saw.

| Want | Command |
|------|---------|
| Run + capture a trace for **every** test (all requests/responses/DOM/console) | `PW_TRACE=on npm test` (or `npm run test:trace`) |
| Run normally — trace kept only for **failures** (default) | `npm test` |
| Open the HTML report (results, screenshots, videos, trace links) | `npm run report` |
| Open a specific trace file in the viewer | `npm run trace -- path/to/trace.zip` |

The **trace viewer** is the tool for "check the data from the E2E tests": it
shows every network request + **response body**, the DOM snapshot at each step,
console logs, and a timeline. `PW_TRACE` accepts `on` / `off` /
`retain-on-failure` / `on-first-retry` (see `playwright.config.ts`).

Artifacts land in `playwright-report/` and `test-results/`. In CI, upload those
dirs as artifacts (and optionally push to a hosted dashboard like Currents.dev
or an Allure report) for run-over-run history.

## Code coverage

Per package (each has its own runner):

| Package | Command | Tool |
|---------|---------|------|
| **edge-api** (jest) | `npm run test:cov` | jest `--coverage` (built in) |
| **front4** (vitest) | `npm run test:coverage` | `@vitest/coverage-v8` |
| **csadmin / customize** (vitest) | `npx vitest run --coverage` | vitest coverage |

Coverage reports write to each package's `coverage/` (lcov + HTML). Open
`coverage/index.html`, or upload the `lcov.info` to **Codecov**/**Coveralls**
for PR comments + trend history.

### E2E → app coverage (which app code the browser tests exercised)

Playwright can collect V8 coverage from Chromium during a run and merge it into
an istanbul report. The lightweight path: wrap tests with
[`monocart-coverage-reports`](https://github.com/cenfun/monocart-coverage-reports)
(or `playwright-test-coverage`), calling `page.coverage.startJSCoverage()` /
`stopJSCoverage()` around navigation and feeding the entries to the reporter.
This answers "did the greyed-timeline path get exercised by E2E?" — distinct
from the unit coverage above. Not wired by default (adds runtime + needs source
maps from each SPA build); enable per-app when you want that signal.
