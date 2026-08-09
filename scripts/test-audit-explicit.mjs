#!/usr/bin/env node
// Self-test for scripts/audit-explicit-coverage.mjs — a synthetic index that hits EVERY
// bucket, plus an end-to-end CLI run. No deps, no network:
//   node scripts/test-audit-explicit.mjs
// Exits non-zero on any failure.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  audit, classifySong, collectionsFromDoc, findCollection, twinKey, norm, BUCKETS, REMEDIES,
} from './audit-explicit-coverage.mjs';

let failures = 0;
function eq(actual, expected, label) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { console.log(`  ✓ ${label}`); return; }
  failures++;
  console.error(`  ✗ ${label}\n      expected ${e}\n      actual   ${a}`);
}
function ok(cond, label) { eq(!!cond, true, label); }

// ────────────────────────── synthetic index ──────────────────────────
// One song per bucket, plus the two duplicate-row shapes and a few decoys.
const S = {
  resolved:   { id: 'sng_res',  artist: 'Kendrick Lamar', name: 'HUMBLE.',  albumId: 'alb_1', explicit: true,  appleMusicId: '100', appleMusicIdClean: '100', appleMusicIdExplicit: '101' },
  pending:    { id: 'sng_pen',  artist: 'Big Sean',       name: 'Bounce',   albumId: 'alb_1', explicit: true,  appleMusicId: '200' },
  noEdition:  { id: 'sng_noe',  artist: 'Drake',          name: 'Passion',  albumId: 'alb_1', explicit: true,  appleMusicId: '300', appleMusicIdClean: '300' },
  noCatalog:  { id: 'sng_noc',  artist: 'Jay-Z',          name: 'Dirt',     albumId: 'alb_2', explicit: true },
  // has a clean id but STILL no appleMusicId: the lookup route cannot start -> NO_CATALOG_ID,
  // not NO_EXPLICIT_EDITION. Regression guard for the bucket ordering.
  noCatClean: { id: 'sng_ncc',  artist: 'Nas',            name: 'Halftime', albumId: 'alb_2', explicit: true,  appleMusicIdClean: '400' },
  // duplicate rows, BOTH flagged explicit: the id-less one is recoverable from its twin
  twinBad:    { id: 'sng_twa',  artist: 'DMX',            name: 'X Gon',    albumId: 'alb_3', explicit: true },
  twinGood:   { id: 'sng_twb',  artist: 'DMX',            name: 'X Gon!',   albumId: 'alb_3', explicit: true,  appleMusicId: '500', appleMusicIdExplicit: '501' },
  // the owner's DJ Khaled shape: id-less row flagged explicit:false beside a full twin
  shadow:     { id: 'sng_shd',  artist: 'DJ Khaled',      name: "I'm On One", albumId: 'alb_4', explicit: false, appleMusicIdClean: '600' },
  shadowTwin: { id: 'sng_sht',  artist: 'DJ Khaled',      name: "I'm On One", albumId: 'alb_4', explicit: true,  appleMusicId: '601', appleMusicIdExplicit: '602' },
  // decoys: never in scope
  cleanSong:  { id: 'sng_cln',  artist: 'Adele',          name: 'Hello',    albumId: 'alb_5', explicit: false, appleMusicId: '700' },
  unflagged:  { id: 'sng_unf',  artist: 'Enya',           name: 'Orinoco',  albumId: 'alb_5' },
  // id-less, unflagged, NO explicit twin -> plain missing data, NOT a shadow twin
  lonely:     { id: 'sng_lon',  artist: 'Moby',           name: 'Porcelain', albumId: 'alb_5', explicit: false },
};
const index = {
  manifest: { generatedAt: '2026-01-01T00:00:00Z' },
  albums: [
    { id: 'alb_1', trackList: ['sng_res', 'sng_pen', 'sng_noe'] },
    { id: 'alb_2', trackList: ['sng_noc', 'sng_ncc'] },
    { id: 'alb_3', trackList: ['sng_twa', 'sng_twb'] },
    { id: 'alb_4', trackList: ['sng_shd', 'sng_sht'] },
    { id: 'alb_5', trackList: ['sng_cln', 'sng_unf', 'sng_lon'] },
  ],
  songs: Object.values(S),
};
const doc = {
  schemaVersion: 6,
  pockets: [
    // worst pocket: 3 flagged explicit, 1 resolved, + a shadow twin
    { id: 'pkt_gym', name: '🏋🏾‍♀️', songIds: ['sng_res', 'sng_noc', 'sng_ncc', 'sng_shd', 'sng_twa', 'sng_noe'], songRepeats: { sng_pen: 2 }, albumIds: [], childPocketIds: [] },
    // album expansion + a nested child pocket
    { id: 'pkt_par', name: 'Parent', songIds: [], albumIds: ['alb_3'], childPocketIds: ['pkt_kid'] },
    { id: 'pkt_kid', name: 'Kid',    songIds: ['sng_noe'], albumIds: [], childPocketIds: ['pkt_par'] },   // cycle back
    // fully clean pocket — must sort last
    { id: 'pkt_cln', name: 'Clean',  songIds: ['sng_cln', 'sng_res'], albumIds: [], childPocketIds: [] },
    // references a song id that is not in the index (studio/profile item) — must be ignored
    { id: 'pkt_gho', name: 'Ghost',  songIds: ['smp_not_a_catalog_song'], albumIds: [], childPocketIds: [] },
  ],
  playlists: [
    { id: 'pl_1', name: 'Set A', sequences: [
      { kind: 'song', songId: 'sng_pen' },
      { kind: 'sequence', children: [{ kind: 'album', albumId: 'alb_2' }, { kind: 'pocket', pocketId: 'pkt_kid' }] },
    ] },
  ],
  setlists: [{ id: 'sl_1', name: 'Live', tracks: [{ songId: 'sng_twa' }, { songId: 'sng_res' }] }],
};

