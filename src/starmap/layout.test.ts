import { describe, it, expect } from 'vitest';
import { computeLayout } from './layout';
import { categorize } from './constellationMap';
import type { AlbumItem } from '../types/model';

function album(over: Partial<AlbumItem> & { id: string }): AlbumItem {
  return {
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

const sampleAlbums = (): AlbumItem[] => [
  album({ id: 'rock-new', genre: 'rock', year: 2000 }),
  album({ id: 'rock-old', genre: 'rock', year: 1990 }),
  album({ id: 'jazz1', genre: 'jazz', year: 2010 }),
  album({ id: 'ungenred', genre: '', year: 1980 }),
];

describe('computeLayout — tier 1 (categories)', () => {
  it('constellations are categories present in the album set; tier === 1', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 1 });
    expect(layout.tier).toBe(1);
    // rock + jazz + the empty-genre album bucketed into Other
    expect(new Set(layout.constellations.map((c) => c.genre))).toEqual(
      new Set(['rock', 'jazz', 'Other']),
    );
    expect(layout.constellations.every((c) => c.tier === 1)).toBe(true);
  });

  it('one constellation per distinct category (count === distinct categories)', () => {
    const albums = sampleAlbums();
    const distinct = new Set(albums.map((a) => categorize(a.genre).category));
    const layout = computeLayout(albums, { tier: 1 });
    expect(layout.constellations.length).toBe(distinct.size);
  });

  it('tier-1 stars are NOT clickable (constellation is the click target)', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 1 });
    expect(layout.stars.every((s) => s.clickable === false)).toBe(true);
  });

  it('tier-1 constellations carry a category and no subgenre', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 1 });
    for (const c of layout.constellations) {
      expect(typeof c.category).toBe('string');
      expect(c.subgenre).toBeUndefined();
    }
  });

  it('defaults to tier 1 when no opts are given', () => {
    expect(computeLayout(sampleAlbums()).tier).toBe(1);
  });

  it('focusCategory is undefined on tier 1', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 1 });
    expect(layout.focusCategory).toBeUndefined();
  });
});

describe('computeLayout — every star carries category + subgenre matching categorize()', () => {
  it('each star.category/subgenre equals categorize(album.genre)', () => {
    const albums = sampleAlbums();
    const byId = new Map(albums.map((a) => [a.id, a]));
    const layout = computeLayout(albums, { tier: 1 });
    for (const s of layout.stars) {
      const a = byId.get(s.albumId)!;
      const { category, subgenre } = categorize(a.genre);
      expect(s.category).toBe(category);
      expect(s.subgenre).toBe(subgenre);
    }
  });

  it('lays out exactly one star per album', () => {
    const albums = sampleAlbums();
    const layout = computeLayout(albums, { tier: 1 });
    expect(layout.stars.map((s) => s.albumId).sort()).toEqual(albums.map((a) => a.id).sort());
  });

  it('stars copy through convenience fields (artist/name/year/coverArtKey)', () => {
    const a = album({ id: 'x', genre: 'rock', year: 1999, artist: 'Q', name: 'T', coverArtKey: 'k1' });
    const layout = computeLayout([a], { tier: 1 });
    const s = layout.stars[0];
    expect(s.artist).toBe('Q');
    expect(s.name).toBe('T');
    expect(s.year).toBe(1999);
    expect(s.coverArtKey).toBe('k1');
  });
});

describe('computeLayout — year maps to vertical (newer = higher / smaller y)', () => {
  it('within a constellation, a newer album has a SMALLER y than an older one', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 1 });
    const byId = new Map(layout.stars.map((s) => [s.albumId, s]));
    expect(byId.get('rock-new')!.y).toBeLessThan(byId.get('rock-old')!.y);
  });

  it('layout records the global year range', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 1 });
    expect(layout.minYear).toBe(1980);
    expect(layout.maxYear).toBe(2010);
  });

  it('all-unknown years collapse the range to 0..0 without throwing', () => {
    const albums = [album({ id: 'a', genre: 'rock' }), album({ id: 'b', genre: 'jazz' })];
    const layout = computeLayout(albums, { tier: 1 });
    expect(layout.minYear).toBe(0);
    expect(layout.maxYear).toBe(0);
    expect(layout.stars.length).toBe(2);
  });
});

