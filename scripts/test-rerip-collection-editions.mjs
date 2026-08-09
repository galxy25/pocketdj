#!/usr/bin/env node
// Tests for the collection-scoped edition re-rip (scripts/rerip-collection-editions.mjs).
// Network-free: a synthetic catalog + collections doc + rips manifest, plus a stub fetch
// for the enqueue path. Run: node scripts/test-rerip-collection-editions.mjs

import {
  catalogIdFor, decide, variantId, collectionsOf, songIdsOfCollection, buildWorkList,
  averageRipBytes, observedRipsPerHour, costReport, enqueueBatches, parseArgs,
} from './rerip-collection-editions.mjs';

let pass = 0, fail = 0;
const ok = (cond, label) => { if (cond) { pass++; } else { fail++; console.error(`  ✗ ${label}`); } };
const eq = (a, b, label) => ok(JSON.stringify(a) === JSON.stringify(b), `${label}\n      got ${JSON.stringify(a)}\n      want ${JSON.stringify(b)}`);
const section = (s) => console.error(`\n${s}`);

// ---------------------------------------------------------------- fixtures

// sng_a: explicit song, both editions known, primary = the CLEAN id (the owner's Big Sean shape)
const songA = { id: 'sng_aaaaaaaaaaaa', name: 'A', artist: 'X', explicit: true,
                appleMusicId: '100', appleMusicIdExplicit: '101', appleMusicIdClean: '100', length: 180000 };
// sng_b: explicit, NO explicit id resolved (the 14k NO_CATALOG_ID / unresolved shape)
const songB = { id: 'sng_bbbbbbbbbbbb', name: 'B', artist: 'X', explicit: true,
                appleMusicId: '200', length: 200000 };
// sng_c: clean song with an explicit sibling
const songC = { id: 'sng_cccccccccccc', name: 'C', artist: 'X', explicit: false,
                appleMusicId: '300', appleMusicIdExplicit: '301', appleMusicIdClean: '300', length: 220000 };
// sng_d: explicit, its PRIMARY already is the explicit cut (nothing to substitute)
const songD = { id: 'sng_dddddddddddd', name: 'D', artist: 'X', explicit: true,
                appleMusicId: '400', appleMusicIdExplicit: '400', appleMusicIdClean: '401', length: 240000 };
// sng_e: album track, reached only through a pocket's albumIds
const songE = { id: 'sng_eeeeeeeeeeee', name: 'E', artist: 'X', explicit: true,
                appleMusicId: '500', appleMusicIdExplicit: '501', length: 260000 };
// sng_g: unclassified explicitness, no variant ids — its explicit edition has NO catalog id
const songG = { id: 'sng_gggggggggggg', name: 'G', artist: 'X',
                appleMusicId: '700', length: 300000 };
// sng_f: in NO collection at all — must never appear (the lazy path serves it)
const songF = { id: 'sng_ffffffffffff', name: 'F', artist: 'X', explicit: true,
                appleMusicId: '600', appleMusicIdExplicit: '601', length: 280000 };

const songsById = new Map([songA, songB, songC, songD, songE, songF, songG].map((s) => [s.id, s]));
const albumTracks = new Map([['alb_1', [songE.id]]]);

const doc = {
  pockets: [
    { id: 'pkt_gym', name: '🏋🏾‍♀️', songIds: [songA.id, songB.id, songG.id], albumIds: ['alb_1'],
      childPocketIds: ['pkt_child'] },
    { id: 'pkt_child', name: 'child', songIds: [songD.id] },
    { id: 'pkt_clean', name: 'Kids', cleanOnly: true, songIds: [songC.id] },
  ],
  playlists: [
    { id: 'pl_1', name: 'List', sequences: [{ kind: 'song', songId: songC.id }] },
  ],
  setlists: [
    { id: 'set_1', name: 'Set', tracks: [{ songId: songA.id }] },
  ],
};

// ---------------------------------------------------------------- catalogIdFor

section('catalogIdFor — the IndexSong.appleMusicId(for:) mirror');
eq(catalogIdFor(songA, 'explicit'), '101', 'variant field wins');
eq(catalogIdFor(songA, 'clean'), '100', 'clean variant field');
eq(catalogIdFor(songB, 'explicit'), '200', 'explicit primary IS its own explicit edition');
eq(catalogIdFor(songB, 'clean'), null, 'explicit song with no clean edition → null');
eq(catalogIdFor(songC, 'clean'), '300', 'clean primary IS its own clean edition');
eq(catalogIdFor({ id: 'x', appleMusicId: '9' }, 'explicit'), null, 'unclassified → null (never invented)');
eq(catalogIdFor({ id: 'x', appleMusicId: '9' }, 'clean'), null, 'unclassified clean → null');

// ---------------------------------------------------------------- decide (precedence)

section('decide — the EditionPolicy precedence mirror');
eq(decide(songA, { collectionCleanOnly: false, preferredEdition: 'explicit' }),
   { edition: 'explicit', catalogId: '101' }, 'prefer-explicit substitutes the explicit id');
