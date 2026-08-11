// Unit tests for the PURE decisions inside scripts/rip-backfill.mjs — the ordered rip-queue
// driver that pumps the owner's pocket backup through the rip server.
//
// What is pinned, and why it matters more than usual here:
//   · ORDERING decides which songs get real-time capture FIRST across weeks of serial ripping —
//     an ordering bug doesn't fail, it silently rips the stale half of the collection first.
//   · DEDUP first-occurrence-wins is what makes "freshest taste first" true for shared songs.
//   · ALIAS matching gates ~1.2k skips; a loose matcher here re-rips nothing but a WRONG match
//     maps a pocket song onto a different recording's analysis — the fabricated-row failure the
//     segment-attribution law exists to prevent. Version markers must agree (tight-matching law).
//   · SKIP classification is the difference between "visible, reasoned skip" and silent loss.
import { describe, it, expect } from 'vitest';
import {
  orderPockets, expandPocketSongIds, buildWorkList,
  recordingKeys, buildAliasIndex, findAlias,
  classifySong, classifyAll, isDrmVideo, resolutionReport, etaHours,
} from '../../scripts/rip-backfill.mjs';
import { indexLibrary } from '../../scripts/lib/am-match.mjs';

const pocket = (id, over = {}) => ({
  id, name: id, kind: 'harmonic', songIds: [], childPocketIds: [],
  lastPlayedAt: null, ...over,
});

describe('orderPockets', () => {
  it('freshest lastPlayedAt first, nulls LAST, then size desc, then id — deterministic', () => {
    const fresh = pocket('pkt_b', { lastPlayedAt: 2000, songIds: ['s1'] });
    const stale = pocket('pkt_a', { lastPlayedAt: 1000, songIds: ['s1', 's2', 's3'] });
    const neverBig = pocket('pkt_d', { songIds: ['s1', 's2'] });
    const neverSmall = pocket('pkt_c', { songIds: ['s1'] });
    const got = orderPockets([neverSmall, stale, neverBig, fresh]).map((p) => p.id);
    // played pockets outrank never-played REGARDLESS of size; among never-played, bigger first
    expect(got).toEqual(['pkt_b', 'pkt_a', 'pkt_d', 'pkt_c']);
  });

  it('ties (same play time, same size) break on id so a recompute reproduces the same order', () => {
    const x = pocket('pkt_x', { lastPlayedAt: 5, songIds: ['a'] });
    const y = pocket('pkt_y', { lastPlayedAt: 5, songIds: ['b'] });
    expect(orderPockets([y, x]).map((p) => p.id)).toEqual(['pkt_x', 'pkt_y']);
  });

  it('sizes by the EXPANDED map when provided — membership on children must count', () => {
    const parent = pocket('pkt_p', { songIds: [] });
    const flat = pocket('pkt_f', { songIds: ['a'] });
    const sizes = new Map([['pkt_p', 10], ['pkt_f', 1]]);
    expect(orderPockets([flat, parent], sizes)[0].id).toBe('pkt_p');
  });
});

describe('expandPocketSongIds', () => {
  it('own songIds first (stored order preserved), then children depth-first', () => {
    const child = pocket('pkt_c', { songIds: ['c1', 'c2'] });
    const parent = pocket('pkt_p', { songIds: ['p1'], childPocketIds: ['pkt_c'] });
    const byId = new Map([['pkt_c', child], ['pkt_p', parent]]);
    expect(expandPocketSongIds(parent, byId)).toEqual(['p1', 'c1', 'c2']);
  });

  it('a cycle terminates instead of recursing forever, and a dangling child is ignored', () => {
    const a = pocket('pkt_a', { songIds: ['a1'], childPocketIds: ['pkt_b', 'pkt_ghost'] });
    const b = pocket('pkt_b', { songIds: ['b1'], childPocketIds: ['pkt_a'] });
    const byId = new Map([['pkt_a', a], ['pkt_b', b]]);
    expect(expandPocketSongIds(a, byId)).toEqual(['a1', 'b1']);
  });
});

describe('buildWorkList', () => {
  it('de-dups across pockets with FIRST occurrence winning — a shared song rips at the fresh pocket\'s position', () => {
    const fresh = pocket('pkt_fresh', { lastPlayedAt: 100, songIds: ['shared', 'f2'] });
    const stale = pocket('pkt_stale', { lastPlayedAt: 1, songIds: ['s1', 'shared'] });
    const got = buildWorkList([stale, fresh]);
    expect(got.map((e) => e.songId)).toEqual(['shared', 'f2', 's1']);
    expect(got[0].pocketId).toBe('pkt_fresh');
  });

  it('membership living on children still enters the list under the parent\'s rank', () => {
    const child = pocket('pkt_child', { songIds: ['c1'] });
    const parent = pocket('pkt_parent', { lastPlayedAt: 100, songIds: [], childPocketIds: ['pkt_child'] });
    const other = pocket('pkt_other', { lastPlayedAt: 50, songIds: ['o1'] });
    // the child also exists top-level (never played) — parent's expansion must claim c1 first
    const got = buildWorkList([child, other, parent]);
    expect(got.map((e) => e.songId)).toEqual(['c1', 'o1']);
    expect(got[0].pocketId).toBe('pkt_parent');
  });
});

