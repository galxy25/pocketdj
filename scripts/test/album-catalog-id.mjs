#!/usr/bin/env node
// F7 Discover-album dedupe — the album `appleMusicId` EMISSION.
//
// The client field (IndexAlbum.appleMusicId) + the supersede join (splitAlbums) already
// exist and are tested in Swift. This asserts the missing INDEXER half:
//   • resolve-apple-music-catalog.mjs captures the album `collectionId` off the SAME
//     iTunes row that yields the song's trackId  (unit, mocked results — no network),
//   • index-apple-music.mjs aggregates per-track collectionIds into the album's
//     `appleMusicId` via a robust mode (unit + a real end-to-end index of a tiny
//     synthetic Library.xml — no real library, no S3, no network).
//
//   node scripts/test/album-catalog-id.mjs
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { mostCommonNonEmpty } from '../index-apple-music.mjs';
import { bestMatch } from '../resolve-apple-music-catalog.mjs';
import { nsFor, songIdFor } from '../lib/am-ids.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

// (a) majority collectionId wins.
{
  ok(mostCommonNonEmpty(['617154241', '617154241', '617154241']) === '617154241',
    '(a) all tracks share collectionId → album appleMusicId = "617154241"');
  ok(mostCommonNonEmpty(['617154241', '617154241', undefined]) === '617154241',
    '(a) majority with a gap still resolves to the shared id');
}

// (b) a single outlier can't hijack the album.
{
  ok(mostCommonNonEmpty(['617154241', '617154241', '999999999']) === '617154241',
    '(b) mode ignores one mistagged outlier collectionId');
  ok(mostCommonNonEmpty([999999999, 617154241, 617154241]) === '617154241',
    '(b) numeric inputs are coerced to String and still moded');
}

// (c) no track carries a collectionId → undefined (JSON.stringify omits it).
{
  ok(mostCommonNonEmpty([undefined, undefined, '']) === undefined,
    '(c) no track collectionId → album appleMusicId undefined');
  ok(mostCommonNonEmpty([]) === undefined, '(c) empty album → undefined');
}

// (d) resolve captures collectionId off a mocked iTunes row (same row as the trackId).
{
  const results = [{
    wrapperType: 'track', kind: 'song',
    trackId: 617154479,            // song adam id
    collectionId: 617154241,       // album catalog id — the join key
    trackName: 'Song A (feat. Wanz)',
    artistName: 'Macklemore',
    collectionName: 'The Heist',
  }];
  const m = bestMatch({ name: 'Song A', artist: 'Macklemore' }, 'The Heist', results);
  ok(m && m.storeId === '617154479', `(d) resolve keeps song storeId = trackId (${m && m.storeId})`);
  ok(m && m.collectionId === '617154241', `(d) resolve captures collectionId (String) (${m && m.collectionId})`);
  const noColl = bestMatch({ name: 'Song A', artist: 'Macklemore' }, 'The Heist',
    [{ trackId: 1, trackName: 'Song A', artistName: 'Macklemore', collectionName: 'The Heist' }]);
  ok(noColl && noColl.collectionId === undefined, '(d) row without collectionId → collectionId undefined');
}

// (e) END-TO-END: the REAL indexer emits album appleMusicId from a cache, and leaves it
// off for an album whose tracks resolved none (backward-compatible with old records).
{
  const work = mkdtempSync(join(tmpdir(), 'pdj-catid-'));
  const ns = nsFor('Apple Music (Local)'); // default --source-name
  const sidA = songIdFor(ns, 'AAAA1111');
  const sidB = songIdFor(ns, 'BBBB2222');
  const sidC = songIdFor(ns, 'CCCC3333');

  const xml = join(work, 'Library.xml');
  writeFileSync(xml, [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<plist version="1.0">',
    '<dict>',
    '\t<key>Major Version</key><integer>1</integer>',
    '\t<key>Tracks</key>',
    '\t<dict>',
    ...trackDict('1', 'AAAA1111', 'Song A', 'Macklemore', 'The Heist'),
    ...trackDict('2', 'BBBB2222', 'Song B', 'Macklemore', 'The Heist'),
    ...trackDict('3', 'CCCC3333', 'Song C', 'Nobody', 'Uncatalogued'),
    '\t</dict>',
    '</dict>',
    '</plist>',
    '',
  ].join('\n'));

  // Cache: A & B carry the album collectionId; C has none (an "old" record shape).
  const cache = join(work, 'cache.ndjson');
  writeFileSync(cache, [
    JSON.stringify({ id: sidA, storeId: '617154479', collectionId: '617154241' }),
    JSON.stringify({ id: sidB, storeId: '617154480', collectionId: '617154241' }),
    JSON.stringify({ id: sidC, storeId: '617154999' }), // no collectionId (legacy)
    '',
  ].join('\n'));

  const out = join(work, 'index.json');
  const r = spawnSync('node', [
    join(REPO, 'scripts/index-apple-music.mjs'),
    '--xml', xml, '--out', out, '--catalog-cache', cache,
  ], { encoding: 'utf8' });
  ok(r.status === 0, `(e) indexer exits 0 (${r.status})${r.status ? '\n' + r.stderr : ''}`);

  const idx = JSON.parse(readFileSync(out, 'utf8'));
  const heist = idx.albums.find((a) => a.name === 'The Heist');
  const uncat = idx.albums.find((a) => a.name === 'Uncatalogued');
  ok(heist && heist.appleMusicId === '617154241',
    `(e) indexed album "The Heist" gets appleMusicId="617154241" (${heist && heist.appleMusicId})`);
  ok(uncat && !('appleMusicId' in uncat),
    '(e) album with no resolved collectionId omits appleMusicId (backward-compatible)');
  // sanity: songs still carry their own adam id (unchanged behavior)
  const songA = idx.songs.find((s) => s.id === sidA);
  ok(songA && songA.appleMusicId === '617154479', '(e) song appleMusicId still = per-song storeId (unchanged)');
}

function trackDict(trackId, persistentId, name, artist, album) {
  return [
    `\t\t<key>${trackId}</key>`,
    '\t\t<dict>',
    `\t\t\t<key>Track ID</key><integer>${trackId}</integer>`,
    `\t\t\t<key>Name</key><string>${name}</string>`,
    `\t\t\t<key>Artist</key><string>${artist}</string>`,
    `\t\t\t<key>Album Artist</key><string>${artist}</string>`,
    `\t\t\t<key>Album</key><string>${album}</string>`,
    `\t\t\t<key>Persistent ID</key><string>${persistentId}</string>`,
    '\t\t</dict>',
  ];
}

console.log(fail === 0 ? '\nAlbum catalog-id: PASS' : `\nAlbum catalog-id: ${fail} FAILED`);
process.exit(fail === 0 ? 0 : 1);
