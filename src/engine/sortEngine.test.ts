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
    expect(sortItems(items, [sort('bogus', 'asc')])).toBe(items);
  });

  it('does not mutate the input array', () => {
    const items = [album({ id: 'b', year: 2 }), album({ id: 'a', year: 1 })];
    const before = ids(items);
    sortItems(items, [sort('year', 'asc')]);
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
    expect(ids(sortItems(items, [sort('year', 'asc')]))).toEqual(['y9', 'y20', 'y100']);
  });

  it('desc reverses numeric order', () => {
    const items = [
      album({ id: 'y9', year: 9 }),
      album({ id: 'y100', year: 100 }),
      album({ id: 'y20', year: 20 }),
    ];
    expect(ids(sortItems(items, [sort('year', 'desc')]))).toEqual(['y100', 'y20', 'y9']);
  });
});

describe('sortItems — string (locale, case-insensitive)', () => {
  it('asc sorts alphabetically, ignoring case', () => {
    const items = [
      album({ id: 'c', artist: 'cherry' }),
      album({ id: 'A', artist: 'Apple' }),
      album({ id: 'b', artist: 'Banana' }),
    ];
    expect(ids(sortItems(items, [sort('artist', 'asc')]))).toEqual(['A', 'b', 'c']);
  });

  it('desc reverses', () => {
    const items = [
      album({ id: 'a', artist: 'Apple' }),
      album({ id: 'b', artist: 'Banana' }),
    ];
    expect(ids(sortItems(items, [sort('artist', 'desc')]))).toEqual(['b', 'a']);
  });
});

describe('sortItems — nulls and empty strings sort LAST regardless of direction', () => {
  it('asc: null/empty values at the end', () => {
    const items = [
      album({ id: 'has', year: 2000 }),
      album({ id: 'none', year: undefined }),
      album({ id: 'has2', year: 1990 }),
    ];
    expect(ids(sortItems(items, [sort('year', 'asc')]))).toEqual(['has2', 'has', 'none']);
  });

  it('desc: null still last (not first)', () => {
    const items = [
      album({ id: 'has', year: 2000 }),
      album({ id: 'none', year: undefined }),
      album({ id: 'has2', year: 1990 }),
    ];
    expect(ids(sortItems(items, [sort('year', 'desc')]))).toEqual(['has', 'has2', 'none']);
  });

  it('empty string is treated as null (last)', () => {
    const items = [
      album({ id: 'z', artist: 'Z' }),
      album({ id: 'empty', artist: '' }),
      album({ id: 'a', artist: 'A' }),
    ];
    expect(ids(sortItems(items, [sort('artist', 'asc')]))).toEqual(['a', 'z', 'empty']);
  });

  it('all-null preserves original (stable) order', () => {
    const items = [
      album({ id: 'first', year: undefined }),
      album({ id: 'second', year: undefined }),
    ];
    expect(ids(sortItems(items, [sort('year', 'asc')]))).toEqual(['first', 'second']);
  });
});

describe('sortItems — stable tiebreak preserves input order for equal keys', () => {
  it('equal values keep their relative order (asc)', () => {
    const items = [
      album({ id: 'first', year: 2000 }),
      album({ id: 'second', year: 2000 }),
      album({ id: 'third', year: 2000 }),
    ];
    expect(ids(sortItems(items, [sort('year', 'asc')]))).toEqual(['first', 'second', 'third']);
  });

  it('equal values keep INPUT order even on desc (tiebreak is not flipped)', () => {
    const items = [
      album({ id: 'first', year: 2000 }),
      album({ id: 'second', year: 2000 }),
    ];
    expect(ids(sortItems(items, [sort('year', 'desc')]))).toEqual(['first', 'second']);
  });
});

describe('sortItems — boolean', () => {
  it('asc: false before true', () => {
    const items = [
      song({ id: 'e', explicit: true }),
      song({ id: 'c', explicit: false }),
    ];
    expect(ids(sortItems(items, [sort('explicit', 'asc')]))).toEqual(['c', 'e']);
  });

  it('desc: true before false', () => {
    const items = [
      song({ id: 'c', explicit: false }),
      song({ id: 'e', explicit: true }),
    ];
    expect(ids(sortItems(items, [sort('explicit', 'desc')]))).toEqual(['e', 'c']);
  });
});