// ────────────────────────── classifySong ──────────────────────────
console.log('classifySong — one bucket per song');
eq(classifySong(S.resolved, null), 'RESOLVED', 'appleMusicIdExplicit present -> RESOLVED');
eq(classifySong(S.pending, null), 'PENDING', 'catalog id, never examined -> PENDING');
eq(classifySong(S.noEdition, null), 'NO_EXPLICIT_EDITION', 'clean id, no explicit sibling -> NO_EXPLICIT_EDITION');
eq(classifySong(S.noCatalog, null), 'NO_CATALOG_ID', 'no catalog id, no twin -> NO_CATALOG_ID');
eq(classifySong(S.noCatClean, null), 'NO_CATALOG_ID', 'clean id but no appleMusicId is STILL NO_CATALOG_ID');
eq(classifySong(S.twinBad, S.twinGood), 'TWIN_RECOVERABLE', 'id-less row with a twin that has ids -> TWIN_RECOVERABLE');
eq(classifySong(S.twinBad, S.noCatalog), 'NO_CATALOG_ID', 'a twin with no ids of its own does not rescue anything');
eq(classifySong({ ...S.pending, appleMusicIdExplicit: '  ' }, null), 'PENDING', 'a blank explicit id is not a resolution');
eq(classifySong({ ...S.noCatalog, appleMusicId: '' }, null), 'NO_CATALOG_ID', 'an empty appleMusicId counts as absent');
ok(BUCKETS.every((b) => typeof REMEDIES[b] === 'string' && REMEDIES[b].length > 10), 'every bucket has a remedy string');
ok(REMEDIES.NO_CATALOG_ID.includes('resolve-apple-music-catalog.mjs'), 'NO_CATALOG_ID remedy names the catalog-id resolver script');
ok(REMEDIES.PENDING.includes('resolve-explicit-lookup.mjs'), 'PENDING remedy names the lookup resolver script');
ok(typeof REMEDIES.SHADOW_TWIN === 'string', 'SHADOW_TWIN has a remedy too');

// ────────────────────────── normalization / twin key ──────────────────────────
console.log('twin key');
eq(norm('Beyoncé'), 'beyonce', 'diacritics folded');
eq(twinKey({ artist: 'DMX', name: 'X Gon' }), twinKey({ artist: 'dmx', name: 'X-Gon!' }),
   'punctuation + case do not split a twin pair');
ok(twinKey({ artist: 'DMX', name: 'X Gon' }) !== twinKey({ artist: 'DMX', name: 'X Gon (Clean)' }),
   'an edition parenthetical is a REAL difference — never folded away');

