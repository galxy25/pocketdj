import { describe, it, expect } from 'vitest';
import {
  bpmBucketLabel,
  bpmBucketStart,
  groupSongs,
  musicalKeyRank,
  UNKNOWN_LABEL,
} from './grouping';
import type { SongItem } from '../types/model';

function song(over: Partial<SongItem> & { id: string }): SongItem {
  return {
    sourceId: 's1',
    type: 'song',
    createdAt: 0,
    updatedAt: 0,
    artist: 'Artist',
    name: 'Name',
    sentimentKeywords: [],
    explicit: false,
    bpm: null,
    key: null,
    ...over,
  };
}

describe('bpm bucketing helpers', () => {
  it('floors into decade buckets', () => {
    expect(bpmBucketStart(124)).toBe(120);
    expect(bpmBucketStart(120)).toBe(120);
    expect(bpmBucketStart(129)).toBe(120);
    expect(bpmBucketStart(130)).toBe(130);
    expect(bpmBucketStart(95)).toBe(90);
  });
  it('labels a decade bucket (no unit suffix — the mode supplies context)', () => {
    expect(bpmBucketLabel(120)).toBe('120–130');
    expect(bpmBucketLabel(90)).toBe('90–100');
  });
});

describe('musicalKeyRank', () => {
  it('returns null for nullish / unparseable input', () => {
    expect(musicalKeyRank(null)).toBeNull();
    expect(musicalKeyRank(undefined)).toBeNull();
    expect(musicalKeyRank('')).toBeNull();
    expect(musicalKeyRank('8A')).toBeNull();
    expect(musicalKeyRank('H major')).toBeNull();
  });

  it('orders chromatically C..B, minor before major within a pitch', () => {
    const keys = ['C major', 'C minor', 'A minor', 'A major', 'F# major'];
    const sorted = [...keys].sort((x, y) => musicalKeyRank(x)! - musicalKeyRank(y)!);
    expect(sorted).toEqual(['C minor', 'C major', 'F# major', 'A minor', 'A major']);
  });

  it('treats enharmonic equivalents as the same pitch', () => {
    expect(musicalKeyRank('A# minor')).toBe(musicalKeyRank('Bb minor'));
    expect(musicalKeyRank('Db major')).toBe(musicalKeyRank('C# major'));
  });
});

describe('groupSongs — BPM mode', () => {
  it('buckets songs into ascending decade constellations with counts', () => {
    const songs = [
      song({ id: 'a', bpm: 128 }),
      song({ id: 'b', bpm: 122 }),
      song({ id: 'c', bpm: 95 }),
      song({ id: 'd', bpm: 138 }),
    ];
    const cons = groupSongs(songs, 'bpm');
    expect(cons.map((c) => c.label)).toEqual(['90–100', '120–130', '130–140']);
    // 122 + 128 share the 120 constellation.
    expect(cons.find((c) => c.id === '120')!.songCount).toBe(2);
    expect(cons.find((c) => c.id === '90')!.songCount).toBe(1);
  });

  it('emits a bpm BETWEEN filter spanning the decade', () => {
    const cons = groupSongs([song({ id: 'a', bpm: 124 })], 'bpm');
    expect(cons[0].filter).toEqual({ field: 'bpm', op: 'between', min: 120, max: 130 });
  });

  it('null / non-finite bpm collects into a single Unknown constellation, placed last', () => {
    const songs = [
      song({ id: 'known', bpm: 120 }),
      song({ id: 'null', bpm: null }),
      song({ id: 'inf', bpm: Infinity }),
    ];
    const cons = groupSongs(songs, 'bpm');
    const last = cons[cons.length - 1];
    expect(last.id).toBe(UNKNOWN_LABEL);
    expect(last.label).toBe(UNKNOWN_LABEL);
    expect(last.songCount).toBe(2);
    expect(last.filter).toBeNull();
  });

  it('counts every song in exactly one constellation', () => {
    const songs = [
      song({ id: 'a', bpm: 100 }),
      song({ id: 'b', bpm: 100 }),
      song({ id: 'c', bpm: null }),
    ];
    const total = groupSongs(songs, 'bpm').reduce((n, c) => n + c.songCount, 0);
    expect(total).toBe(3);
  });

  it('no Unknown constellation when every song has a bpm', () => {
    const cons = groupSongs([song({ id: 'a', bpm: 120 })], 'bpm');
    expect(cons.some((c) => c.id === UNKNOWN_LABEL)).toBe(false);
  });
});

