// Tests for the incremental Apple Music sync's diff/merge decisions — the ones that
// shipped real damage before they were extracted: the mid-edit "OTG" playlist deletion
// (2026-06-30), the perpetual "new tracks: 13" ghost churn, and snapshot-skew rows.
import { describe, it, expect } from 'vitest';
import {
  diffLibrary, partitionTrackRows, mergePlaylists,
  recordStrike, effectiveIgnoredPids, removalGuardTripped, playlistDumpLooksBroken, CONFIRM_STRIKES,
  reconcileRemovals, deferPlaylistRemovals, membershipKey, REMOVAL_CONFIRM_STRIKES,
} from '../../scripts/lib/am-sync-merge.mjs';
import { nsFor, songIdFor, playlistIdFor } from '../../scripts/lib/am-ids.mjs';
import { parsePlaylistRows, writeLibraryXml, nonMusicFlag, COLS } from '../../scripts/lib/am-music.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ns = nsFor('Apple Music (Local)');
const sid = (pid) => songIdFor(ns, pid);

const tsvLine = (fields) => COLS.map((c) => fields[c] || '').join('\t');

describe('diffLibrary', () => {
  it('classifies unknown pids as new (1-based positions) and missing ids as removed', () => {
    const { newPositions, newPids, removed } = diffLibrary({
      allPids: ['AAA', 'BBB', 'CCC'],
      existingIds: new Set([sid('AAA'), sid('GONE')]),
      ns,
    });
    expect(newPositions).toEqual([2, 3]);
    expect(newPids).toEqual(['BBB', 'CCC']);
    expect([...removed]).toEqual([sid('GONE')]);
  });

  it('excludes ignore-listed ghosts from new, counting them instead', () => {
    const { newPositions, newPids, ignoredSeen } = diffLibrary({
      allPids: ['GHOST1', 'REAL1', 'GHOST2'],
      existingIds: new Set(),
      ns,
      ignoredPids: new Set(['GHOST1', 'GHOST2']),
    });
    expect(newPositions).toEqual([2]);
    expect(newPids).toEqual(['REAL1']);
    expect(ignoredSeen).toBe(2);
  });
});

describe('partitionTrackRows', () => {
  it('splits usable rows, metadata-less ghosts, and unrequested (skew) rows', () => {
    const text = [
      tsvLine({ persistentID: 'REAL1', artist: 'Freddie Gibbs', title: 'Outside' }),
      tsvLine({ persistentID: 'GHOST1' }), // no title, no artist -> ghost
      tsvLine({ persistentID: 'OTHER1', artist: 'Sade', title: 'No Ordinary Love' }), // not requested
      tsvLine({ persistentID: 'REAL2', artist: '', title: 'Instrumental' }), // title only is usable
    ].join('\n');
    const { rows, ghostPids, skewPids } = partitionTrackRows(text, ['REAL1', 'GHOST1', 'REAL2']);
    expect(rows.map((r) => r.persistentID)).toEqual(['REAL1', 'REAL2']);
    expect(ghostPids).toEqual(['GHOST1']);
    expect(skewPids).toEqual(['OTHER1']);
  });

  it('coerces "missing value" to empty and drops blank/pid-less lines', () => {
    const text = [
      '',
      tsvLine({ persistentID: 'missing value', artist: 'X', title: 'Y' }),
      tsvLine({ persistentID: 'A1', artist: 'missing value', title: 'missing value' }),
    ].join('\n');
    const { rows, ghostPids } = partitionTrackRows(text, ['A1']);
    expect(rows).toEqual([]);
    expect(ghostPids).toEqual(['A1']);
  });
});

