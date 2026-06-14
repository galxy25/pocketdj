// Golden tests for the TRACK-NUMBER REPAIR fold (pass 2 of track-cleanup).
// renumber-tracks.mjs exports flagAlbum + buildCanonicalIndex + renumberTracks (no I/O on
// import), modeled on the real Isley "Between the Sheets" case (15 distinct tracks
// mis-numbered 1..5,1..5,1..5).
import { describe, it, expect } from 'vitest';
import {
  flagAlbum,
  buildCanonicalIndex,
  renumberTracks,
} from '../../.claude/skills/analog-indexer/lib/renumber-tracks.mjs';

describe('flagAlbum', () => {
  it('flags duplicate trackNumbers', () => {
    const songs = [{ trackNumber: 1 }, { trackNumber: 1 }, { trackNumber: 2 }];
    expect(flagAlbum({ audioTracks: [] }, songs).dupNumbers).toBe(true);
    expect(flagAlbum({ audioTracks: [] }, songs).flagged).toBe(true);
  });
  it('does NOT flag a clean 1..N album', () => {
    const songs = [{ trackNumber: 1 }, { trackNumber: 2 }, { trackNumber: 3 }];
    expect(flagAlbum({ audioTracks: [{}, {}, {}] }, songs).flagged).toBe(false);
  });
  it('flags a large trackList-vs-audio count mismatch', () => {
    const songs = Array.from({ length: 15 }, (_, i) => ({ trackNumber: i + 1 }));
    // 15 tracks vs 4 audio segments -> mismatch
    expect(flagAlbum({ audioTracks: [{}, {}, {}, {}] }, songs).countMismatch).toBe(true);
  });
  it('tolerates a small count difference (segmentation is only a guide)', () => {
    const songs = Array.from({ length: 10 }, (_, i) => ({ trackNumber: i + 1 }));
    expect(flagAlbum({ audioTracks: Array(9).fill({}) }, songs).countMismatch).toBe(false);
  });
});

// Build the Isley fixture: 15 DISTINCT tracks, mis-numbered 1..5,1..5,1..5, in a sensible
// "current order". (Subset shown; numbers intentionally collide.)
function isleyIndex() {
  const titles = [
    'Choosey Lover', 'Touch Me', 'I Need Your Body', 'Between the Sheets', "Let's Make Love Tonight",
    'Ballad for the Fallen Soldier', 'Slow Down Children', 'Way Out Love', "Gettin' Over", 'Rock You Good',
    'Between the Sheets (Instrumental Version)', 'Choosey Lover (Instrumental Version)',
    'I Need Your Body (Instrumental Version)', "Let's Make Love Tonight (Instrumental Version)",
    'Between the Sheets (Single Version)',
  ];
  const songs = titles.map((name, i) => ({
    id: `s${i}`,
    name,
    trackNumber: (i % 5) + 1, // 1..5,1..5,1..5
  }));
  const album = {
    id: 'alb_isley',
    artist: 'the Isley Brothers',
    name: 'Between the Sheets',
    trackList: songs.map((s) => s.id),
    audioTracks: Array(10).fill({}),
  };
  return { albums: [album], songs };
}

describe('renumberTracks — sequential fallback', () => {
  it('renumbers 15 distinct mis-numbered tracks to 1..15 in current order', () => {
    const idx = isleyIndex();
    const r = renumberTracks(idx, null);
    expect(r.albumsRenumbered).toBe(1);
    expect(r.viaSequential).toBe(1);
    expect(r.viaCanonical).toBe(0);
    const nums = idx.songs.map((s) => s.trackNumber);
    expect(nums).toEqual(Array.from({ length: 15 }, (_, i) => i + 1));
    // order preserved, no songs added/removed
    expect(idx.albums[0].trackList).toEqual(idx.songs.map((s) => s.id));
    expect(idx.songs).toHaveLength(15);
  });

  it('leaves a clean album untouched', () => {
    const idx = {
      albums: [{ id: 'a', trackList: ['s1', 's2'], audioTracks: [{}, {}] }],
      songs: [{ id: 's1', name: 'One', trackNumber: 1 }, { id: 's2', name: 'Two', trackNumber: 2 }],
    };
    const r = renumberTracks(idx, null);
    expect(r.albumsRenumbered).toBe(0);
    expect(idx.songs.map((s) => s.trackNumber)).toEqual([1, 2]);
  });

  it('does NOT renumber an album flagged ONLY by audio-count mismatch but already 1..N', () => {
    // 5 tracks, cleanly numbered 1..5, but only 1 audio segment -> flagged by countMismatch.
    // Its numbering is fine, so it must be left untouched (audio is a guide, not gospel).
    const songs = Array.from({ length: 5 }, (_, i) => ({ id: `s${i}`, name: `T${i}`, trackNumber: i + 1 }));
    const idx = {
      albums: [{ id: 'a', trackList: songs.map((s) => s.id), audioTracks: [{}] }],
      songs,
    };
    const r = renumberTracks(idx, null);
    expect(r.albumsRenumbered).toBe(0);
    expect(idx.songs.map((s) => s.trackNumber)).toEqual([1, 2, 3, 4, 5]);
  });
});