describe('groupSongs — KEY mode, camelot notation', () => {
  it('groups by camelot, ordered by the camelot wheel, with eq filters', () => {
    const songs = [
      song({ id: 'a', camelot: '8A' }),
      song({ id: 'b', camelot: '1A' }),
      song({ id: 'c', camelot: '8A' }),
      song({ id: 'd', camelot: '12B' }),
    ];
    const cons = groupSongs(songs, 'key', 'camelot');
    expect(cons.map((c) => c.label)).toEqual(['1A', '8A', '12B']);
    expect(cons.find((c) => c.id === '8A')!.songCount).toBe(2);
    expect(cons.find((c) => c.id === '8A')!.filter).toEqual({
      field: 'camelot',
      op: 'eq',
      value: '8A',
    });
  });

  it('null / unparseable camelot -> Unknown, last, filter null', () => {
    const songs = [
      song({ id: 'k', camelot: '8A' }),
      song({ id: 'n', camelot: null }),
      song({ id: 'bad', camelot: 'nope' }),
      song({ id: 'm' }),
    ];
    const cons = groupSongs(songs, 'key', 'camelot');
    const last = cons[cons.length - 1];
    expect(last.id).toBe(UNKNOWN_LABEL);
    expect(last.songCount).toBe(3);
    expect(last.filter).toBeNull();
  });
});

describe('groupSongs — KEY mode, musical notation', () => {
  it('groups by key, pitch-ordered (minor before major), with eq filters', () => {
    const songs = [
      song({ id: 'a', key: 'A major' }),
      song({ id: 'b', key: 'A minor' }),
      song({ id: 'c', key: 'C major' }),
      song({ id: 'd', key: 'A minor' }),
    ];
    const cons = groupSongs(songs, 'key', 'musical');
    expect(cons.map((c) => c.label)).toEqual(['C major', 'A minor', 'A major']);
    expect(cons.find((c) => c.id === 'A minor')!.songCount).toBe(2);
    expect(cons.find((c) => c.id === 'A minor')!.filter).toEqual({
      field: 'key',
      op: 'eq',
      value: 'A minor',
    });
  });

  it('defaults keyNotation to camelot when omitted', () => {
    const songs = [song({ id: 'a', camelot: '8A', key: 'A minor' })];
    expect(groupSongs(songs, 'key')[0].label).toBe('8A');
    expect(groupSongs(songs, 'key')[0].filter).toEqual({
      field: 'camelot',
      op: 'eq',
      value: '8A',
    });
  });

  it('null / unparseable musical key -> Unknown, last', () => {
    const songs = [
      song({ id: 'k', key: 'A minor' }),
      song({ id: 'n', key: null }),
      song({ id: 'm' }),
    ];
    const cons = groupSongs(songs, 'key', 'musical');
    expect(cons[cons.length - 1].id).toBe(UNKNOWN_LABEL);
    expect(cons[cons.length - 1].songCount).toBe(2);
  });
});

describe('groupSongs — determinism + guards', () => {
  it('is deterministic regardless of input order', () => {
    const songs = [
      song({ id: 'a', bpm: 128 }),
      song({ id: 'b', bpm: 95 }),
      song({ id: 'c', bpm: 128 }),
    ];
    const forward = groupSongs(songs, 'bpm');
    const reversed = groupSongs([...songs].reverse(), 'bpm');
    expect(forward).toEqual(reversed);
  });

  it('returns an empty list for no songs', () => {
    expect(groupSongs([], 'bpm')).toEqual([]);
    expect(groupSongs([], 'key', 'musical')).toEqual([]);
  });

  it('throws if called with genre (genre is album-based, handled by computeLayout)', () => {
    expect(() => groupSongs([], 'genre' as never)).toThrow();
  });
});