describe('mergePlaylists (presence governs existence)', () => {
  const finalSongIds = new Set([sid('P1'), sid('P2')]);

  it('keeps a playlist whose membership resolves to zero — the OTG regression', () => {
    const out = mergePlaylists({
      playlistRows: [{ ppid: 'OTGPPID', name: 'OTG', pids: ['UNKNOWN1', 'UNKNOWN2'] }],
      oldPlaylists: [{ id: playlistIdFor(ns, 'OTGPPID'), name: 'OTG', songIds: [sid('P1')] }],
      finalSongIds,
      ns,
    });
    expect(out).toHaveLength(1);
    expect(out[0]).toEqual({ id: playlistIdFor(ns, 'OTGPPID'), name: 'OTG', songIds: [] });
  });

  it('keeps a genuinely empty playlist as empty', () => {
    const out = mergePlaylists({ playlistRows: [{ ppid: 'E1', name: 'Empty', pids: [] }], oldPlaylists: [], finalSongIds, ns });
    expect(out).toEqual([{ id: playlistIdFor(ns, 'E1'), name: 'Empty', songIds: [] }]);
  });

  it('drops a playlist absent from the dump (deleted in Music)', () => {
    const out = mergePlaylists({
      playlistRows: [{ ppid: 'KEEP', name: 'Keep', pids: ['P1'] }],
      oldPlaylists: [{ id: playlistIdFor(ns, 'DELETED'), name: 'Deleted', songIds: [sid('P1')] }],
      finalSongIds,
      ns,
    });
    expect(out.map((p) => p.name)).toEqual(['Keep']);
  });

  it('retains previous membership (pruned) when the track read errored', () => {
    const out = mergePlaylists({
      playlistRows: [{ ppid: 'ERRPL', name: 'Flaky', pids: [], readError: true }],
      oldPlaylists: [{ id: playlistIdFor(ns, 'ERRPL'), name: 'Flaky', songIds: [sid('P1'), sid('REMOVED')] }],
      finalSongIds,
      ns,
    });
    expect(out).toEqual([{ id: playlistIdFor(ns, 'ERRPL'), name: 'Flaky', songIds: [sid('P1')] }]);
  });

  it('remaps membership to song ids and drops unresolvable members', () => {
    const out = mergePlaylists({
      playlistRows: [{ ppid: 'M1', name: 'Mix', pids: ['P1', 'NOPE', 'P2'] }],
      oldPlaylists: [],
      finalSongIds,
      ns,
    });
    expect(out[0].songIds).toEqual([sid('P1'), sid('P2')]);
  });
});

describe('ignore-list strikes (transient read failures must self-heal)', () => {
  it('emptiness-derived entries only become effective after CONFIRM_STRIKES distinct days', () => {
    const m = {};
    recordStrike(m, 'G1', 'no-metadata', '2026-07-03T04:00:00Z');
    expect(effectiveIgnoredPids(m).has('G1')).toBe(false); // strike 1 — retries tomorrow
    recordStrike(m, 'G1', 'no-metadata', '2026-07-04T04:00:00Z');
    expect(effectiveIgnoredPids(m).has('G1')).toBe(false); // strike 2
    recordStrike(m, 'G1', 'no-metadata', '2026-07-05T04:00:00Z');
    expect(m.G1.strikes).toBe(CONFIRM_STRIKES);
    expect(effectiveIgnoredPids(m).has('G1')).toBe(true);
  });

  it('does not double-strike within the same day (manual rerun after the 04:00 run)', () => {
    const m = {};
    recordStrike(m, 'G1', 'no-metadata', '2026-07-03T04:00:00Z');
    recordStrike(m, 'G1', 'no-metadata', '2026-07-03T09:30:00Z');
    expect(m.G1.strikes).toBe(1);
  });

  it('positive-evidence non-music entries are effective immediately', () => {
    const m = { V1: { firstSeen: 'x', lastSeen: 'x', reason: 'non-music' } };
    expect(effectiveIgnoredPids(m).has('V1')).toBe(true);
  });
});