describe('computeLayout — determinism', () => {
  it('same albums => identical stars, constellations and hash', () => {
    const a = computeLayout(sampleAlbums(), { tier: 1 });
    const b = computeLayout(sampleAlbums(), { tier: 1 });
    expect(a.albumSetHash).toBe(b.albumSetHash);
    expect(a.stars).toEqual(b.stars);
    expect(a.constellations).toEqual(b.constellations);
    expect(a.width).toBe(b.width);
    expect(a.height).toBe(b.height);
  });

  it('album input ORDER does not change the hash (ids are sorted before hashing)', () => {
    const albums = sampleAlbums();
    const reversed = [...albums].reverse();
    expect(computeLayout(albums, { tier: 1 }).albumSetHash).toBe(
      computeLayout(reversed, { tier: 1 }).albumSetHash,
    );
  });

  it('different album sets => different hashes', () => {
    const a = computeLayout(sampleAlbums(), { tier: 1 }).albumSetHash;
    const b = computeLayout([...sampleAlbums(), album({ id: 'extra', genre: 'pop', year: 2020 })], {
      tier: 1,
    }).albumSetHash;
    expect(a).not.toBe(b);
  });
});

describe('computeLayout — tier 2 (subgenres)', () => {
  it('tier-2 constellations are subgenres; tier === 2; stars clickable', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 2 });
    expect(layout.tier).toBe(2);
    expect(layout.constellations.every((c) => c.tier === 2)).toBe(true);
    expect(layout.constellations.every((c) => c.subgenre !== undefined)).toBe(true);
    expect(layout.stars.every((s) => s.clickable === true)).toBe(true);
  });

  it('global tier 2: one constellation per (category, subgenre) pair present', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 2 });
    // rock/Classic Pop Rock, jazz/Classic Jazz, Other/Unknown
    expect(new Set(layout.constellations.map((c) => c.genre))).toEqual(
      new Set(['Classic / Pop Rock', 'Classic Jazz', 'Unknown']),
    );
  });

  it('focused tier 2: only the focused category is laid out', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 2, focusCategory: 'rock' });
    expect(layout.focusCategory).toBe('rock');
    expect(layout.stars.map((s) => s.albumId).sort()).toEqual(['rock-new', 'rock-old']);
    expect(layout.constellations.every((c) => c.category === 'rock')).toBe(true);
  });

  it('focused tier-2 hash reflects only the filtered album subset', () => {
    const full = computeLayout(sampleAlbums(), { tier: 2 }).albumSetHash;
    const focused = computeLayout(sampleAlbums(), { tier: 2, focusCategory: 'rock' }).albumSetHash;
    expect(focused).not.toBe(full);
  });

  it('focusCategory is ignored on tier 1', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 1, focusCategory: 'rock' } as never);
    expect(layout.focusCategory).toBeUndefined();
    // all albums still laid out (not filtered)
    expect(layout.stars.length).toBe(4);
  });
});

describe('computeLayout — scene geometry sanity', () => {
  it('width/height are positive finite numbers', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 1 });
    expect(Number.isFinite(layout.width)).toBe(true);
    expect(Number.isFinite(layout.height)).toBe(true);
    expect(layout.width).toBeGreaterThan(0);
    expect(layout.height).toBeGreaterThan(0);
  });

  it('empty album list yields an empty but valid layout', () => {
    const layout = computeLayout([], { tier: 1 });
    expect(layout.stars).toEqual([]);
    expect(layout.constellations).toEqual([]);
    expect(layout.minYear).toBe(0);
    expect(layout.maxYear).toBe(0);
    expect(Number.isFinite(layout.width)).toBe(true);
    expect(Number.isFinite(layout.height)).toBe(true);
  });

  it('constellation starIds are ordered chronologically (by year) within a box', () => {
    const layout = computeLayout(sampleAlbums(), { tier: 1 });
    const rock = layout.constellations.find((c) => c.genre === 'rock')!;
    // rock-old (1990) before rock-new (2000) in the polyline order
    expect(rock.starIds).toEqual(['rock-old', 'rock-new']);
  });
});
