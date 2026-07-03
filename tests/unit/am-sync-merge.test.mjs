// Tests for the incremental Apple Music sync's diff/merge decisions — the ones that
// shipped real damage before they were extracted: the mid-edit "OTG" playlist deletion
// (2026-06-30), the perpetual "new tracks: 13" ghost churn, and snapshot-skew rows.
import { describe, it, expect } from 'vitest';
import { diffLibrary, partitionTrackRows, mergePlaylists } from '../../scripts/lib/am-sync-merge.mjs';
import { nsFor, songIdFor, playlistIdFor } from '../../scripts/lib/am-ids.mjs';
import { parsePlaylistRows, writeLibraryXml, COLS } from '../../scripts/lib/am-music.mjs';
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