describe('mass-removal circuit breaker', () => {
  it('allows plausible nightly removals and trips on implausible ones', () => {
    expect(removalGuardTripped(50, 92591)).toBe(false);
    expect(removalGuardTripped(463, 92591)).toBe(false); // 0.5% = 463
    expect(removalGuardTripped(464, 92591)).toBe(true);
    expect(removalGuardTripped(92591, 92591)).toBe(true); // empty snapshot = wipe
    expect(removalGuardTripped(10, 100)).toBe(false); // small library: 50-floor applies
  });
});

describe('playlist-dump circuit breaker', () => {
  it('treats an empty or >50%-shrunk dump as a read failure', () => {
    expect(playlistDumpLooksBroken(0, 118)).toBe(true);
    expect(playlistDumpLooksBroken(58, 118)).toBe(true);
    expect(playlistDumpLooksBroken(60, 118)).toBe(false);
    expect(playlistDumpLooksBroken(0, 0)).toBe(false);   // first-ever run
    expect(playlistDumpLooksBroken(1, 3)).toBe(false);   // tiny populations exempt
  });
});

describe('mergePlaylists identity under partial read failures', () => {
  const finalSongIds = new Set([sid('P1')]);

  it('reuses the committed id when the ppid read came back blank', () => {
    const committed = { id: playlistIdFor(ns, 'REALPPID'), name: 'OTG', songIds: [sid('P1')] };
    const out = mergePlaylists({
      playlistRows: [{ ppid: '', name: 'OTG', pids: ['P1'] }],
      oldPlaylists: [committed],
      finalSongIds,
      ns,
    });
    expect(out).toEqual([{ id: committed.id, name: 'OTG', songIds: [sid('P1')] }]);
  });

  it('retains committed playlists displaced by unidentifiable (blank/blank) rows', () => {
    const committed = { id: playlistIdFor(ns, 'X1'), name: 'Certified', songIds: [sid('P1'), sid('GONE')] };
    const out = mergePlaylists({
      playlistRows: [{ ppid: '', name: '', pids: [] }],
      oldPlaylists: [committed],
      finalSongIds,
      ns,
    });
    expect(out).toEqual([{ id: committed.id, name: 'Certified', songIds: [sid('P1')] }]);
  });
});

describe('reconcileRemovals (multi-run removal confirmation)', () => {
  const days = ['2026-07-16T04:00:00Z', '2026-07-17T04:00:00Z', '2026-07-18T04:00:00Z'];

  it('confirms a removal only after REMOVAL_CONFIRM_STRIKES distinct days', () => {
    const pending = {};
    for (const [i, day] of days.entries()) {
      const { confirmed, deferred } = reconcileRemovals({ pending, missing: ['A'], nowIso: day });
      if (i < REMOVAL_CONFIRM_STRIKES - 1) {
        expect(confirmed.size).toBe(0);
        expect(deferred.has('A')).toBe(true);
      } else {
        expect(confirmed.has('A')).toBe(true);
        expect(pending.A).toBeUndefined(); // cleared once shipped
      }
    }
  });

  it('does not double-strike a manual rerun on the same day', () => {
    const pending = {};
    reconcileRemovals({ pending, missing: ['A'], nowIso: '2026-07-16T04:00:00Z' });
    reconcileRemovals({ pending, missing: ['A'], nowIso: '2026-07-16T09:00:00Z' });
    expect(pending.A.strikes).toBe(1);
  });

  it('resets strikes when the item reappears (transient snapshot self-heals)', () => {
    const pending = {};
    reconcileRemovals({ pending, missing: ['A'], nowIso: days[0] });
    reconcileRemovals({ pending, missing: ['A'], nowIso: days[1] });
    expect(pending.A.strikes).toBe(2);
    reconcileRemovals({ pending, missing: [], nowIso: days[2] }); // A is back
    expect(pending.A).toBeUndefined();
    const { confirmed } = reconcileRemovals({ pending, missing: ['A'], nowIso: '2026-07-19T04:00:00Z' });
    expect(confirmed.size).toBe(0); // back to strike 1
  });

  it('honors a custom confirmStrikes (1 = ship same run)', () => {
    const pending = {};
    const { confirmed } = reconcileRemovals({ pending, missing: ['A'], nowIso: days[0], confirmStrikes: 1 });
    expect(confirmed.has('A')).toBe(true);
  });
});

