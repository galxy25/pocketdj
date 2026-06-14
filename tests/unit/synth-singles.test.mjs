// Integration test for synth-singles.mjs. The module is a runnable script (acts
// on process.argv at import), so we run it as a child process against a temp
// shard dir fixture and assert the rewritten enriched.jsonl + the dropped
// downstream records.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { execFileSync } from 'node:child_process';
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
  readFileSync,
  existsSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const SCRIPT = join(
  here,
  '..',
  '..',
  '.claude',
  'skills',
  'analog-indexer',
  'lib',
  'synth-singles.mjs',
);

let dir;
const path = (name) => join(dir, name);
const writeJsonl = (name, recs) =>
  writeFileSync(path(name), recs.map((r) => JSON.stringify(r)).join('\n') + (recs.length ? '\n' : ''));
const readJsonl = (name) =>
  existsSync(path(name))
    ? readFileSync(path(name), 'utf8')
        .split('\n')
        .map((l) => l.trim())
        .filter(Boolean)
        .map((l) => JSON.parse(l))
    : [];

// Run the script; it exits 0 even on "nothing to do". Returns stderr text.
function run() {
  try {
    return execFileSync('node', [SCRIPT, '--dir', dir], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    // some "nothing to convert" paths exit 0; surface real failures
    if (e.stdout || e.stderr) return (e.stdout || '') + (e.stderr || '');
    throw e;
  }
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'pdj-synth-'));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe('synth-singles', () => {
  it('converts a still-unmatched record into a one-track "<name> Single" album', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'unmatched', artist: 'Some DJ', name: 'Hot Track', tracks: [] },
      { candidateIndex: 1, status: 'matched', artist: 'ABBA', name: 'Greatest Hits', tracks: [{ trackNumber: 1, name: 'SOS' }] },
    ]);
    run();
    const out = readJsonl('enriched.jsonl');
    const single = out.find((r) => r.candidateIndex === 0);
    expect(single.status).toBe('matched');
    expect(single.matchConfidence).toBe('single');
    expect(single.name).toBe('Hot Track Single');
    expect(single.sources).toContain('single-synth');
    expect(single.tracks).toHaveLength(1);
    expect(single.tracks[0]).toMatchObject({
      discNumber: 1,
      trackNumber: 1,
      name: 'Hot Track',
      artist: 'Some DJ',
      lyricsStatus: 'notfound',
    });
    // the already-matched album is untouched
    const kept = out.find((r) => r.candidateIndex === 1);
    expect(kept.status).toBe('matched');
    expect(kept.matchConfidence).toBeUndefined();
  });

  it('does not double-append "Single" when the name already contains it', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'unmatched', artist: 'DJ', name: 'My Cool Single', tracks: [] },
    ]);
    run();
    const single = readJsonl('enriched.jsonl')[0];
    expect(single.name).toBe('My Cool Single');
  });

  it('falls back to the artist (then "Untitled") when name is blank', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'unmatched', artist: 'Lonely Artist', name: '', tracks: [] },
      { candidateIndex: 1, status: 'unmatched', artist: '', name: '', tracks: [] },
    ]);
    run();
    const out = readJsonl('enriched.jsonl');
    expect(out.find((r) => r.candidateIndex === 0).name).toBe('Lonely Artist Single');
    expect(out.find((r) => r.candidateIndex === 1).name).toBe('Untitled Single');
  });

  it('does NOT convert an album recovered by web/google backfill', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'unmatched', artist: 'X', name: 'Recovered Elsewhere', tracks: [] },
    ]);
    writeJsonl('web.jsonl', [
      { candidateIndex: 0, status: 'matched', artist: 'Real', name: 'Real Album', tracks: [{ trackNumber: 1, name: 't' }] },
    ]);
    run();
    const out = readJsonl('enriched.jsonl');
    // unchanged: still unmatched in enriched.jsonl (the recovery owns it downstream)
    expect(out[0].status).toBe('unmatched');
    expect(out[0].sources || []).not.toContain('single-synth');
  });

  it('is idempotent — a second run does not re-convert or double-suffix', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'unmatched', artist: 'DJ', name: 'Hot Track', tracks: [] },
    ]);
    run();
    const afterFirst = readJsonl('enriched.jsonl');
    run(); // second run: no still-unmatched left -> no-op
    const afterSecond = readJsonl('enriched.jsonl');
    expect(afterSecond).toEqual(afterFirst);
    expect(afterSecond[0].name).toBe('Hot Track Single');
    expect(afterSecond[0].sources.filter((s) => s === 'single-synth')).toHaveLength(1);
  });

  it('drops converted candidateIndexes from lyrics.jsonl and sentiment.jsonl', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'unmatched', artist: 'DJ', name: 'Hot Track', tracks: [] },
      { candidateIndex: 1, status: 'matched', artist: 'ABBA', name: 'GH', tracks: [{ trackNumber: 1, name: 'x' }] },
    ]);
    writeJsonl('lyrics.jsonl', [
      { candidateIndex: 0, status: 'unmatched', tracks: [] },
      { candidateIndex: 1, status: 'matched', tracks: [{ trackNumber: 1, name: 'x', lyricsStatus: 'found' }] },
    ]);
    writeJsonl('sentiment.jsonl', [
      { candidateIndex: 0, status: 'unmatched', tracks: [] },
      { candidateIndex: 1, status: 'matched', tracks: [{ trackNumber: 1, name: 'x', sentimentKeywords: ['joy'] }] },
    ]);
    run();
    // ci 0 dropped (will be re-processed), ci 1 kept
    expect(readJsonl('lyrics.jsonl').map((r) => r.candidateIndex)).toEqual([1]);
    expect(readJsonl('sentiment.jsonl').map((r) => r.candidateIndex)).toEqual([1]);
  });

  it('backs up enriched.jsonl before rewriting', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'unmatched', artist: 'DJ', name: 'Hot Track', tracks: [] },
    ]);
    run();
    expect(existsSync(path('enriched.jsonl.bak'))).toBe(true);
    const bak = readFileSync(path('enriched.jsonl.bak'), 'utf8');
    expect(bak).toContain('"status":"unmatched"');
  });

  it('makes no changes when there are no still-unmatched albums', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'matched', artist: 'ABBA', name: 'GH', tracks: [{ trackNumber: 1, name: 'x' }] },
    ]);
    run();
    // no .bak written, enriched untouched
    expect(existsSync(path('enriched.jsonl.bak'))).toBe(false);
    expect(readJsonl('enriched.jsonl')[0].status).toBe('matched');
  });
});
