import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { applyFilters, filterHash } from './filterEngine';
import type { AlbumItem, SongItem, MusicItem } from '../types/model';
import type { FilterClause, FilterState } from '../types/filter';

// ---- fixtures -------------------------------------------------------------
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
function clause(over: Partial<FilterClause> & Pick<FilterClause, 'field' | 'op'>): FilterClause {
  return { id: 'c1', ...over };
}
function state(...clauses: FilterClause[]): FilterState {
  return { clauses };
}
const ids = (items: MusicItem[]) => items.map((i) => i.id);

// Silence the PDJ_API transcript line emitted by applyFilters.
beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
});
afterEach(() => {
  vi.restoreAllMocks();
});

describe('applyFilters — empty / passthrough', () => {
  it('returns the original array (same reference) when no clauses', () => {
    const items = [album(), song()];
    const out = applyFilters(items, state());
    expect(out).toBe(items); // identity short-circuit, no copy
  });

  it('returns all items when a clause references an unknown field', () => {
    const items = [album({ artist: 'A' }), album({ artist: 'B' })];
    const out = applyFilters(items, state(clause({ field: 'nope', op: 'eq', value: 'A' })));
    expect(ids(out)).toEqual(ids(items));
  });

  it('passes items through when the clause field does not apply to the item type', () => {
    // `country` applies only to album; a song must pass through it untouched.
    const s = song({ id: 'keep' });
    const a = album({ id: 'drop', country: 'UK' });
    const out = applyFilters([s, a], state(clause({ field: 'country', op: 'eq', value: 'US' })));
    // song passes (field N/A), album excluded (country mismatch)
    expect(ids(out)).toEqual(['keep']);
  });
});

describe('applyFilters — incomplete clauses (no operand yet) pass through', () => {
  // Regression: a filter row added but never filled in must NOT exclude everything.
  it('eq with undefined value is a no-op (passes everything)', () => {
    const items = [album({ id: 'a', artist: 'X' }), album({ id: 'b', artist: 'Y' })];
    const out = applyFilters(items, state(clause({ field: 'artist', op: 'eq' })));
    expect(ids(out)).toEqual(['a', 'b']);
  });

  it('an empty added clause alongside a real one does not zero the real one', () => {
    const items = [album({ id: 'a', genre: 'soul' }), album({ id: 'b', genre: 'rock' })];
    const out = applyFilters(
      items,
      state(
        clause({ id: 'c1', field: 'genre', op: 'in', values: ['soul'] }),
        clause({ id: 'c2', field: 'artist', op: 'eq' }), // empty, never filled
      ),
    );
    expect(ids(out)).toEqual(['a']);
  });

  it('between with neither bound is a no-op', () => {
    const items = [album({ id: 'a', year: 1990 }), album({ id: 'b', year: 2000 })];
    const out = applyFilters(items, state(clause({ field: 'year', op: 'between' })));
    expect(ids(out)).toEqual(['a', 'b']);
  });

  it('explicit empty-string eq is NOT incomplete (still matches missing/empty)', () => {
    const items = [album({ id: 'a', country: undefined }), album({ id: 'b', country: 'US' })];
    const out = applyFilters(items, state(clause({ field: 'country', op: 'eq', value: '' })));
    expect(ids(out)).toEqual(['a']);
  });
});

describe('applyFilters — string fields (case/whitespace-insensitive)', () => {
  it('eq matches normalized (trim + lowercase)', () => {
    const items = [album({ id: 'a', artist: '  Daft Punk ' }), album({ id: 'b', artist: 'Other' })];
    const out = applyFilters(items, state(clause({ field: 'artist', op: 'eq', value: 'daft punk' })));
    expect(ids(out)).toEqual(['a']);
  });

  it('neq excludes the matching value', () => {
    const items = [album({ id: 'a', artist: 'X' }), album({ id: 'b', artist: 'Y' })];
    const out = applyFilters(items, state(clause({ field: 'artist', op: 'neq', value: 'x' })));
    expect(ids(out)).toEqual(['b']);
  });

  it('in matches any of the listed values (normalized)', () => {
    const items = [
      album({ id: 'a', genre: 'Rock' }),
      album({ id: 'b', genre: 'Jazz' }),
      album({ id: 'c', genre: 'Pop' }),
    ];
    const out = applyFilters(items, state(clause({ field: 'genre', op: 'in', values: ['rock', 'pop'] })));
    expect(ids(out)).toEqual(['a', 'c']);
  });

  it('in with no values is an incomplete clause -> passes everything through', () => {
    // A half-built `in` row (no values picked yet) must not zero the catalog.
    const items = [album({ id: 'a', genre: 'Rock' }), album({ id: 'b', genre: 'Jazz' })];
    const out = applyFilters(items, state(clause({ field: 'genre', op: 'in', values: [] })));
    expect(ids(out)).toEqual(['a', 'b']);
  });

  it('treats null/undefined string value as empty string for eq', () => {
    const items = [album({ id: 'a', country: undefined }), album({ id: 'b', country: 'US' })];
    const out = applyFilters(items, state(clause({ field: 'country', op: 'eq', value: '' })));
    expect(ids(out)).toEqual(['a']);
  });
});

