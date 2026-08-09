#!/usr/bin/env node
// Self-test for the lookup-route matcher (scripts/lib/explicit-lookup.mjs).
// No deps, no network:  node scripts/test-explicit-lookup.mjs
// Exits non-zero on any failure.
import { pickSiblingAlbum, pickTrackInAlbum, albumRow, trackRow } from './lib/explicit-lookup.mjs';

let failures = 0;
function eq(actual, expected, label) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { console.log(`  ✓ ${label}`); return; }
  failures++;
  console.error(`  ✗ ${label}\n      expected ${e}\n      actual   ${a}`);
}

// ---------------- albumRow / trackRow ----------------
console.log('row normalizers');
eq(albumRow({ collectionId: 1, collectionName: 'DAMN.', collectionExplicitness: 'explicit' }),
   { id: 1, name: 'DAMN.', cls: 'explicit' }, 'explicit album row');
eq(albumRow({ collectionId: 2, collectionName: 'DAMN.', collectionExplicitness: 'cleaned' }),
   { id: 2, name: 'DAMN.', cls: 'clean' }, "'cleaned' album -> clean");
eq(trackRow({ trackId: 9, trackName: 'HUMBLE.', trackTimeMillis: 177000, trackExplicitness: 'explicit' }),
   { id: 9, name: 'HUMBLE.', ms: 177000, cls: 'explicit' }, 'explicit track row');

// ---------------- pickSiblingAlbum ----------------
console.log('pickSiblingAlbum');
const cat = [
  { id: 'c1', name: 'DAMN.', cls: 'clean' },
  { id: 'e1', name: 'DAMN.', cls: 'explicit' },
  { id: 'e2', name: 'To Pimp a Butterfly', cls: 'explicit' },
  { id: 'e3', name: 'DAMN. COLLECTORS EDITION.', cls: 'explicit' },
];
eq(pickSiblingAlbum(cat, 'explicit', 'DAMN.'), 'e1', 'finds the explicit edition of the same album');
eq(pickSiblingAlbum(cat, 'clean', 'DAMN.'), 'c1', 'finds the clean edition too (same machinery)');
eq(pickSiblingAlbum(cat, 'explicit', 'DAMN. (Clean)'), 'e1',
   'a cosmetic "(Clean)" parenthetical still matches its explicit sibling');
eq(pickSiblingAlbum(cat, 'explicit', 'Mr. Morale'), null, 'no match -> null, never a guess');
eq(pickSiblingAlbum(cat, 'explicit', '', 'To Pimp a Butterfly'), 'e2',
   'falls back to the storefront collectionName when the index album name is blank');
eq(pickSiblingAlbum(cat, 'explicit', null, null), null, 'no usable title -> null');
eq(pickSiblingAlbum([], 'explicit', 'DAMN.'), null, 'empty catalog -> null');
// A COLLECTORS EDITION is a different release and must not stand in for the album.
eq(pickSiblingAlbum([{ id: 'x', name: 'DAMN. COLLECTORS EDITION.', cls: 'explicit' }], 'explicit', 'DAMN.'),
   null, 'a differently-titled reissue is not a sibling');

// ---------------- pickTrackInAlbum ----------------
console.log('pickTrackInAlbum');
const song = { name: 'HUMBLE.', length: 177000 };
const tracks = [
  { id: 't1', name: 'DNA.', ms: 185000, cls: 'explicit' },
  { id: 't2', name: 'HUMBLE.', ms: 177000, cls: 'explicit' },
  { id: 't3', name: 'HUMBLE.', ms: 177000, cls: 'clean' },
];
eq(pickTrackInAlbum(song, tracks, 'explicit'), 't2', 'matches title + duration in the right class');
eq(pickTrackInAlbum(song, tracks, 'clean'), 't3', 'class is respected');
eq(pickTrackInAlbum({ name: 'HUMBLE.', length: 177000 },
   [{ id: 'r', name: 'HUMBLE. (Remix)', ms: 177000, cls: 'explicit' }], 'explicit'),
   null, 'a remix is a different recording — tight matching holds');
eq(pickTrackInAlbum({ name: 'HUMBLE.', length: 177000 },
   [{ id: 'f', name: 'HUMBLE.', ms: 210000, cls: 'explicit' }], 'explicit'),
   null, 'duration beyond 7s -> reject');
eq(pickTrackInAlbum({ name: 'HUMBLE.', length: 177000 },
   [{ id: 'u', name: 'HUMBLE.', ms: 0, cls: 'explicit' }], 'explicit'),
   null, 'unknown duration is rejected, not assumed');
eq(pickTrackInAlbum({ name: 'HUMBLE.', length: 0 }, tracks, 'explicit'),
   null, 'unknown song length is rejected, not assumed');
eq(pickTrackInAlbum({ name: 'HUMBLE.', length: 177000 }, [
   { id: 'near', name: 'HUMBLE.', ms: 180000, cls: 'explicit' },
   { id: 'exact', name: 'HUMBLE.', ms: 177000, cls: 'explicit' },
 ], 'explicit'), 'exact', 'ties break toward the closest duration');
eq(pickTrackInAlbum(song, [], 'explicit'), null, 'empty track list -> null');

console.log(failures ? `\n${failures} FAILED` : '\nall passed');
process.exit(failures ? 1 : 0);
