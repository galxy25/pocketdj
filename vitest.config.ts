import { defineConfig } from 'vitest/config';

// PocketDJ unit tests (Vitest).
// - environment 'node': the modules under test are pure (parsers, engines, id
//   helpers). No DOM is needed; jsdom would only slow the suite down.
// - globals enabled so describe/it/expect are available without imports,
//   though importing them from 'vitest' is also supported and preferred.
// - Playwright e2e specs live in tests/e2e and are explicitly excluded so they
//   are never picked up by `vitest run`.
export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    // No unit tests exist yet; don't fail CI/`npm test` until they're added.
    passWithNoTests: true,
    include: [
      // Co-located app/source unit tests.
      'src/**/*.test.ts',
      // Standalone unit tests (app + indexer). .mjs is allowed so the existing
      // indexer parser test can live here without renaming.
      'tests/unit/**/*.test.{ts,mjs}',
    ],
    exclude: [
      'node_modules/**',
      'dist/**',
      // Playwright e2e — owned by playwright.config.ts, never run under Vitest.
      'tests/e2e/**',
    ],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html'],
      include: ['src/**', '.claude/skills/analog-indexer/lib/**'],
    },
  },
});