describe('applyFilters — numeric fields', () => {
  const items = () => [
    album({ id: 'y1990', year: 1990 }),
    album({ id: 'y2000', year: 2000 }),
    album({ id: 'y2010', year: 2010 }),
    album({ id: 'yNull', year: undefined }),
  ];

  it('eq matches the exact number (and excludes null)', () => {
    const out = applyFilters(items(), state(clause({ field: 'year', op: 'eq', value: 2000 })));
    expect(ids(out)).toEqual(['y2000']);
  });

  it('eq coerces a string clause value to number', () => {
    const out = applyFilters(items(), state(clause({ field: 'year', op: 'eq', value: '2010' as unknown as number })));
    expect(ids(out)).toEqual(['y2010']);
  });

  it('neq keeps non-matches AND keeps null years', () => {
    const out = applyFilters(items(), state(clause({ field: 'year', op: 'neq', value: 2000 })));
    expect(ids(out)).toEqual(['y1990', 'y2010', 'yNull']);
  });

  it('in matches any listed number, excludes null', () => {
    const out = applyFilters(items(), state(clause({ field: 'year', op: 'in', values: [1990, 2010] })));
    expect(ids(out)).toEqual(['y1990', 'y2010']);
  });

  it('between is inclusive of both bounds, excludes null', () => {
    const out = applyFilters(items(), state(clause({ field: 'year', op: 'between', min: 2000, max: 2010 })));
    expect(ids(out)).toEqual(['y2000', 'y2010']);
  });

  it('between with only min (max defaults to +Infinity)', () => {
    const out = applyFilters(items(), state(clause({ field: 'year', op: 'between', min: 2000 })));
    expect(ids(out)).toEqual(['y2000', 'y2010']);
  });

  it('between with only max (min defaults to -Infinity)', () => {
    const out = applyFilters(items(), state(clause({ field: 'year', op: 'between', max: 1990 })));
    expect(ids(out)).toEqual(['y1990']);
  });

  it('trackCount is derived from trackIds.length and is numeric-filterable', () => {
    const items2 = [
      album({ id: 'two', trackIds: ['t1', 't2'] }),
      album({ id: 'zero', trackIds: [] }),
    ];
    const out = applyFilters(items2, state(clause({ field: 'trackCount', op: 'eq', value: 2 })));
    expect(ids(out)).toEqual(['two']);
  });
});

describe('applyFilters — boolean field (explicit)', () => {
  it('eq true matches explicit songs', () => {
    const items = [song({ id: 'e', explicit: true }), song({ id: 'c', explicit: false })];
    const out = applyFilters(items, state(clause({ field: 'explicit', op: 'eq', value: true })));
    expect(ids(out)).toEqual(['e']);
  });

  it('eq false matches clean songs', () => {
    const items = [song({ id: 'e', explicit: true }), song({ id: 'c', explicit: false })];
    const out = applyFilters(items, state(clause({ field: 'explicit', op: 'eq', value: false })));
    expect(ids(out)).toEqual(['c']);
  });

  it('non-eq op on boolean passes everything through', () => {
    const items = [song({ id: 'e', explicit: true }), song({ id: 'c', explicit: false })];
    const out = applyFilters(items, state(clause({ field: 'explicit', op: 'neq', value: true })));
    expect(ids(out)).toEqual(['e', 'c']);
  });
});