eq(decide(songA, { collectionCleanOnly: true, preferredEdition: 'explicit' }), null,
   'CLEAN-ONLY BEATS prefer-explicit: songA primary already is the clean cut → nothing to do');
eq(decide(songB, { collectionCleanOnly: false, preferredEdition: 'explicit' }), null,
   'explicit primary under prefer-explicit → no substitution (the base rip IS that edition)');
eq(decide(songC, { collectionCleanOnly: true, preferredEdition: 'explicit' }), null,
   'clean-only + already-clean song → untouched');
eq(decide(songC, { collectionCleanOnly: false, preferredEdition: 'explicit' }),
   { edition: 'explicit', catalogId: '301' }, 'clean song gains its explicit sibling under prefer-explicit');
eq(decide(songD, { collectionCleanOnly: false, preferredEdition: 'explicit' }), null,
   'primary already IS the explicit edition → no duplicate storage');
eq(decide(songD, { collectionCleanOnly: true, preferredEdition: 'explicit' }),
   { edition: 'clean', catalogId: '401' }, 'clean-only on an explicit song substitutes clean');
eq(decide(null, { collectionCleanOnly: false, preferredEdition: 'explicit' }), null,
   'unknown song → null');
// The hard gate: an edition we cannot NAME is never enqueued.
eq(decide({ id: 'sng_z', explicit: true, appleMusicId: null }, { collectionCleanOnly: true, preferredEdition: 'explicit' }),
   null, 'explicit song with NO clean id → nothing enqueued (never guessed from artist+title)');

// ---------------------------------------------------------------- membership walk

section('per-collection membership (reuses collectionSongIds)');
const colls = collectionsOf(doc);
eq(colls.map((c) => `${c.kind}:${c.id}:${c.cleanOnly}`),
   ['pocket:pkt_gym:false', 'pocket:pkt_child:false', 'pocket:pkt_clean:true',
    'playlist:pl_1:false', 'setlist:set_1:false'],
   'collections flattened with their cleanOnly flags');

const gym = songIdsOfCollection(doc, colls[0], albumTracks);
ok(gym.has(songA.id) && gym.has(songB.id), 'pocket: own songIds');
ok(gym.has(songE.id), 'pocket: albumIds expand to tracks');
ok(gym.has(songD.id), 'pocket: nested childPocketIds');
ok(!gym.has(songC.id), 'pocket: does NOT leak the clean-only pocket’s song');
ok(!gym.has(songF.id), 'pocket: does NOT leak a non-member');

const cleanPocket = songIdsOfCollection(doc, colls[2], albumTracks);
eq([...cleanPocket], [songC.id], 'clean-only pocket resolves to exactly its song');

const setl = songIdsOfCollection(doc, colls[4], albumTracks);
eq([...setl], [songA.id], 'setlist resolves its frozen tracks');

// ---------------------------------------------------------------- work list

section('buildWorkList — scope, precedence, idempotence');
{
  const { enqueue, stats } = buildWorkList({
    songsById, albumTracks, doc, manifest: {}, preferredEdition: 'explicit',
  });
  const ids = enqueue.map((e) => e.songId).sort();
  eq(ids, [variantId(songA.id, 'explicit'), variantId(songE.id, 'explicit')].sort(),
     'enqueues exactly the songs with a real, NAMEABLE missing edition');
  ok(!ids.includes(variantId(songF.id, 'explicit')),
     'NOTHING catalog-wide: a song outside every collection is never enqueued');
  ok(!enqueue.some((e) => e.baseId === songC.id),
     'a song ONLY in a clean-only collection takes CLEAN → already its primary → nothing');
  ok(!enqueue.some((e) => e.baseId === songD.id),
     'songD sits in an ORDINARY pocket and its primary already IS the explicit cut → no duplicate storage');
  const a = enqueue.find((e) => e.baseId === songA.id);
  eq([a.edition, a.catalogId, a.cleanOnlyCollection], ['explicit', '101', false],
     'the owner’s shape (primary = the clean id, explicit id known) is what gets enqueued');
  ok(!enqueue.some((e) => e.baseId === songG.id),
     'a song whose wanted edition has NO catalog id is never enqueued (the hard gate)');
  eq(stats.unknownCatalogId, 1, 'and it is COUNTED, so the report says why nothing happened for it');
}

// A song in BOTH a clean-only and an ordinary collection takes CLEAN (the restriction wins).
{
  const doc2 = {
    pockets: [
      { id: 'pkt_norm', name: 'norm', songIds: [songD.id] },
      { id: 'pkt_clean', name: 'kids', cleanOnly: true, songIds: [songD.id] },
    ],
  };
  const { enqueue } = buildWorkList({
    songsById, albumTracks, doc: doc2, manifest: {}, preferredEdition: 'explicit',
  });
  eq(enqueue.map((e) => `${e.baseId}:${e.edition}`), [`${songD.id}:clean`],
     'clean-only membership BEATS the global preference for a song in both');
  ok(enqueue[0].cleanOnlyCollection === true, 'and the row records why');
}