// ────────────────────────── collection expansion ──────────────────────────
console.log('collection expansion');
const albumsById = new Map(index.albums.map((a) => [a.id, a.trackList]));
const cols = collectionsFromDoc(doc, albumsById);
eq(cols.length, 7, '5 pockets + 1 playlist + 1 setlist');
const byName = new Map(cols.map((c) => [c.name, c]));
eq([...byName.get('🏋🏾‍♀️').songIds].sort(), ['sng_ncc', 'sng_noc', 'sng_noe', 'sng_pen', 'sng_res', 'sng_shd', 'sng_twa'],
   'songIds + songRepeats keys both count as membership');
eq([...byName.get('Parent').songIds].sort(), ['sng_noe', 'sng_twa', 'sng_twb'],
   'albumIds expand to tracks and childPocketIds recurse (cycle-guarded, no hang)');
eq([...byName.get('Set A').songIds].sort(), ['sng_ncc', 'sng_noc', 'sng_noe', 'sng_pen', 'sng_twa', 'sng_twb'],
   'playlist sequence tree walks song + album + nested pocket (which itself expands)');
eq([...byName.get('Live').songIds].sort(), ['sng_res', 'sng_twa'], 'setlist takes its frozen tracks');

console.log('findCollection');
eq(findCollection(cols, 'pkt_gym').match.name, '🏋🏾‍♀️',
   'exact id wins — the escape hatch for emoji names a shell will not pass through');
eq(findCollection(cols, 'parent').match.id, 'pkt_par', 'case-insensitive exact name');
eq(findCollection(cols, 'ren').match.id, 'pkt_par', 'unique substring match');
eq(findCollection(cols, 'nope').match, null, 'no match -> null, never a guess');
ok(findCollection(cols, 'a').ambiguous?.length > 1, 'ambiguous substring reports the candidates');

// ────────────────────────── the audit ──────────────────────────
console.log('audit — catalog-wide');
const res = audit(index, doc);
eq(res.totals.flaggedExplicit, 8, '8 songs flagged explicit');
eq(res.totals.buckets, { RESOLVED: 3, TWIN_RECOVERABLE: 1, NO_CATALOG_ID: 2, NO_EXPLICIT_EDITION: 1, PENDING: 1 },
   'every flagged song lands in exactly one bucket');
eq(Object.values(res.totals.buckets).reduce((a, b) => a + b, 0), res.totals.flaggedExplicit,
   'buckets sum to the flagged total (no song double-counted or dropped)');
eq(res.totals.unresolved, 5, 'unresolved = flagged - resolved');
eq(res.totals.unresolvedPct, 62.5, 'unresolved percentage');
eq(res.rows.filter((r) => r.bucket === 'TWIN_RECOVERABLE').map((r) => [r.id, r.twin.id]), [['sng_twa', 'sng_twb']],
   'the twin row is reported with the id to copy from');

console.log('audit — shadow twins (the DJ Khaled shape)');
eq(res.totals.shadowTwins, 1, 'exactly one shadow twin');
eq(res.shadows.map((r) => [r.id, r.bucket, r.twin.id, r.twin.appleMusicIdExplicit]),
   [['sng_shd', 'SHADOW_TWIN', 'sng_sht', '602']],
   'the unflagged id-less row is matched to its flagged twin and its explicit id');
ok(!res.rows.some((r) => r.id === 'sng_shd'), 'a shadow twin is NOT counted in the five flagged buckets');
ok(!res.shadows.some((r) => r.id === 'sng_lon'), 'an id-less row with no explicit twin is not a shadow twin');
eq(res.rows.find((r) => r.id === 'sng_res').collections.sort(), ['Clean', 'Live', '🏋🏾‍♀️'],
   'each song carries the collections it belongs to');

console.log('audit — section 2, per collection');
const cbn = new Map(res.collections.map((c) => [c.name, c]));
eq([cbn.get('🏋🏾‍♀️').songs, cbn.get('🏋🏾‍♀️').flaggedExplicit, cbn.get('🏋🏾‍♀️').resolved, cbn.get('🏋🏾‍♀️').unresolved, cbn.get('🏋🏾‍♀️').shadowTwins],
   [7, 6, 1, 5, 1], 'gym pocket: 7 members, 6 flagged, 1 resolved, 5 unresolved, 1 shadow');
eq(cbn.get('🏋🏾‍♀️').buckets, { RESOLVED: 1, TWIN_RECOVERABLE: 1, NO_CATALOG_ID: 2, NO_EXPLICIT_EDITION: 1, PENDING: 1 },
   'per-collection bucket breakdown');
