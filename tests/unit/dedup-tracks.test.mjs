// Golden tests for the deterministic track DEDUP fold (pass 1 of track-cleanup).
// dedup-tracks.mjs exports normSongName + dedupTracks (no I/O when imported), modeled on
// the real Sade "Diamond Life" / Isley "Between the Sheets" cases.
import { describe, it, expect } from 'vitest';
import {
  normSongName,
  completeness,
  dedupTracks,
} from '../../.claude/skills/analog-indexer/lib/dedup-tracks.mjs';

// minimal index builder: albums[] with trackList of songIds, songs[] flat
function mkIndex(album, songs) {
  return { albums: [album], songs };
}

describe('normSongName', () => {
  it('lowercases, collapses whitespace, strips surrounding punctuation', () => {
    expect(normSongName('  Smooth   Operator  ')).toBe('smooth operator');
    expect(normSongName('"Cherry Pie"')).toBe('cherry pie');
    expect(normSongName('Sally!')).toBe('sally');
  });
  it('keeps interior punctuation + parentheticals so VERSIONS never merge', () => {
    expect(normSongName('Between the Sheets')).not.toBe(
      normSongName('Between the Sheets (Instrumental Version)'),
    );
    expect(normSongName('Smooth Operator')).not.toBe(normSongName('Smooth Operator / Snake Bite'));
  });
  it('folds diacritics and unifies apostrophes', () => {
    expect(normSongName('Café')).toBe(normSongName('Cafe'));
    expect(normSongName('Frankie’s First Affair')).toBe(normSongName("Frankie's First Affair"));
  });
});

describe('completeness', () => {
  it('ranks the audio-enriched copy above a bare metadata row', () => {
    const rich = { bpm: 118, key: 'A minor', camelot: '8A', lyrics: 'x', sentimentKeywords: ['a'] };
    const bare = { bpm: null, key: null, camelot: null, lyrics: 'x', sentimentKeywords: ['a'] };
    expect(completeness(rich)).toBeGreaterThan(completeness(bare));
  });
});

describe('dedupTracks', () => {
  it('drops the duplicate (Sade case) keeping the copy WITH bpm/key', () => {
    // "Smooth Operator" twice: #1 rich, then a bare metadata copy. Plus a distinct
    // "Smooth Operator / Snake Bite" that must NOT be merged.
    const album = {
      id: 'alb_sade',
      artist: 'Sade',
      name: 'Diamond Life',
      trackList: ['sng_rich', 'sng_bare', 'sng_medley'],
    };
    const songs = [
      { id: 'sng_rich', albumId: 'alb_sade', name: 'Smooth Operator', trackNumber: 1, bpm: 118, key: 'A minor', camelot: '8A' },
      { id: 'sng_bare', albumId: 'alb_sade', name: 'Smooth Operator', trackNumber: 1, bpm: null, key: null },
      { id: 'sng_medley', albumId: 'alb_sade', name: 'Smooth Operator / Snake Bite', trackNumber: 1, bpm: null },
    ];
    const idx = mkIndex(album, songs);
    const r = dedupTracks(idx);

    expect(r.tracksDropped).toBe(1);
    expect(r.droppedSongIds).toEqual(['sng_bare']);
    expect(r.albumsDeduped).toBe(1);
    // kept rich copy + the distinct medley remain; bare copy gone from BOTH lists
    expect(idx.albums[0].trackList).toEqual(['sng_rich', 'sng_medley']);
    expect(idx.songs.map((s) => s.id).sort()).toEqual(['sng_medley', 'sng_rich']);
    // the keeper keeps its bpm/key (we never touch the kept song's audio data)
    expect(idx.songs.find((s) => s.id === 'sng_rich').bpm).toBe(118);
  });

  it('on a tie keeps the FIRST (earliest) occurrence', () => {
    const album = { id: 'alb_t', artist: 'A', name: 'B', trackList: ['s1', 's2'] };
    const songs = [
      { id: 's1', name: 'Same Song', bpm: null },
      { id: 's2', name: 'same   song', bpm: null }, // normalizes equal, equal completeness
    ];
    const idx = mkIndex(album, songs);
    const r = dedupTracks(idx);
    expect(r.droppedSongIds).toEqual(['s2']);
    expect(idx.albums[0].trackList).toEqual(['s1']);
  });

  it('does NOT merge distinct versions (Isley-style) — leaves them all', () => {
    const album = {
      id: 'alb_isley',
      artist: 'the Isley Brothers',
      name: 'Between the Sheets',
      trackList: ['a', 'b', 'c'],
    };
    const songs = [
      { id: 'a', name: 'Between the Sheets', trackNumber: 4 },
      { id: 'b', name: 'Between the Sheets (Instrumental Version)', trackNumber: 1 },
      { id: 'c', name: 'Between the Sheets (Single Version)', trackNumber: 5 },
    ];
    const idx = mkIndex(album, songs);
    const r = dedupTracks(idx);
    expect(r.tracksDropped).toBe(0);
    expect(r.albumsDeduped).toBe(0);
    expect(idx.songs).toHaveLength(3);
  });

  it('scopes dedup to the album — same name on a different album is untouched', () => {
    const idx = {
      albums: [
        { id: 'alb1', trackList: ['x1'] },
        { id: 'alb2', trackList: ['x2'] },
      ],
      songs: [
        { id: 'x1', albumId: 'alb1', name: 'Shared Title' },
        { id: 'x2', albumId: 'alb2', name: 'Shared Title' },
      ],
    };
    const r = dedupTracks(idx);
    expect(r.tracksDropped).toBe(0);
    expect(idx.songs).toHaveLength(2);
  });

  it('is idempotent', () => {
    const album = { id: 'alb', trackList: ['s1', 's2'] };
    const songs = [
      { id: 's1', name: 'Dup', bpm: 100 },
      { id: 's2', name: 'Dup', bpm: null },
    ];
    const idx = mkIndex(album, songs);
    dedupTracks(idx);
    const afterFirst = JSON.parse(JSON.stringify(idx));
    const r2 = dedupTracks(idx);
    expect(r2.tracksDropped).toBe(0);
    expect(idx).toEqual(afterFirst);
  });
});