describe('deferPlaylistRemovals', () => {
  const plId = playlistIdFor(ns, 'PL1');
  const goneId = playlistIdFor(ns, 'GONE');
  const finalSongIds = new Set([sid('P1'), sid('P2'), sid('P3')]);
  const day = (n) => `2026-07-${16 + n}T04:00:00Z`;

  it('retains a dump-absent playlist (pruned) until confirmed, then drops it', () => {
    const pending = {};
    const oldPlaylists = [
      { id: plId, name: 'Keep', songIds: [sid('P1')] },
      { id: goneId, name: 'Deleted', songIds: [sid('P2'), sid('NOT_IN_LIB')] },
    ];
    const merged = [{ id: plId, name: 'Keep', songIds: [sid('P1')] }];
    for (const n of [0, 1]) {
      const out = deferPlaylistRemovals({ merged, oldPlaylists, pending, finalSongIds, nowIso: day(n) });
      expect(out.map((p) => p.name)).toEqual(['Keep', 'Deleted']); // reinserted at old index (end)
      expect(out[1].songIds).toEqual([sid('P2')]); // pruned to live songs
    }
    const out3 = deferPlaylistRemovals({ merged, oldPlaylists, pending, finalSongIds, nowIso: day(2) });
    expect(out3.map((p) => p.name)).toEqual(['Keep']);
    expect(pending.playlists[goneId]).toBeUndefined();
  });

  it('reinserts a membership-removed song at its old index until confirmed', () => {
    const pending = {};
    const oldPlaylists = [{ id: plId, name: 'Mix', songIds: [sid('P1'), sid('P2'), sid('P3')] }];
    const merged = [{ id: plId, name: 'Mix', songIds: [sid('P1'), sid('P3')] }]; // P2 removed in Music
    const out1 = deferPlaylistRemovals({ merged, oldPlaylists, pending, finalSongIds, nowIso: day(0) });
    expect(out1[0].songIds).toEqual([sid('P1'), sid('P2'), sid('P3')]); // retained in place
    deferPlaylistRemovals({ merged, oldPlaylists, pending, finalSongIds, nowIso: day(1) });
    const out3 = deferPlaylistRemovals({ merged, oldPlaylists, pending, finalSongIds, nowIso: day(2) });
    expect(out3[0].songIds).toEqual([sid('P1'), sid('P3')]); // confirmed — ships
    expect(pending.memberships[membershipKey(plId, sid('P2'))]).toBeUndefined();
  });

  it('membership reappearing resets its pending strike', () => {
    const pending = {};
    const oldPlaylists = [{ id: plId, name: 'Mix', songIds: [sid('P1'), sid('P2')] }];
    const removedOnce = [{ id: plId, name: 'Mix', songIds: [sid('P1')] }];
    deferPlaylistRemovals({ merged: removedOnce, oldPlaylists, pending, finalSongIds, nowIso: day(0) });
    expect(pending.memberships[membershipKey(plId, sid('P2'))].strikes).toBe(1);
    const backAgain = [{ id: plId, name: 'Mix', songIds: [sid('P1'), sid('P2')] }];
    deferPlaylistRemovals({ merged: backAgain, oldPlaylists, pending, finalSongIds, nowIso: day(1) });
    expect(pending.memberships[membershipKey(plId, sid('P2'))]).toBeUndefined();
  });

  it('does not treat a library-wide song removal as a membership edit', () => {
    const pending = {};
    const oldPlaylists = [{ id: plId, name: 'Mix', songIds: [sid('P1'), sid('LIBGONE')] }];
    const merged = [{ id: plId, name: 'Mix', songIds: [sid('P1')] }];
    deferPlaylistRemovals({ merged, oldPlaylists, pending, finalSongIds, nowIso: day(0) });
    expect(Object.keys(pending.memberships)).toEqual([]); // LIBGONE ∉ finalSongIds — not a playlist edit
  });

  it('a new playlist and an unchanged playlist pass through untouched', () => {
    const pending = {};
    const oldPlaylists = [{ id: plId, name: 'Mix', songIds: [sid('P1')] }];
    const merged = [
      { id: plId, name: 'Mix', songIds: [sid('P1')] },
      { id: playlistIdFor(ns, 'NEW'), name: 'Brand New', songIds: [sid('P2')] },
    ];
    const out = deferPlaylistRemovals({ merged, oldPlaylists, pending, finalSongIds, nowIso: day(0) });
    expect(out).toEqual(merged);
    expect(pending.playlists).toEqual({});
    expect(pending.memberships).toEqual({});
  });
});