describe('applyFilters — string[] field (sentimentKeywords)', () => {
  const items = () => [
    song({ id: 's1', sentimentKeywords: ['Love', 'Joy'] }),
    song({ id: 's2', sentimentKeywords: ['anger'] }),
    song({ id: 's3', sentimentKeywords: [] }),
  ];

  it('eq = "contains" (normalized membership)', () => {
    const out = applyFilters(items(), state(clause({ field: 'sentimentKeywords', op: 'eq', value: 'love' })));
    expect(ids(out)).toEqual(['s1']);
  });

  it('neq = "does not contain"', () => {
    const out = applyFilters(items(), state(clause({ field: 'sentimentKeywords', op: 'neq', value: 'love' })));
    expect(ids(out)).toEqual(['s2', 's3']);
  });

  it('in = intersection (any listed value present)', () => {
    const out = applyFilters(items(), state(clause({ field: 'sentimentKeywords', op: 'in', values: ['anger', 'joy'] })));
    expect(ids(out)).toEqual(['s1', 's2']);
  });

  it('in with EMPTY values list matches everything (special-cased)', () => {
    const out = applyFilters(items(), state(clause({ field: 'sentimentKeywords', op: 'in', values: [] })));
    expect(ids(out)).toEqual(['s1', 's2', 's3']);
  });

  it('between is unsupported on string[] -> passes everything through', () => {
    const out = applyFilters(items(), state(clause({ field: 'sentimentKeywords', op: 'between', min: 0, max: 1 })));
    expect(ids(out)).toEqual(['s1', 's2', 's3']);
  });
});

describe('applyFilters — AND composition', () => {
  it('all clauses must pass', () => {
    const items = [
      album({ id: 'a', artist: 'X', year: 2000, genre: 'rock' }),
      album({ id: 'b', artist: 'X', year: 1990, genre: 'rock' }),
      album({ id: 'c', artist: 'Y', year: 2000, genre: 'rock' }),
    ];
    const out = applyFilters(
      items,
      state(
        clause({ field: 'artist', op: 'eq', value: 'X' }),
        clause({ field: 'year', op: 'eq', value: 2000 }),
      ),
    );
    expect(ids(out)).toEqual(['a']);
  });

  it('mixed album/song set: a song-only clause leaves albums in (field N/A) but filters songs', () => {
    const a = album({ id: 'alb', year: 2000 });
    const s1 = song({ id: 'loud', explicit: true });
    const s2 = song({ id: 'soft', explicit: false });
    const out = applyFilters([a, s1, s2], state(clause({ field: 'explicit', op: 'eq', value: true })));
    expect(ids(out)).toEqual(['alb', 'loud']);
  });
});

describe('applyFilters — transcript', () => {
  it('emits a PDJ_API filter.apply line with in/out counts and clause summary', () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    const items = [album({ id: 'a', year: 2000 }), album({ id: 'b', year: 1990 })];
    applyFilters(items, state(clause({ field: 'year', op: 'eq', value: 2000 })));
    expect(log).toHaveBeenCalledTimes(1);
    const line = log.mock.calls[0][0] as string;
    expect(line.startsWith('PDJ_API ')).toBe(true);
    const payload = JSON.parse(line.slice('PDJ_API '.length));
    expect(payload.op).toBe('filter.apply');
    expect(payload.in).toBe(2);
    expect(payload.out).toBe(1);
    expect(payload.clauses).toEqual([{ field: 'year', op: 'eq' }]);
  });

  it('does NOT emit a transcript line when there are no clauses', () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    applyFilters([album()], state());
    expect(log).not.toHaveBeenCalled();
  });
});

describe('filterHash', () => {
  it('is the JSON of clauses (stable for equal states)', () => {
    const c = clause({ field: 'year', op: 'eq', value: 2000 });
    expect(filterHash(state(c))).toBe(filterHash(state(c)));
  });

  it('differs when clauses differ', () => {
    const h1 = filterHash(state(clause({ field: 'year', op: 'eq', value: 2000 })));
    const h2 = filterHash(state(clause({ field: 'year', op: 'eq', value: 2001 })));
    expect(h1).not.toBe(h2);
  });

  it('empty state hashes to "[]"', () => {
    expect(filterHash(state())).toBe('[]');
  });
});