describe('recordingKeys / alias matching (tight-matching law)', () => {
  it('same recording, cosmetic differences → same primary key', () => {
    expect(recordingKeys('ABBA', 'Fernando')[0])
      .toBe(recordingKeys('ABBA', 'Fernando (Remastered)')[0]);
    expect(recordingKeys('Omarion', 'Post To Be (feat. Chris Brown & Jhene Aiko)')[0])
      .toBe(recordingKeys('Omarion', 'Post To Be')[0]);
  });

  it('version markers MUST agree — a club mix is not the album cut', () => {
    expect(recordingKeys('Ace of Base', 'Living In Danger (For The Big Clubs Only Mix)')[0])
      .not.toBe(recordingKeys('Ace of Base', 'Living In Danger')[0]);
  });

  it('spaceless secondary key catches Apple\'s own spelling variance ("Pop Star" vs "Popstar")', () => {
    const idx = buildAliasIndex([{ id: 'sng_owned', artist: 'Tinashe', name: 'Popstar', rank: 0 }]);
    const hit = findAlias(idx, { id: 'sng_new', artist: 'Tinashe', name: 'Pop Star' });
    expect(hit?.id).toBe('sng_owned');
  });

  it('never aliases a song to ITSELF, and misses cleanly when only the same id holds the recording', () => {
    const idx = buildAliasIndex([{ id: 'sng_a', artist: 'Sade', name: 'Smooth Operator', rank: 0 }]);
    expect(findAlias(idx, { id: 'sng_a', artist: 'Sade', name: 'Smooth Operator' })).toBeNull();
  });

  it('several ids holding one recording resolve deterministically: rank asc, then id asc', () => {
    const idx = buildAliasIndex([
      { id: 'sng_vinyl', artist: 'Mann', name: 'Steelo', rank: 2 },
      { id: 'sng_manifest', artist: 'Mann', name: 'Steelo (LP Version)', rank: 0 }, // LP Version is cosmetic
      { id: 'sng_manifest2', artist: 'Mann', name: 'Steelo', rank: 0 },
    ]);
    const hit = findAlias(idx, { id: 'sng_pocket', artist: 'Mann', name: 'Steelo' });
    expect(hit.id).toBe('sng_manifest'); // rank 0 beats rank 2; id asc breaks the rank tie
  });

  it('artist must agree — a different artist\'s identical title never aliases', () => {
    const idx = buildAliasIndex([{ id: 'sng_x', artist: 'Nirvana', name: 'Intro', rank: 0 }]);
    expect(findAlias(idx, { id: 'sng_y', artist: 'Danger Mouse', name: 'Intro' })).toBeNull();
  });
});

