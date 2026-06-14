---
name: test
description: Run PocketDJ's Vitest unit tests and Playwright e2e tests, and produce proof-of-verification artifacts. Use when asked to "test the app", "run unit tests", "run e2e tests", "verify the app", or to confirm a feature works end-to-end. Covers vitest, running all/single specs, headed mode, and the PDJ_API transcript + screenshot proof convention.
---

# Test PocketDJ

PocketDJ has two test layers:

1. **Vitest unit tests** — fast, pure-module tests (no browser, no DOM).
2. **Playwright e2e tests** — drive the real app in Chromium and capture
   proof-of-verification artifacts.

## Unit tests (Vitest)

```bash
npm test           # vitest run  (alias of test:unit)
npm run test:unit  # same
npm run test:watch # vitest in watch mode
```

Config is `vitest.config.ts`: `environment: 'node'`, `globals: true`,
`passWithNoTests: true`. It includes `src/**/*.test.ts`, `tests/unit/**/*.test.{ts,mjs}`,
and **excludes `tests/e2e/**`** (those belong to Playwright, never Vitest).

The pure/unit-testable modules are:

- **App:** `src/engine/{filterEngine,sortEngine,fieldRegistry}.ts`,
  `src/lib/{format,prng,concurrency}.ts`,
  `src/starmap/{constellationMap,layout,solarSystem}.ts`.
- **Indexer:** `.claude/skills/analog-indexer/lib/{parser,normalize,itunes,merge,assemble,batching,ids}.js`
  + `manifest.mjs` (`buildFromStages`) + `synth-singles.mjs` logic.

> Note: today the only unit test wired in is the indexer parser test
> (`.claude/skills/analog-indexer/lib/parser.test.mjs`), runnable on its own via
> `npm run indexer:parser-test` and also picked up by `npm test`. Add new unit tests
> next to the module (`*.test.ts`) or under `tests/unit/`.

# Test PocketDJ end-to-end (Playwright)

E2e tests are Playwright + **Chromium only** (per project spec). Specs live in
`tests/e2e/*.spec.ts` (`browser.spec.ts`, `starmap.spec.ts`, `importexport.spec.ts`).
The dev server is auto-started/reused by Playwright.

## First-time setup

Install the Chromium browser once per machine:

```bash
npx playwright install chromium
```

## Run the e2e tests

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
asserting the expected ops appear, and saving a `screenshot.png`. The transcript
shows the data ops actually happened; the screenshot shows the UI rendered them.

The real op vocabulary (the `ApiOp` union in `src/lib/log.ts`) is: `db.open`,
`db.putSource`, `db.putItem`, `db.bulkPutItems`, `db.getItemsBySource`,
`db.getAllItems`, `db.deleteSource`, `art.cache`, `art.generate`, `import.index`,
`import.zip`, `export.zip`, `filter.apply`, `sort.apply`, `starmap.layout`,
`starmap.tier`, `mock.load`. (E.g. drilling tier-1 → tier-2 in the star map emits
`starmap.tier`; loading an index emits `import.index` + `db.bulkPutItems`.)

`tests/e2e/helpers.ts` provides the shared plumbing: `attachTranscript(page)` to
collect `PDJ_API` lines, a fixture loader that drives `window.__pdj`, op-assertion
helpers, and `writeProof(dir, page, transcript)` which writes both
`api-transcript.log` and `screenshot.png` under `PROOF_DIR` (`tests/e2e/proof`).

When you add a feature, add/extend a spec that produces both artifacts under a new
`tests/e2e/proof/<feature>/` directory. Existing examples: `load-index`,
`filter-eq`, `filter-in`, `filter-between-year`, `filter-songs`, `export-import`,
`edit-persist`, `starmap`, `starmap-two-tier`, `solar-system`, `song-detail`.
