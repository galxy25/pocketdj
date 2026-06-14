#!/usr/bin/env node
// Golden assertions for the deterministic filename parser. Run: node parser.test.mjs
import { parseLine, isVinylLine, splitCamel, parseFile } from './parser.js';
import { albumId, songId } from './ids.js';

let pass = 0;
let fail = 0;
function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { pass++; }
  else { fail++; console.error(`FAIL ${label}\n  expected ${e}\n  actual   ${a}`); }
}

// --- CamelCase splitting ---
eq(splitCamel('ABBAGreatestHits'), 'ABBA Greatest Hits', 'splitCamel acronym');
eq(splitCamel('TheBrothersJohnsonLightUpTheNight'), 'The Brothers Johnson Light Up The Night', 'splitCamel words');
eq(splitCamel('EvelynChampagneKingSmoothTalk'), 'Evelyn Champagne King Smooth Talk', 'splitCamel names');
eq(splitCamel("BobbyWomackIDon'tKnowWhatTheWorldIsComingTo"),
   "Bobby Womack I Don't Know What The World Is Coming To", 'splitCamel apostrophe+pronoun');
eq(splitCamel('ABBRARose'), 'ABBRA Rose', 'splitCamel acronym2');

// --- full parse: marker + dedup + ext ---
const a = parseLine('ABBAGreatestHitsRaw.mp3');
eq(a.spacedBlob, 'ABBA Greatest Hits', 'parse spacedBlob');
eq(a.fileType, 'mp3', 'parse fileType');
eq(a.dupIndex, null, 'parse dupIndex none');

const dup1 = parseLine('TheBrothersJohnsonLightUpTheNightRaw 2.mp3');
eq(dup1.dupIndex, 2, 'parse dupIndex "Raw 2"');
eq(dup1.spacedBlob, 'The Brothers Johnson Light Up The Night', 'parse dup spaced (no digit in name)');

const dup2 = parseLine('EvelynChampagneKingSmoothTalkRaw2.mp3');
eq(dup2.dupIndex, 2, 'parse dupIndex "Raw2"');
eq(dup2.spacedBlob, 'Evelyn Champagne King Smooth Talk', 'parse dup2 spaced');

const amp = parseLine('FaithHope&CharityRaw 2.mp3');
eq(amp.spacedBlob, 'Faith Hope & Charity', 'parse ampersand kept');
eq(amp.dupIndex, 2, 'parse ampersand dup');

const raws = parseLine('VariousArtistsDanceOfTheBlessedSpiritsRaws.mp3');
eq(raws.spacedBlob, 'Various Artists Dance Of The Blessed Spirits', 'parse "Raws" typo stripped');

const aiff = parseLine('AaliyahOneInAMillionRaw.aiff');
eq(aiff.fileType, 'aiff', 'parse aiff ext');
eq(aiff.spacedBlob, 'Aaliyah One In A Million', 'parse aiff spaced');

// --- non-vinyl lines are skipped (no "Raw") ---
eq(isVinylLine('IceIceBaby.aiff'), false, 'gate non-vinyl IceIceBaby');
eq(isVinylLine('SangoNorth.aiff'), false, 'gate non-vinyl SangoNorth');
eq(isVinylLine('RasAKassGhettoFabulous.mp3'), false, 'gate non-vinyl RasAKass');
eq(isVinylLine('# Vinyl'), false, 'gate header line');
eq(parseLine('IceIceBaby.aiff'), null, 'parseLine null for non-vinyl');

// --- "Raw" must never leak into the lookup blob ---
for (const line of ['ABBAGreatestHitsRaw.mp3', 'ConFunkShun7Raw.mp3', 'VariousArtistsDanceOfTheBlessedSpiritsRaws.mp3']) {
  const c = parseLine(line);
  eq(/raw/i.test(c.spacedBlob), false, `no "raw" in blob: ${line}`);
}

// --- duplicate pressings get DISTINCT ids via dupIndex ---
const idA = albumId('The Brothers Johnson', 'Light Up The Night', null);
const idB = albumId('The Brothers Johnson', 'Light Up The Night', 2);
eq(idA !== idB, true, 'dup pressings -> distinct album ids');
eq(albumId('The Brothers Johnson', 'Light Up The Night', null) === idA, true, 'album id stable');
eq(songId(idA, 1, 1).startsWith('sng_'), true, 'song id prefix');

// --- file parse end to end on the fixture ---
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const here = dirname(fileURLToPath(import.meta.url));
const fix = readFileSync(join(here, '..', 'fixtures', 'sample-lines.txt'), 'utf8');
const { candidates, skipped } = parseFile(fix);
eq(candidates.length, 10, 'fixture vinyl count');
eq(skipped.length, 3, 'fixture skipped count');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