eq(cbn.get('🏋🏾‍♀️').unresolvedIds.sort(), ['sng_ncc', 'sng_noc', 'sng_noe', 'sng_pen', 'sng_shd', 'sng_twa'],
   'unresolvedIds is the re-rip work list (shadow twins included)');
eq(cbn.get('Ghost').songs, 0, 'collection ids that are not catalog songs are ignored');
eq(cbn.get('Clean').unresolved, 0, 'a fully resolved collection reports zero unresolved');
eq(res.collections.map((c) => c.name), ['🏋🏾‍♀️', 'Set A', 'Kid', 'Parent', 'Live', 'Clean', 'Ghost'],
   'worst first: unresolved+shadow desc, then unresolved %, then name');

console.log('audit — --collection scoping');
const scoped = audit(index, doc, { scopeIds: byName.get('🏋🏾‍♀️').songIds });
eq(scoped.totals.songsInScope, 7, 'scope limits the song walk');
eq(scoped.totals.flaggedExplicit, 6, 'scoped flagged count');
eq(scoped.totals.buckets.NO_CATALOG_ID, 2, 'scoped bucket counts');
eq(scoped.collections.length, 7, 'every collection still reported under a scope');
eq(scoped.collections.find((c) => c.name === 'Set A').songs, 5,
   'other collections are INTERSECTED with the scope, not dropped (6 members -> 5 in scope)');

console.log('audit — degenerate inputs');
eq(audit({ songs: [] }, null).totals.flaggedExplicit, 0, 'empty index -> zeros, no throw');
eq(audit(index, null).totals.flaggedExplicit, 8, 'missing collections doc still audits the catalog');
eq(audit(index, null).collections, [], 'missing collections doc -> empty section 2');

// ────────────────────────── end-to-end CLI ──────────────────────────
console.log('CLI end-to-end');
const dir = mkdtempSync(join(tmpdir(), 'pdj-audit-'));
const idxPath = join(dir, 'index.json');
const docPath = join(dir, 'collections.json');
const jsonPath = join(dir, 'out.json');
writeFileSync(idxPath, JSON.stringify(index));
writeFileSync(docPath, JSON.stringify(doc));
const run = (extra) => spawnSync(process.execPath, [
  new URL('./audit-explicit-coverage.mjs', import.meta.url).pathname,
  '--index', idxPath, '--collections', docPath, ...extra,
], { encoding: 'utf8' });

const r1 = run(['--json', jsonPath]);
eq(r1.status, 0, 'exits 0');
ok(/SECTION 1/.test(r1.stderr) && /SECTION 2/.test(r1.stderr), 'human summary goes to stderr');
eq(r1.stdout, '', 'stdout stays clean (stderr is the report, --json is the data)');
const out = JSON.parse(readFileSync(jsonPath, 'utf8'));
eq(out.totals.buckets, res.totals.buckets, 'JSON totals match the in-process audit');
eq(out.songs.length, 8, 'JSON carries every flagged song');
eq(out.shadowTwins.length, 1, 'JSON carries the shadow twins');
ok(out.collections[0].name === '🏋🏾‍♀️', 'JSON collections are worst-first');
ok(typeof out.remedies.NO_CATALOG_ID === 'string', 'JSON carries the remedies');
ok(/^\d{4}-/.test(out.generatedAt) && out.indexGeneratedAt === '2026-01-01T00:00:00Z', 'JSON stamps both timestamps');

const r2 = run(['--collection', '🏋🏾‍♀️', '--json', '-']);
eq(r2.status, 0, '--collection exits 0');
eq(JSON.parse(r2.stdout).totals.flaggedExplicit, 6, "--collection scopes the audit ('-' writes JSON to stdout)");

const r3 = run(['--collection', 'no-such-collection']);
eq(r3.status, 1, 'an unknown --collection is a hard error, not a silent empty audit');

const r4 = run(['--json', jsonPath, '--no-songs']);
eq(r4.status, 0, '--no-songs exits 0');
ok(JSON.parse(readFileSync(jsonPath, 'utf8')).songs === undefined, '--no-songs omits the per-song array');

console.log(failures ? `\n${failures} FAILED` : '\nall passed');
process.exit(failures ? 1 : 0);