describe('classifySong precedence', () => {
  const song = (id, over = {}) => ({ id, artist: 'A', name: 'T', ...over });

  it('own audio wins over everything (nothing to rip, nothing to alias)', () => {
    const ctx = {
      audioIds: new Set(['sng_a']), audioVia: new Map([['sng_a', 'manifest-digital']]),
      aliasIndex: buildAliasIndex([{ id: 'sng_other', artist: 'A', name: 'T', rank: 0 }]),
    };
    expect(classifySong(song('sng_a'), ctx)).toEqual({ action: 'skip', reason: 'has-audio', via: 'manifest-digital' });
  });

  it('alias outranks drm-video — a DRM row whose recording exists elsewhere still yields its mapping', () => {
    const ctx = {
      audioIds: new Set(),
      aliasIndex: buildAliasIndex([{ id: 'sng_vinyl', artist: 'A', name: 'T', rank: 2 }]),
    };
    const c = classifySong(song('sng_drm', { pointer: { fileLocation: 'file:///x/01%20T.movpkg/' } }), ctx);
    expect(c).toEqual({ action: 'skip', reason: 'alias-analysed', aliasOf: 'sng_vinyl' });
  });

  it('drm-video (.movpkg) rows are skipped with their own visible reason', () => {
    const ctx = { audioIds: new Set(), aliasIndex: new Map() };
    const c = classifySong(song('sng_v', { pointer: { fileLocation: 'file:///Music/01%20Ale.movpkg/' } }), ctx);
    expect(c).toEqual({ action: 'skip', reason: 'drm-video' });
    expect(isDrmVideo({ pointer: { fileLocation: '/x/y.mp3' } })).toBe(false);
    expect(isDrmVideo({})).toBe(false);
  });

  it('studio artifacts (smp_/lp_/ptn_/tk_) never reach the rip queue — server law, mirrored', () => {
    const ctx = { audioIds: new Set(), aliasIndex: new Map() };
    expect(classifySong(song('smp_123'), ctx).reason).toBe('studio-artifact');
    expect(classifySong(song('tk_9'), ctx).reason).toBe('studio-artifact');
  });

  it('routes: appleMusicId first; else the Library.xml row (exact preferred, loose accepted); else no-route', () => {
    const ctx = { audioIds: new Set(), aliasIndex: new Map() };
    expect(classifySong(song('sng_1', { appleMusicId: '123' }), ctx)).toEqual({ action: 'rip', route: 'am-id' });

    // a real am-match index: one exact-able row, one only-loosely-reachable row
    const lib = indexLibrary([
      { persistentID: 'P1', artist: 'Sade', title: 'Smooth Operator' },
      { persistentID: 'P2', artist: 'Mtume', title: 'Juicy Fruit (Fruity Instrumental Mix)' },
    ]);
    expect(classifySong(song('sng_2', { artist: 'Sade', name: 'Smooth Operator' }), { ...ctx, libIndex: lib }))
      .toEqual({ action: 'rip', route: 'library-exact' });
    // version markers disagree → not exact; paren-stripped title + artist subset → loose
    expect(classifySong(song('sng_3', { artist: 'Mtume', name: 'Juicy Fruit' }), { ...ctx, libIndex: lib }))
      .toEqual({ action: 'rip', route: 'library-loose' });
    expect(classifySong(song('sng_4', { artist: 'Nobody', name: 'Nothing' }), { ...ctx, libIndex: lib }))
      .toEqual({ action: 'skip', reason: 'no-route' });
  });

  it('with NO library index, id-less rows stay rippable as library-unprobed — never guessed into no-route', () => {
    const ctx = { audioIds: new Set(), aliasIndex: new Map(), libIndex: null };
    expect(classifySong(song('sng_5'), ctx)).toEqual({ action: 'rip', route: 'library-unprobed' });
  });
});

describe('classifyAll', () => {
  it('unresolved ids become VISIBLE skips, alias mappings are collected for lane 2', () => {
    const byId = new Map([
      ['sng_ok', { id: 'sng_ok', artist: 'A', name: 'T', appleMusicId: '1' }],
      ['sng_aliased', { id: 'sng_aliased', artist: 'B', name: 'U' }],
    ]);
    const ctx = {
      audioIds: new Set(),
      aliasIndex: buildAliasIndex([{ id: 'sng_corpus', artist: 'B', name: 'U', rank: 0 }]),
    };
    const entries = [
      { songId: 'sng_ok', pocketId: 'p1', pocketName: 'P' },
      { songId: 'sng_aliased', pocketId: 'p1', pocketName: 'P' },
      { songId: 'sng_gone', pocketId: 'p2', pocketName: 'Q' },
    ];
    const { rips, skips, aliases } = classifyAll(entries, byId, ctx);
    expect(rips.map((r) => r.songId)).toEqual(['sng_ok']);
    expect(skips.sng_gone.reason).toBe('unresolved');
    expect(skips.sng_aliased).toMatchObject({ reason: 'alias-analysed', aliasOf: 'sng_corpus' });
    expect(aliases).toEqual({ sng_aliased: 'sng_corpus' });
  });
});

describe('resolutionReport', () => {
  it('a namespace mismatch reads as a catastrophic rate with the namespaces named — loud, not empty', () => {
    const byId = new Map([['sng_a', {}]]);
    const rep = resolutionReport(['trk_1', 'trk_2', 'sng_a'], byId);
    expect(rep.total).toBe(3);
    expect(rep.resolved).toBe(1);
    expect(rep.rate).toBeCloseTo(1 / 3);
    expect(rep.backupNamespaces).toEqual({ trk_: 2, sng_: 1 });
    expect(rep.unresolvedSample).toEqual(['trk_1', 'trk_2']);
  });
});

describe('etaHours', () => {
  it('linear in remaining at the measured serial-capture mean', () => {
    expect(etaHours(0, 280)).toBe(0);
    expect(etaHours(3290, 280)).toBeCloseTo(255.89, 1); // the full-corpus shape of the number
  });
});
