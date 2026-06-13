---
name: test
description: Run PocketDJ's Playwright e2e tests and produce proof-of-verification artifacts. Use when asked to "test the app", "run e2e tests", "verify the app", or to confirm a feature works end-to-end. Covers running all/single specs, headed mode, and the transcript+screenshot proof convention.
---

# Test PocketDJ (Playwright e2e)

Tests are Playwright + **Chromium only** (per project spec). Specs live in
`tests/e2e/*.spec.ts`. The dev server is auto-started/reused by Playwright.

## First-time setup

Install the Chromium browser once per machine:

```bash
npx playwright install chromium
```

## Run the tests

```bash
npm run test:e2e            # playwright test  (all specs, Chromium)
npm run test:e2e:headed    # same, but shows the browser
```

The dev server is handled by `playwright.config.ts` (`webServer`): it runs
`npm run dev` at `http://localhost:5173` and `reuseExistingServer: true`, so an
already-running dev server is reused and you don't need to start one yourself.
Tests run serially (`workers: 1`, `fullyParallel: false`).

## Run a single spec / test

```bash
npx playwright test tests/e2e/starmap.spec.ts          # one file
npx playwright test tests/e2e/starmap.spec.ts --headed # watch it run
npx playwright test -g "filter"                        # by test title
```

The HTML report is written to `playwright-report/` (open with
`npx playwright show-report`). Traces are captured on first retry.

## Proof-of-verification convention (required for every new feature)

Each feature test writes proof artifacts to `tests/e2e/proof/<feature>/`:

```
tests/e2e/proof/<feature>/
  api-transcript.log   # captured PDJ_API console lines (the "API transcript")
  screenshot.png       # visual proof of the resulting UI state
```

PocketDJ's only backend is the client: every storage/data op logs ONE greppable
line `PDJ_API {"t":…,"op":"…",…}` (see `src/lib/log.ts`). A test proves a feature
by driving the app, capturing those `PDJ_API` lines into `api-transcript.log`,
asserting the expected ops appear (e.g. `import.index`, `db.bulkPutItems`,
`filter.apply`, `starmap.layout`), and saving a `screenshot.png`. The transcript
shows the data ops actually happened; the screenshot shows the UI rendered them.

When you add a feature, add/extend a spec that produces both artifacts under a new
`tests/e2e/proof/<feature>/` directory. Existing examples: `load-index`,
`filter-eq`, `filter-in`, `filter-between-year`, `export-import`, `edit-persist`,
`starmap`, `solar-system`.
