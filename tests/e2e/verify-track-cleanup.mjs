#!/usr/bin/env node
// Browser-verify the TRACK-CLEANUP on DEV (against the live CloudFront seed), using
// @playwright/test's chromium directly (NOT the playwright MCP). It:
//   1. boots the dev app, clears the DB, and loads the DEPLOYED current-index.json seed
//      via window.__pdj.loadIndex (so we test exactly what dev is serving),
//   2. opens each album's /album/:albumId track view and reads the rendered rows
//      (.pdj-song__track number + .pdj-song__name), and
//   3. asserts: Sade "Diamond Life" has clean 1..N numbers and NO duplicate names;
//      Isley "Between the Sheets" has ~15 DISTINCT tracks numbered 1..15.
// Writes a screenshot per album to tests/e2e/proof/track-cleanup/.
//
//   node tests/e2e/verify-track-cleanup.mjs [https://djictbz9w796r.cloudfront.net]
import { chromium } from '@playwright/test';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

const BASE = process.argv[2] || 'https://djictbz9w796r.cloudfront.net';
const PROOF = join(process.cwd(), 'tests', 'e2e', 'proof', 'track-cleanup');
mkdirSync(PROOF, { recursive: true });

const TARGETS = [
  {
    label: 'Sade — Diamond Life',
    match: (a) => /sade/i.test(a.artist) && /diamond life/i.test(a.name),
    expectNoDupNames: true,
    expectCount: null, // exact count not asserted; numbering + no-dups is the contract
  },
  {
    label: 'Isley Brothers — Between the Sheets',
    match: (a) => /isley/i.test(a.artist) && /between the sheets/i.test(a.name),
    expectNoDupNames: true,
    expectCountAround: 15,
  },
];

function fail(msg) {
  console.error('FAIL: ' + msg);
  process.exitCode = 1;
}

const browser = await chromium.launch();
const page = await browser.newPage();
page.setDefaultTimeout(45000);

try {
  console.log(`▶ dev: ${BASE}`);
  await page.goto(`${BASE}/browse`, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => !!window.__pdj, null, { timeout: 45000 });

  // Load EXACTLY the deployed seed (fetch from the same origin, then import via __pdj),
  // so verification reflects what dev is actually serving.
  const counts = await page.evaluate(async () => {
    const res = await fetch('/current-index.json', { cache: 'no-store' });
    const seed = await res.json();
    await window.__pdj.clear();
    return await window.__pdj.loadIndex(seed, 'Dev Seed');
  });
  console.log(`▶ loaded seed: ${counts.albums} albums, ${counts.songs} songs`);

  // Resolve each target's albumId from the loaded index.
  const albumIds = await page.evaluate(async () => {
    const res = await fetch('/current-index.json', { cache: 'no-store' });
    const seed = await res.json();
    return seed.albums.map((a) => ({ id: a.id, artist: a.artist, name: a.name }));
  });

  for (const t of TARGETS) {
    const found = albumIds.find((a) => t.match(a));
    if (!found) {
      fail(`${t.label}: album not found in seed`);
      continue;
    }
    await page.goto(`${BASE}/album/${found.id}`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="album-tracks"] .pdj-song', { timeout: 45000 });

    const rows = await page.$$eval('[data-testid="album-tracks"] .pdj-song', (els) =>
      els.map((el) => ({
        track: el.querySelector('.pdj-song__track')?.textContent?.trim() ?? '',
        name: el.querySelector('.pdj-song__name')?.textContent?.trim() ?? '',
        bpm: el.querySelector('.pdj-song__bpm')?.textContent?.trim() ?? '',
        key: el.querySelector('.pdj-song__keyname')?.textContent?.trim() ?? '',
      })),
    );

    console.log(`\n=== ${t.label}  (${found.id}) — ${rows.length} tracks ===`);
    for (const r of rows) console.log(`  #${r.track}  ${r.name}  [bpm ${r.bpm} key ${r.key}]`);

    await page.screenshot({
      path: join(PROOF, t.label.replace(/[^a-z0-9]+/gi, '-').toLowerCase() + '.png'),
      fullPage: true,
    });

    // --- assertions ---
    const nums = rows.map((r) => Number(r.track));
    // 1..N contiguous, ascending, no duplicates
    const expectedSeq = rows.map((_, i) => i + 1);
    const seqOk = JSON.stringify(nums) === JSON.stringify(expectedSeq);
    if (!seqOk) fail(`${t.label}: track numbers are not a clean 1..N sequence -> ${nums.join(',')}`);
    else console.log(`  ✓ numbered 1..${rows.length} (clean ascending, no dup numbers)`);

    if (t.expectNoDupNames) {
      const norm = (s) => s.toLowerCase().replace(/\s+/g, ' ').trim().replace(/[\s\p{P}]+$/u, '');
      const seen = new Map();
      for (const r of rows) seen.set(norm(r.name), (seen.get(norm(r.name)) || 0) + 1);
      const dups = [...seen.entries()].filter(([, c]) => c > 1).map(([n]) => n);
      if (dups.length) fail(`${t.label}: duplicate track NAMES remain -> ${dups.join(' | ')}`);
      else console.log(`  ✓ no duplicate track names`);
    }

    if (t.expectCountAround != null) {
      // distinct songs ~ expected (segmentation/edition tolerance: within 2)
      if (Math.abs(rows.length - t.expectCountAround) > 2) {
        fail(`${t.label}: expected ~${t.expectCountAround} tracks, got ${rows.length}`);
      } else {
        console.log(`  ✓ ~${t.expectCountAround} distinct tracks (got ${rows.length})`);
      }
    }
  }
} catch (e) {
  fail('exception: ' + (e?.stack || e));
} finally {
  await browser.close();
}

console.log(process.exitCode ? '\n✗ VERIFY FAILED' : '\n✓ VERIFY PASSED');