describe('nonMusicFlag', () => {
  it('does not let media kind "unknown" suppress the Kind fallback', () => {
    expect(nonMusicFlag({ mediaKind: 'unknown', kind: 'QuickTime movie file' })).toBe('Has Video');
    expect(nonMusicFlag({ mediaKind: 'unknown', kind: 'AAC audio file' })).toBe(null);
    expect(nonMusicFlag({ mediaKind: 'song', kind: 'Protected MPEG-4 video file' })).toBe(null);
    expect(nonMusicFlag({ mediaKind: 'music video', kind: '' })).toBe('Has Video');
    expect(nonMusicFlag({ mediaKind: 'podcast' })).toBe('Podcast');
  });
});

describe('parsePlaylistRows (!ERR marker)', () => {
  it('distinguishes a failed track read from an empty playlist', () => {
    const rows = parsePlaylistRows('PP1\tBroken\t!ERR\nPP2\tEmpty\t\nPP3\tFull\tA,B');
    expect(rows[0]).toMatchObject({ name: 'Broken', pids: [], readError: true });
    expect(rows[1]).toMatchObject({ name: 'Empty', pids: [] });
    expect(rows[1].readError).toBeUndefined();
    expect(rows[2]).toMatchObject({ name: 'Full', pids: ['A', 'B'] });
  });
});

describe('writeLibraryXml non-music flags', () => {
  const write = (row) => {
    const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'amx-')), 'lib.xml');
    writeLibraryXml({ rows: [row], playlists: [], runStart: 0, out });
    return fs.readFileSync(out, 'utf8');
  };

  it('flags a music video so the indexer music-only filter fires', () => {
    const xml = write({ persistentID: 'V1', title: 'CONFESSIONS II', artist: 'Madonna',
      kind: 'Protected MPEG-4 video file', mediaKind: 'music video' });
    expect(xml).toContain('<key>Has Video</key><true/>');
  });

  it('falls back to Kind when mediaKind is absent (pre-v3 TSV)', () => {
    const xml = write({ persistentID: 'V2', title: 'Old Video', artist: 'X', kind: 'QuickTime movie file' });
    expect(xml).toContain('<key>Has Video</key><true/>');
  });

  it('flags podcasts and leaves plain songs unflagged', () => {
    expect(write({ persistentID: 'P1', title: 'Ep 1', artist: 'Host', mediaKind: 'podcast' }))
      .toContain('<key>Podcast</key><true/>');
    const song = write({ persistentID: 'S1', title: 'Outside', artist: 'Freddie Gibbs',
      kind: 'Apple Music AAC audio file', mediaKind: 'song' });
    for (const flag of ['Has Video', 'Movie', 'TV Show', 'Podcast', 'Audiobook']) {
      expect(song).not.toContain(`<key>${flag}</key>`);
    }
  });
});