describe('sortItems — bpm (numeric, nulls last)', () => {
  it('asc orders by numeric bpm', () => {
    const items = [
      song({ id: 'b128', bpm: 128 }),
      song({ id: 'b90', bpm: 90 }),
      song({ id: 'b174', bpm: 174 }),
    ];
    expect(ids(sortItems(items, [sort('bpm', 'asc')]))).toEqual(['b90', 'b128', 'b174']);
  });

  it('desc reverses bpm order', () => {
    const items = [
      song({ id: 'b90', bpm: 90 }),
      song({ id: 'b174', bpm: 174 }),
      song({ id: 'b128', bpm: 128 }),
    ];
    expect(ids(sortItems(items, [sort('bpm', 'desc')]))).toEqual(['b174', 'b128', 'b90']);
  });

  it('null bpm sorts last regardless of direction', () => {
    const items = [
      song({ id: 'has', bpm: 120 }),
      song({ id: 'none', bpm: null }),
      song({ id: 'has2', bpm: 100 }),
    ];
    expect(ids(sortItems(items, [sort('bpm', 'asc')]))).toEqual(['has2', 'has', 'none']);
    expect(ids(sortItems(items, [sort('bpm', 'desc')]))).toEqual(['has', 'has2', 'none']);
  });
});

describe('sortItems — key (Camelot harmonic order, not alphabetical)', () => {
  it('orders by wheel number then letter (A before B), NOT lexicographically', () => {
    // Lexicographic order would be "10A","11A","1A","2A","2B" — the camelot field
    // must instead yield 1A,2A,2B,10A,11A.
    const items = [
      song({ id: 't10A', camelot: '10A' }),
      song({ id: 't2B', camelot: '2B' }),
      song({ id: 't1A', camelot: '1A' }),
      song({ id: 't11A', camelot: '11A' }),
      song({ id: 't2A', camelot: '2A' }),
    ];
    expect(ids(sortItems(items, [sort('camelot', 'asc')]))).toEqual([
      't1A', 't2A', 't2B', 't10A', 't11A',
    ]);
  });

  it('desc reverses harmonic order', () => {
    const items = [
      song({ id: 't1A', camelot: '1A' }),
      song({ id: 't12B', camelot: '12B' }),
      song({ id: 't6A', camelot: '6A' }),
    ];
    expect(ids(sortItems(items, [sort('camelot', 'desc')]))).toEqual(['t12B', 't6A', 't1A']);
  });

  it('null/unparseable camelot sorts last regardless of direction', () => {
    const items = [
      song({ id: 'good', camelot: '5A' }),
      song({ id: 'bad', camelot: 'not-a-key' }),
      song({ id: 'none', camelot: null }),
      song({ id: 'good2', camelot: '3B' }),
    ];
    expect(ids(sortItems(items, [sort('camelot', 'asc')]))).toEqual([
      'good2', 'good', 'bad', 'none',
    ]);
    // nulls/unparseable still last on desc; their input order is preserved among themselves.
    expect(ids(sortItems(items, [sort('camelot', 'desc')]))).toEqual([
      'good', 'good2', 'bad', 'none',
    ]);
  });
});

describe('sortItems — mixed item types (field accessor returns undefined for the other type)', () => {
  it('songs (no genre field) sort as null/last when sorting albums by genre', () => {
    const items = [
      song({ id: 'sng' }),
      album({ id: 'rock', genre: 'rock' }),
    ];
    // genre applies to albums; songs get undefined -> last.
    expect(ids(sortItems(items, [sort('genre', 'asc')]))).toEqual(['rock', 'sng']);
  });
});

describe('sortHash', () => {
  it('encodes field and direction', () => {
    expect(sortHash([sort('year', 'asc')])).toBe('year:asc');
    expect(sortHash([sort('artist', 'desc')])).toBe('artist:desc');
  });

  it('null sort hashes to empty string', () => {
    expect(sortHash(null)).toBe('');
  });
});

