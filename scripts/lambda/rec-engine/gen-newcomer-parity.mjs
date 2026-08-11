#!/usr/bin/env node
// Generate the CLOUD/DEVICE NEWCOMER-FLOOR PARITY FIXTURE — apple/Tests/Fixtures/newcomer-parity.json.
//
// The owner's 50% incumbent cap ships twice: `RecComposition.compose` +
// `RecVersionIdentity.creditArtistKeys` on the device, `composeIncumbentCap` +
// `creditArtistKeys` in the Lambda. The two MUST agree — a compose that seats one extra
// incumbent on one side, or a credit split that reads "Dinner Party, Terrace Martin…" as one
// artist on one side only, silently gives the two surfaces different floors. This fixture is the
// law both sides are held to, exactly the timbre-parity arrangement:
//
//   · generated HERE, through the Lambda's own exports (no third implementation);
//   · replayed by `test-rec-engine.mjs` (self-check: regeneration drift fails the Node suite);
//   · replayed by `NewcomerParityTests.swift` (the device must match every list and key exactly).
//
// Deterministic: a fixed-seed LCG, so re-running produces byte-identical cases.
//
//   node scripts/lambda/rec-engine/gen-newcomer-parity.mjs
import { writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { creditArtistKeys, composeIncumbentCap } from './index.mjs';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const OUT = join(REPO, 'apple', 'Tests', 'Fixtures', 'newcomer-parity.json');

let seed = 0x50f7;
const rand = () => {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  return seed / 0x7fffffff;
};
const pick = (arr) => arr[Math.floor(rand() * arr.length)];

// ── The credit split — real-shaped credits, including every known trap ──────────────────────────
const CREDITS = [
  'Drake',
  'Drake & Future',
  'Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington',
  'Terrace Martin',
  'Tyler, The Creator',
  'Earth, Wind & Fire',
  'Simon and Garfunkel',
  '[IVY] & XIRA',
  'Beyoncé',
  'The Weeknd',
  'JAY-Z / Kanye West',
  'Silk Sonic (Bruno Mars & Anderson .Paak)',
  'DJ Khaled feat. Drake',
  'Sade (feat. Sweetback)',
  'KAYTRANADA x Kali Uchis',
  'Run–DMC vs Aerosmith',
  'A Tribe Called Quest with Busta Rhymes',
  'Bandit',                        // " and " must not split a name mid-word
  'Fetty Wap',                     // "with"-shaped middle must not split
  'Xavier',                        // " x " must not split
  'A; B; C',
  'One, Two, Three, Four, Five, Six, Seven, Eight, Nine, Ten, Eleven, Twelve, Thirteen, Fourteen',
  'the pharcyde',
  '',
];
const credits = CREDITS.map((raw) => ({ raw, keys: creditArtistKeys(raw) }));

// ── The compose — randomized ranked lists over every knob ───────────────────────────────────────
const compositions = [];
for (let i = 0; i < 48; i++) {
  const count = 1 + Math.floor(rand() * 30);
  const artists = ['a', 'b', 'c', 'd', 'e', 'f', 'g'].slice(0, 2 + Math.floor(rand() * 5));
  const rows = [];
  for (let j = 0; j < count; j++) {
    rows.push({
      id: `r${String(j).padStart(2, '0')}`,
      capKey: rand() < 0.1 ? '' : pick(artists),
      isIncumbent: rand() < pick([0.2, 0.5, 0.8, 1.0]),
    });
  }
  const limit = pick([5, 10, 25, 3, 1]);
  const maxPerArtist = pick([null, 2, 3, 1]);
  const incumbentMaxShare = pick([0.5, 0.5, 0.5, 0.34, 0, 1]);
  const out = composeIncumbentCap(rows, {
    limit, maxPerArtist: maxPerArtist ?? Infinity, incumbentMaxShare,
  }).map((r) => r.id);
  compositions.push({ rows, limit, maxPerArtist, incumbentMaxShare, out });
}

// Hand-written cases pinning the properties the tests narrate:
// an all-incumbent head with newcomers below (the pull-up), a dry newcomer pool (fail open),
// an odd-count rounding case, and an already-under-the-cap list (must pass through untouched).
const R = (id, capKey, inc) => ({ id, capKey, isIncumbent: inc });
const hand = [
  { rows: [R('i1', 'a', true), R('i2', 'b', true), R('i3', 'c', true),
           R('n1', 'd', false), R('n2', 'e', false), R('n3', 'f', false)],
    limit: 4, maxPerArtist: 3, incumbentMaxShare: 0.5 },
  { rows: [R('i1', 'a', true), R('i2', 'b', true), R('i3', 'c', true)],
    limit: 5, maxPerArtist: 3, incumbentMaxShare: 0.5 },
  { rows: [R('i1', 'a', true), R('n1', 'b', false), R('i2', 'c', true),
           R('n2', 'd', false), R('i3', 'e', true)],
    limit: 5, maxPerArtist: 3, incumbentMaxShare: 0.5 },
  { rows: [R('n1', 'a', false), R('i1', 'b', true), R('n2', 'c', false),
           R('n3', 'd', false), R('n4', 'e', false)],
    limit: 5, maxPerArtist: 3, incumbentMaxShare: 0.5 },
];
for (const h of hand) {
  compositions.push({ ...h,
    out: composeIncumbentCap(h.rows, { limit: h.limit,
                                       maxPerArtist: h.maxPerArtist ?? Infinity,
                                       incumbentMaxShare: h.incumbentMaxShare })
      .map((r) => r.id) });
}

const doc = { v: 1, credits, compositions };
writeFileSync(OUT, `${JSON.stringify(doc, null, 1)}\n`);
console.log(`wrote ${OUT}: ${credits.length} credit cases, ${compositions.length} compositions`);