// IDEMPOTENT: everything already stored enqueues nothing.
{
  const manifest = {
    [variantId(songA.id, 'explicit')]: { key: 'rips/a_explicit.mp3', bytes: 1000 },
    [variantId(songD.id, 'clean')]: { key: 'rips/d_clean.mp3', bytes: 1000 },
    [variantId(songE.id, 'explicit')]: { key: 'rips/e_explicit.mp3', bytes: 1000 },
  };
  const { enqueue, stats } = buildWorkList({
    songsById, albumTracks, doc, manifest, preferredEdition: 'explicit',
  });
  eq(enqueue, [], 're-running with everything stored enqueues NOTHING');
  eq(stats.alreadyStored, 2, 'and reports them as already stored');
}

// A LEGACY un-suffixed rip does NOT satisfy the edition — the whole point of edition keying.
{
  const manifest = { [songA.id]: { key: 'rips/sng_aaaaaaaaaaaa.mp3', bytes: 1000 } };
  const { enqueue } = buildWorkList({
    songsById, albumTracks, doc, manifest, preferredEdition: 'explicit',
  });
  ok(enqueue.some((e) => e.songId === variantId(songA.id, 'explicit')),
     'a legacy base rip does not stand in for the explicit edition (and is never overwritten)');
}

// The clean direction.
{
  const { enqueue } = buildWorkList({
    songsById, albumTracks, doc, manifest: {}, preferredEdition: 'clean',
  });
  ok(enqueue.every((e) => e.edition === 'clean'), '--edition clean enqueues only clean editions');
  ok(enqueue.some((e) => e.baseId === songD.id), 'songD gains its clean sibling');
}

// ---------------------------------------------------------------- cost model

section('cost model');
{
  const manifest = {
    a: { bytes: 4_000_000, rippedAt: 1_000_000_000_000 },
    b: { bytes: 6_000_000, rippedAt: 1_000_003_600_000 },   // +1h
    c: { bytes: 5_000_000, rippedAt: 1_000_007_200_000 },   // +2h
    d: { bytes: 5_000_000, rippedAt: 1_000_010_800_000 },
    e: { bytes: 5_000_000, rippedAt: 1_000_014_400_000 },
    f: { bytes: 0 },                                        // ignored
  };
  eq(averageRipBytes(manifest), 5_000_000, 'average rip size ignores zero/absent byte counts');
  eq(Math.round(observedRipsPerHour(manifest)), 1, 'observed throughput from rippedAt spread');
  eq(averageRipBytes({}), 0, 'no data → 0, never NaN');
  eq(observedRipsPerHour({}), 0, 'too few timestamps → 0 (caller falls back to the real-time floor)');

  const c = costReport([{ lengthMs: 3_600_000 }, { lengthMs: 1_800_000 }],
                       { avgBytes: 5_000_000, ripsPerHour: 2 });
  eq([c.count, c.bytes, c.realtimeHours, c.observedHours], [2, 10_000_000, 1.5, 1],
     'bytes + both wall-clock estimates');
}

// ---------------------------------------------------------------- enqueue path

section('enqueue — the SAME /rip-collection the app uses');
{
  const calls = [];
  const fetchImpl = async (url, opts) => {
    calls.push({ url, body: JSON.parse(opts.body), auth: opts.headers.authorization });
    return { ok: true, json: async () => ({ counts: { ready: 0, queued: opts.body.length ? JSON.parse(opts.body).songIds.length : 0, inflight: 0, unknown: 0, total: 0 } }) };
  };
  const counts = await enqueueBatches(['x1', 'x2', 'x3'], {
    server: 'http://imac:8787/', token: 'tok', batch: 2, fetchImpl,
  });
  eq(calls.length, 2, 'batched');
  eq(calls[0].url, 'http://imac:8787/rip-collection', 'posts to /rip-collection (trailing slash trimmed)');
  eq(calls[0].body.songIds, ['x1', 'x2'], 'first batch');
  eq(calls[1].body.songIds, ['x3'], 'second batch');
  eq(calls[0].auth, 'Bearer tok', 'carries the rip token');
  eq(counts.queued, 3, 'counts summed across batches');
}

// ---------------------------------------------------------------- args

section('args');
eq(parseArgs(['n', 's']).edition, 'explicit', 'default edition is explicit');
eq(parseArgs(['n', 's']).apply, false, 'DEFAULT IS DRY RUN');
eq(parseArgs(['n', 's', '--apply']).apply, true, '--apply opts in');
ok((() => { try { parseArgs(['n', 's', '--edition', 'remix']); return false; } catch { return true; } })(),
   'an unknown edition is rejected');

// ---------------------------------------------------------------- done

console.error(`\n${pass} ✓  ${fail} ✗`);
process.exit(fail ? 1 : 0);
