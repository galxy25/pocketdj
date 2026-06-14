import { describe, it, expect } from 'vitest';
import { sortItems, sortHash } from './sortEngine';
import type { AlbumItem, SongItem, MusicItem } from '../types/model';
import type { SortState } from '../types/filter';

let seq = 0;
function album(over: Partial<AlbumItem> = {}): AlbumItem {
  seq++;
  return {
    id: over.id ?? `alb_${seq}`,
    sourceId: 's1',
    type: 'album',
    createdAt: 0,
    updatedAt: 0,
    artist: 'Artist',
    name: 'Name',
    trackIds: [],
    ...over,
  };
}
function song(over: Partial<SongItem> = {}): SongItem {
  seq++;
  return {
    id: over.id ?? `sng_${seq}`,
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
const ids = (items: MusicItem[]) => items.map((i) => i.id);
const sort = (field: string, dir: 'asc' | 'desc'): SortState => ({ field, dir });

describe('sortItems — passthrough', () => {
  it('returns the input unchanged when sort is null', () => {
    const items = [album({ id: 'b' }), album({ id: 'a' })];
    expect(sortItems(items, null)).toBe(items);
  });

  it('returns the input unchanged when the sort field is unknown', () => {
    const items = [album({ id: 'b' }), album({ id: 'a' })];
    expect(sortItems(items, sort('bogus', 'asc'))).toBe(items);
  });

  it('does not mutate the input array', () => {
    const items = [album({ id: 'b', year: 2 }), album({ id: 'a', year: 1 })];
    const before = ids(items);
    sortItems(items, sort('year', 'asc'));
    expect(ids(items)).toEqual(before);
  });
});

describe('sortItems — numeric', () => {
  it('asc orders by numeric value (not string)', () => {
    const items = [
      album({ id: 'y100', year: 100 }),
      album({ id: 'y9', year: 9 }),
      album({ id: 'y20', year: 20 }),
    ];
    expect(ids(sortItems(items, sort('year', 'asc')))).toEqual(['y9', 'y20', 'y100']);
  });

  it('desc reverses numeric order', () => {
    const items = [
      album({ id: 'y9', year: 9 }),
      album({ id: 'y100', year: 100 }),
      album({ id: 'y20', year: 20 }),
    ];
    expect(ids(sortItems(items, sort('year', 'desc')))).toEqual(['y100', 'y20', 'y9']);
  });
});

describe('sortItems — string (locale, case-insensitive)', () => {
  it('asc sorts alphabetically, ignoring case', () => {
    const items = [
      album({ id: 'c', artist: 'cherry' }),
      album({ id: 'A', artist: 'Apple' }),
      album({ id: 'b', artist: 'Banana' }),
    ];
    expect(ids(sortItems(items, sort('artist', 'asc')))).toEqual(['A', 'b', 'c']);
  });

  it('desc reverses', () => {
    const items = [
      album({ id: 'a', artist: 'Apple' }),
      album({ id: 'b', artist: 'Banana' }),
    ];
    expect(ids(sortItems(items, sort('artist', 'desc')))).toEqual(['b', 'a']);
  });
});

describe('sortItems — nulls and empty strings sort LAST regardless of direction', () => {
  it('asc: null/empty values at the end', () => {
    const items = [
      album({ id: 'has', year: 2000 }),
      album({ id: 'none', year: undefined }),
      album({ id: 'has2', year: 1990 }),
    ];
    expect(ids(sortItems(items, sort('year', 'asc')))).toEqual(['has2', 'has', 'none']);
  });

  it('desc: null still last (not first)', () => {
    const items = [
      album({ id: 'has', year: 2000 }),
      album({ id: 'none', year: undefined }),
      album({ id: 'has2', year: 1990 }),
    ];
    expect(ids(sortItems(items, sort('year', 'desc')))).toEqual(['has', 'has2', 'none']);
  });

  it('empty string is treated as null (last)', () => {
    const items = [
      album({ id: 'z', artist: 'Z' }),
      album({ id: 'empty', artist: '' }),
      album({ id: 'a', artist: 'A' }),
    ];
    expect(ids(sortItems(items, sort('artist', 'asc')))).toEqual(['a', 'z', 'empty']);
  });

  it('all-null preserves original (stable) order', () => {
    const items = [
      album({ id: 'first', year: undefined }),
      album({ id: 'second', year: undefined }),
    ];
    expect(ids(sortItems(items, sort('year', 'asc')))).toEqual(['first', 'second']);
  });
});

describe('sortItems — stable tiebreak preserves input order for equal keys', () => {
  it('equal values keep their relative order (asc)', () => {
    const items = [
      album({ id: 'first', year: 2000 }),
      album({ id: 'second', year: 2000 }),
      album({ id: 'third', year: 2000 }),
    ];
    expect(ids(sortItems(items, sort('year', 'asc')))).toEqual(['first', 'second', 'third']);
  });

  it('equal values keep INPUT order even on desc (tiebreak is not flipped)', () => {
    const items = [
      album({ id: 'first', year: 2000 }),
      album({ id: 'second', year: 2000 }),
    ];
    expect(ids(sortItems(items, sort('year', 'desc')))).toEqual(['first', 'second']);
  });
});

describe('sortItems — boolean', () => {
  it('asc: false before true', () => {
    const items = [
      song({ id: 'e', explicit: true }),
      song({ id: 'c', explicit: false }),
    ];
    expect(ids(sortItems(items, sort('explicit', 'asc')))).toEqual(['c', 'e']);
  });

  it('desc: true before false', () => {
    const items = [
      song({ id: 'c', explicit: false }),
      song({ id: 'e', explicit: true }),
    ];
    expect(ids(sortItems(items, sort('explicit', 'desc')))).toEqual(['e', 'c']);
  });
});

describe('sortItems — mixed item types (field accessor returns undefined for the other type)', () => {
  it('songs (no genre field) sort as null/last when sorting albums by genre', () => {
    const items = [
      song({ id: 'sng' }),
      album({ id: 'rock', genre: 'rock' }),
    ];
    // genre applies to albums; songs get undefined -> last.
    expect(ids(sortItems(items, sort('genre', 'asc')))).toEqual(['rock', 'sng']);
  });
});

describe('sortHash', () => {
  it('encodes field and direction', () => {
    expect(sortHash(sort('year', 'asc'))).toBe('year:asc');
    expect(sortHash(sort('artist', 'desc'))).toBe('artist:desc');
  });

  it('null sort hashes to empty string', () => {
    expect(sortHash(null)).toBe('');
  });
});
