// Shared e2e helpers: load the deterministic fixture, capture the PDJ_API console
// "API transcript", and write proof-of-verification artifacts (transcript + screenshot).
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Page } from '@playwright/test';

// Paths are resolved from the project root (Playwright's cwd), which avoids
// __dirname/import.meta differences between CJS and ESM.
const ROOT = process.cwd();
export const FIXTURE = JSON.parse(
  readFileSync(join(ROOT, 'tests', 'e2e', 'fixtures', 'test-index.json'), 'utf8'),
);

export const PROOF_DIR = join(ROOT, 'tests', 'e2e', 'proof');

/** Attach a console listener that collects PDJ_API transcript lines. */
export function captureTranscript(page: Page): string[] {
  const lines: string[] = [];
  page.on('console', (msg) => {
    const t = msg.text();
    if (t.startsWith('PDJ_API ')) lines.push(t);
  });
  return lines;
}

/** Boot the app on a clean DB and load the fixture index. Returns when data is ready. */
export async function setupApp(page: Page): Promise<void> {
  await page.goto('/browse');
  await page.waitForFunction(() => !!(window as unknown as { __pdj?: unknown }).__pdj);
  await page.evaluate(async (fixture) => {
    const pdj = (window as unknown as { __pdj: { clear: () => Promise<void>; loadIndex: (i: unknown, n?: string) => Promise<unknown> } }).__pdj;
    await pdj.clear();
    await pdj.loadIndex(fixture, 'Test Vinyl');
  }, FIXTURE);
}

/** Parse the latest filter.apply transcript entry (in/out counts). */
export function lastFilterApply(lines: string[]): { in: number; out: number } | null {
  for (let i = lines.length - 1; i >= 0; i--) {
    const obj = JSON.parse(lines[i].slice('PDJ_API '.length));
    if (obj.op === 'filter.apply') return { in: obj.in, out: obj.out };
  }
  return null;
}

export function hasOp(lines: string[], op: string): boolean {
  return lines.some((l) => {
    try {
      return JSON.parse(l.slice('PDJ_API '.length)).op === op;
    } catch {
      return false;
    }
  });
}

/** Write proof artifacts for a feature: the transcript + a screenshot. */
export async function writeProof(feature: string, page: Page, transcript: string[]): Promise<void> {
  const dir = join(PROOF_DIR, feature);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'api-transcript.log'), transcript.join('\n') + '\n');
  await page.screenshot({ path: join(dir, 'screenshot.png'), fullPage: false });
}
