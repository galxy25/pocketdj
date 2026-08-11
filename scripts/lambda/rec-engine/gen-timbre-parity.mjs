#!/usr/bin/env node
// Generate the CLOUD/DEVICE TIMBRE PARITY FIXTURE — apple/Tests/Fixtures/timbre-parity.json.
//
// The timbre math ships twice (SimilarityFamilies on device, index.mjs in the Lambda) and the two
// MUST agree to float precision, or the local tile and the cloud tile quietly disagree about what
// a crate sounds like — the parallel-identity-check bug this repo has been bitten by before, on
// the similarity axis. This fixture is the law both sides are held to:
//
//   · generated HERE, through the Lambda's own exported functions (no third implementation);
//   · replayed by `test-rec-engine.mjs` (self-check: regeneration drift fails the Node suite);
//   · replayed by `TimbreParityTests.swift` (the device must match every value to 1e-9).
//
// Deterministic: a fixed-seed LCG, so re-running produces byte-identical cases (only a REAL
// change to the math changes the file — and then BOTH suites say so).
//
//   node scripts/lambda/rec-engine/gen-timbre-parity.mjs
import { writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { timbreDistance, timbreProfile, timbreFit, timbreNetFit, timbreAdjectives } from './index.mjs';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const OUT = join(REPO, 'apple', 'Tests', 'Fixtures', 'timbre-parity.json');

const AXES = ['bright', 'brightVar', 'air', 'width', 'noisy', 'fizz', 'punch', 'busy',
              'dynamic', 'loud', 'm1', 'm2', 'm3', 'm4'];

let seed = 0x5eed;
const rand = () => {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  return seed / 0x7fffffff;
};

/// A vector with `n` axes populated (drawn in canonical order), values rounded to 4dp like the
/// real corpus. `n < 8` exercises the too-few-shared-axes path.
function vector(n = 14) {
  const v = {};
  const axes = [...AXES];
  for (let i = 0; i < n && axes.length; i++) {
    const idx = Math.floor(rand() * axes.length);
    v[axes.splice(idx, 1)[0]] = Math.round(rand() * 10000) / 10000;
  }
  return v;
}

const distances = [];
for (let i = 0; i < 60; i++) {
  const axesA = i % 5 === 0 ? 6 : (i % 3 === 0 ? 10 : 14);   // some sparse, some partial
  const a = vector(axesA);
  const b = vector(i % 4 === 0 ? 10 : 14);
  distances.push({ a, b, d: timbreDistance(a, b) });
}

const profiles = [];
for (let i = 0; i < 24; i++) {
  const count = i % 6 === 0 ? 2 : 3 + (i % 5);               // some below the liveness bar
  const members = [];
  for (let j = 0; j < count; j++) {
    members.push({ f: vector(j === 0 && i % 7 === 0 ? 6 : 14), w: Math.round(rand() * 300) / 100 + 0.01 });
  }
  const minVectors = i % 8 === 0 ? 1 : 3;
  const p = timbreProfile(members, minVectors);
  const probe = vector(14);
  const neg = i % 3 === 0 ? timbreProfile([{ f: vector(14), w: 1 }], 1) : null;
  profiles.push({
    members, minVectors, probe,
    negativeMembers: neg ? null : undefined,   // placeholder; the real negative is below
    negative: i % 3 === 0 ? { members: [{ f: vector(14), w: 1 }] } : null,
    profile: p,
    fit: p ? timbreFit(probe, p) : null,
    netFit: null,   // filled below when a negative exists
    adjectives: p ? timbreAdjectives(p.centroid) : null,
  });
}
// Net fits with real negatives, computed through the exported function.
for (const c of profiles) {
  if (!c.profile || !c.negative) continue;
  const negP = timbreProfile(c.negative.members, 1);
  c.negative.profile = negP;
  c.netFit = timbreNetFit(c.probe, c.profile, negP);
}
for (const c of profiles) delete c.negativeMembers;

// Adjective table edge cases: exactly-on-threshold and tie-breaking.
const adjectiveCases = [
  { centroid: { punch: 0.65, bright: 0.35, busy: 0.5 }, words: null },
  { centroid: { punch: 0.649, bright: 0.9, dynamic: 0.1, loud: 0.8, noisy: 0.2, air: 0.9 }, words: null },
  { centroid: { punch: 0.8, bright: 0.2, busy: 0.8, dynamic: 0.8, loud: 0.2 }, words: null },
  { centroid: { m1: 0.99, m2: 0.01, brightVar: 0.99, width: 0.01 }, words: null },   // unnamed axes never speak
];
for (const c of adjectiveCases) c.words = timbreAdjectives(c.centroid);

const doc = { v: 1, generator: 'scripts/lambda/rec-engine/gen-timbre-parity.mjs',
              distances, profiles, adjectiveCases };
writeFileSync(OUT, JSON.stringify(doc, null, 1));
console.log(`wrote ${OUT} — ${distances.length} distances, ${profiles.length} profiles, ${adjectiveCases.length} adjective cases`);