describe('renumberTracks — canonical (web-search) order', () => {
  it('orders songs by the canonical tracklist matched fuzzily by name', () => {
    // mis-ordered trackList; canonical says the real order is reversed.
    const idx = {
      albums: [
        {
          id: 'alb_x',
          artist: 'Artist',
          name: 'Album',
          trackList: ['c', 'a', 'b'],
          audioTracks: [{}, {}, {}],
        },
      ],
      songs: [
        { id: 'a', name: 'Alpha Song', trackNumber: 1 },
        { id: 'b', name: 'Bravo Song', trackNumber: 1 }, // dup number -> flagged
        { id: 'c', name: 'Charlie Song', trackNumber: 2 },
      ],
    };
    const canon = buildCanonicalIndex([
      { albumId: 'alb_x', tracks: ['Alpha Song', 'Bravo Song', 'Charlie Song'] },
    ]);
    const r = renumberTracks(idx, canon);
    expect(r.viaCanonical).toBe(1);
    expect(r.viaSequential).toBe(0);
    // re-ordered to canonical a,b,c and numbered 1,2,3
    expect(idx.albums[0].trackList).toEqual(['a', 'b', 'c']);
    const byId = new Map(idx.songs.map((s) => [s.id, s.trackNumber]));
    expect([byId.get('a'), byId.get('b'), byId.get('c')]).toEqual([1, 2, 3]);
  });

  it('matches canonical entries by artist+album when no albumId is given', () => {
    const idx = isleyIndex();
    const canon = buildCanonicalIndex([
      {
        artist: 'The Isley Brothers',
        album: 'Between the Sheets',
        tracks: [
          'Choosey Lover', 'Touch Me', 'I Need Your Body', 'Between the Sheets', "Let's Make Love Tonight",
          'Ballad for the Fallen Soldier', 'Slow Down Children', 'Way Out Love', "Gettin' Over", 'Rock You Good',
          'Between the Sheets (Instrumental Version)', 'Choosey Lover (Instrumental Version)',
          'I Need Your Body (Instrumental Version)', "Let's Make Love Tonight (Instrumental Version)",
          'Between the Sheets (Single Version)',
        ],
      },
    ]);
    const r = renumberTracks(idx, canon);
    expect(r.viaCanonical).toBe(1);
    expect(idx.songs.map((s) => s.trackNumber)).toEqual(Array.from({ length: 15 }, (_, i) => i + 1));
  });

  it('falls back to sequential when canonical matches too few songs', () => {
    const idx = isleyIndex();
    const canon = buildCanonicalIndex([
      { albumId: 'alb_isley', tracks: ['Totally Unrelated', 'Nope Nope', 'Wrong Album'] },
    ]);
    const r = renumberTracks(idx, canon);
    expect(r.viaSequential).toBe(1);
    expect(r.viaCanonical).toBe(0);
    expect(idx.songs.map((s) => s.trackNumber)).toEqual(Array.from({ length: 15 }, (_, i) => i + 1));
  });
});

describe('renumberTracks — idempotent', () => {
  it('re-running on repaired data is a no-op', () => {
    const idx = isleyIndex();
    renumberTracks(idx, null);
    const after = JSON.parse(JSON.stringify(idx));
    const r2 = renumberTracks(idx, null);
    expect(r2.albumsRenumbered).toBe(0);
    expect(idx).toEqual(after);
  });
});
