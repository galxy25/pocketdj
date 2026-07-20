#!/usr/bin/env node
// Hermetic test of scripts/fold-cloud-lyrics.mjs: synthetic index + manifest + a local sidecar
// dir (the --sidecar-dir seam — zero network, zero aws). Asserts the candidate rules (scraped
// 'found' wins, instrumentals untouched, manifest-without-lyrics skipped), the DemuxLine-parity
// line grouping (≥1.2 s gap or 12 words), the whisper provenance stamp, and --apply in-place.
//
//   node scripts/test/fold-cloud-lyrics-test.mjs
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

const work = mkdtempSync(join(tmpdir(), 'pdj-foldlyrics-'));
const sidecars = join(work, 'sidecars');
mkdirSync(sidecars, { recursive: true });

// ---- fixtures ----
const indexPath = join(work, 'test-index.json');
writeFileSync(indexPath, JSON.stringify({
  songs: [
    { id: 'sng_aaaaaaaaaaaa', name: 'A', artist: 'X' },                              // fold me
    { id: 'sng_bbbbbbbbbbbb', name: 'B', artist: 'X', lyricsStatus: 'found' },       // scraped wins
    { id: 'sng_cccccccccccc', name: 'C', artist: 'X', lyricsStatus: 'none' },        // instrumental
    { id: 'sng_dddddddddddd', name: 'D', artist: 'X' },                              // no manifest lyrics
  ],
}));
const manifestPath = join(work, 'manifest.json');
writeFileSync(manifestPath, JSON.stringify({
  sng_aaaaaaaaaaaa: { key: 'rips/a.mp3', lyrics: 'rips/lyrics/sng_aaaaaaaaaaaa.json' },
  sng_bbbbbbbbbbbb: { key: 'rips/b.mp3', lyrics: 'rips/lyrics/sng_bbbbbbbbbbbb.json' },
  sng_cccccccccccc: { key: 'rips/c.mp3', lyrics: 'rips/lyrics/sng_cccccccccccc.json' },
  sng_dddddddddddd: { key: 'rips/d.mp3' },
}));
// 14 quick words (splits at 12) then a >1.2 s gap before two more — expect 3 lines.
const words = [];
for (let i = 0; i < 14; i++) words.push({ text: `w${i}`, startMs: i * 300, endMs: i * 300 + 200 });
words.push({ text: 'after', startMs: 14 * 300 + 2_000, endMs: 14 * 300 + 2_200 });
words.push({ text: 'gap', startMs: 14 * 300 + 2_300, endMs: 14 * 300 + 2_500 });
writeFileSync(join(sidecars, 'sng_aaaaaaaaaaaa.json'),
  JSON.stringify({ version: 1, model: 'faster-whisper-small', words }));
writeFileSync(join(sidecars, 'sng_cccccccccccc.json'),
  JSON.stringify({ version: 1, model: 'faster-whisper-small', words: [] }));

// ---- run (--apply, env seams point everything at the temp dir) ----
execFileSync('node', [join(REPO, 'scripts', 'fold-cloud-lyrics.mjs'),
  '--apply', '--manifest', manifestPath, '--sidecar-dir', sidecars], {
  env: { ...process.env, POCKETDJ_FOLD_INDEXES: indexPath, POCKETDJ_FOLD_OUT: join(work, 'out') },
  stdio: ['ignore', 'inherit', 'inherit'],
});

// ---- asserts ----
const out = JSON.parse(readFileSync(indexPath, 'utf8'));
const by = Object.fromEntries(out.songs.map((s) => [s.id, s]));
ok(by.sng_aaaaaaaaaaaa.lyricsStatus === 'found', 'candidate stamped found');
ok(by.sng_aaaaaaaaaaaa.lyricsSource === 'whisper', 'whisper provenance stamped');
ok(by.sng_bbbbbbbbbbbb.lyricsSource === undefined, "scraped 'found' song untouched");
ok(by.sng_cccccccccccc.lyricsStatus === 'none', 'instrumental (empty words) untouched');
ok(by.sng_dddddddddddd.lyricsStatus === undefined, 'song without manifest lyrics untouched');

const txt = readFileSync(join(work, 'out', 'txt', 'sng_aaaaaaaaaaaa.txt'), 'utf8');
const lines = txt.trim().split('\n');
ok(lines.length === 3, `line grouping: 12-word cap + gap split (got ${lines.length} lines)`);
ok(lines[0] === 'w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11', 'first line caps at 12 words');
ok(lines[1] === 'w12 w13', 'second line ends at the ≥1.2 s gap');
ok(lines[2] === 'after gap', 'post-gap words form the last line');

const report = JSON.parse(readFileSync(join(work, 'out', 'report.json'), 'utf8'));
const r = Object.values(report.indexes)[0];
ok(r.stamped === 1 && r.alreadyFound === 1 && r.instrumental === 1, 'report counts correct');

rmSync(work, { recursive: true, force: true });
console.log(fail ? `\n✗ ${fail} check(s) failed` : '\n✓ all fold-cloud-lyrics checks passed');
process.exit(fail ? 1 : 0);