describe('sortItems — multi-key', () => {
  it('(a) primary tie broken by secondary (equal bpm -> camelot harmonic asc)', () => {
    const items = [
      song({ id: 'b', bpm: 120, camelot: '5A' }),
      song({ id: 'a', bpm: 120, camelot: '1A' }),
      song({ id: 'c', bpm: 120, camelot: '9A' }),
    ];
    expect(ids(sortItems(items, [sort('bpm', 'asc'), sort('camelot', 'asc')]))).toEqual([
      'a', 'b', 'c',
    ]);
  });

  it('(b) mixed dirs: equal bpm group ordered by DESC camelot (harmonic, reversed)', () => {
    const items = [
      song({ id: 'a', bpm: 120, camelot: '1A' }),
      song({ id: 'c', bpm: 120, camelot: '9A' }),
      song({ id: 'b', bpm: 120, camelot: '5A' }),
    ];
    expect(ids(sortItems(items, [sort('bpm', 'asc'), sort('camelot', 'desc')]))).toEqual([
      'c', 'b', 'a',
    ]);
  });

  it('(c) null in PRIMARY sorts last even though its secondary is non-null', () => {
    const items = [
      song({ id: 'hi', bpm: 130, camelot: '9A' }),
      song({ id: 'null', bpm: null, camelot: '1A' }),
      song({ id: 'lo', bpm: 100, camelot: '12A' }),
    ];
    expect(ids(sortItems(items, [sort('bpm', 'asc'), sort('camelot', 'asc')]))).toEqual([
      'lo', 'hi', 'null',
    ]);
    expect(ids(sortItems(items, [sort('bpm', 'desc'), sort('camelot', 'asc')]))).toEqual([
      'hi', 'lo', 'null',
    ]);
  });

  it('(d) primary fully orders (secondary never consulted) and stays stable', () => {
    const items = [
      song({ id: 'mid', bpm: 120, camelot: '8A' }),
      song({ id: 'lo', bpm: 90, camelot: '8A' }),
      song({ id: 'hi', bpm: 174, camelot: '8A' }),
    ];
    expect(ids(sortItems(items, [sort('bpm', 'asc'), sort('camelot', 'asc')]))).toEqual([
      'lo', 'mid', 'hi',
    ]);
  });

  it('(e) sortHash encodes the multi-key chain', () => {
    expect(sortHash([sort('bpm', 'asc'), sort('camelot', 'desc')])).toBe('bpm:asc,camelot:desc');
  });

  it('(f) empty array -> same-ref passthrough', () => {
    const items = [song({ id: 'b', bpm: 2 }), song({ id: 'a', bpm: 1 })];
    expect(sortItems(items, [])).toBe(items);
  });

  it('(g) unknown primary, valid secondary -> sorts by the valid key; all-unknown -> same ref', () => {
    const items = [
      album({ id: 'y2000', year: 2000 }),
      album({ id: 'y1990', year: 1990 }),
      album({ id: 'y2010', year: 2010 }),
    ];
    expect(ids(sortItems(items, [sort('bogus', 'asc'), sort('year', 'asc')]))).toEqual([
      'y1990', 'y2000', 'y2010',
    ]);
    expect(sortItems(items, [sort('bogus', 'asc')])).toBe(items);
  });

  it('(h) both items null on PRIMARY, secondary differs -> ordered by SECONDARY (fall-through)', () => {
    // input order is the REVERSE of camelot order, so a broken `continue` is observable.
    const items = [
      song({ id: 'c5', bpm: null, camelot: '5A' }),
      song({ id: 'c1', bpm: null, camelot: '1A' }),
    ];
    expect(ids(sortItems(items, [sort('bpm', 'asc'), sort('camelot', 'asc')]))).toEqual([
      'c1', 'c5',
    ]);
  });

  it('(i) camelot as SECONDARY over a numeric-tied primary -> harmonic (not lexical) order', () => {
    const items = [
      song({ id: 'c10', bpm: 120, camelot: '10A' }),
      song({ id: 'c2', bpm: 120, camelot: '2A' }),
    ];
    // lexical would put '10A' first; harmonic puts '2A' first.
    expect(ids(sortItems(items, [sort('bpm', 'asc'), sort('camelot', 'asc')]))).toEqual([
      'c2', 'c10',
    ]);
  });

  it('(j) all items equal on EVERY key -> output preserves input order (multi-key stability)', () => {
    const items = [
      song({ id: 'first', bpm: 120, camelot: '8A' }),
      song({ id: 'second', bpm: 120, camelot: '8A' }),
      song({ id: 'third', bpm: 120, camelot: '8A' }),
    ];
    expect(ids(sortItems(items, [sort('bpm', 'asc'), sort('camelot', 'asc')]))).toEqual([
      'first', 'second', 'third',
    ]);
  });
});
