import { describe, it, expect } from 'vitest';
import { FIELDS, getField, fieldsFor } from './fieldRegistry';
import type { AlbumItem, SongItem } from '../types/model';

function album(over: Partial<AlbumItem> = {}): AlbumItem {
  return {
    id: 'alb_1',
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
  return {
    id: 'sng_1',
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

describe('getField', () => {
  it('returns the matching field def', () => {
    expect(getField('year')?.id).toBe('year');
  });
  it('returns undefined for an unknown field', () => {
    expect(getField('does-not-exist')).toBeUndefined();
  });
});

describe('FIELDS — invariants', () => {
  it('every field id is unique', () => {
    const ids = FIELDS.map((f) => f.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it('numeric fields offer between; non-numeric fields never do', () => {
    for (const f of FIELDS) {
      if (f.numeric) expect(f.ops).toContain('between');
      else expect(f.ops).not.toContain('between');
    }
  });

  it('numeric flag agrees with kind === "number"', () => {
    for (const f of FIELDS) {
      expect(f.numeric).toBe(f.kind === 'number');
    }
  });

  it('boolean field offers only eq', () => {
    const explicit = getField('explicit')!;
    expect(explicit.kind).toBe('boolean');
    expect(explicit.ops).toEqual(['eq']);
  });

  it('string[] (sentiment) supports in/eq/neq and is not sortable', () => {
    const f = getField('sentimentKeywords')!;
    expect(f.kind).toBe('string[]');
    expect(f.ops).toEqual(['in', 'eq', 'neq']);
    expect(f.sortable).toBe(false);
  });

  it('every field applies to at least one item type', () => {
    for (const f of FIELDS) {
      expect(f.appliesTo.length).toBeGreaterThan(0);
      for (const t of f.appliesTo) expect(['album', 'song']).toContain(t);
    }
  });

  it('every field has a non-empty label and ops list', () => {
    for (const f of FIELDS) {
      expect(f.label.length).toBeGreaterThan(0);
      expect(f.ops.length).toBeGreaterThan(0);
    }
  });
});

describe('fieldsFor', () => {
  it('album fields exclude song-only fields', () => {
    const albumIds = fieldsFor('album').map((f) => f.id);
    expect(albumIds).toContain('genre');
    expect(albumIds).toContain('trackCount');
    expect(albumIds).not.toContain('explicit');
    expect(albumIds).not.toContain('sentimentKeywords');
    expect(albumIds).not.toContain('lengthMs');
  });

  it('song fields exclude album-only fields', () => {
    const songIds = fieldsFor('song').map((f) => f.id);
    expect(songIds).toContain('explicit');
    expect(songIds).toContain('lengthMs');
    expect(songIds).toContain('sentimentKeywords');
    // genre now applies to songs too (the album's top-level category — for "soul songs…")
    expect(songIds).toContain('genre');
    expect(songIds).not.toContain('country');
    expect(songIds).not.toContain('trackCount');
  });

  it('audio sort fields (bpm/key/camelot) are song-only, sortable', () => {
    const songIds = fieldsFor('song').map((f) => f.id);
    for (const id of ['bpm', 'key', 'camelot']) {
      expect(songIds).toContain(id);
      expect(getField(id)!.sortable).toBe(true);
    }
    const albumIds = fieldsFor('album').map((f) => f.id);
    for (const id of ['bpm', 'key', 'camelot']) {
      expect(albumIds).not.toContain(id);
    }
    // bpm is the only between-filterable audio field; camelot/key are plain strings.
    expect(getField('bpm')!.numeric).toBe(true);
    expect(getField('camelot')!.numeric).toBe(false);
    expect(getField('key')!.numeric).toBe(false);
  });

  it('shared fields (artist/name/year/fileType) appear for both types', () => {
    const a = new Set(fieldsFor('album').map((f) => f.id));
    const s = new Set(fieldsFor('song').map((f) => f.id));
    for (const shared of ['artist', 'name', 'year', 'fileType']) {
      expect(a.has(shared)).toBe(true);
      expect(s.has(shared)).toBe(true);
    }
  });
});

describe('field accessors (get)', () => {
  it('shared accessors read the value off either type', () => {
    expect(getField('artist')!.get(album({ artist: 'A' }))).toBe('A');
    expect(getField('artist')!.get(song({ artist: 'B' }))).toBe('B');
    expect(getField('year')!.get(album({ year: 1999 }))).toBe(1999);
  });

  it('trackCount accessor derives length from trackIds', () => {
    expect(getField('trackCount')!.get(album({ trackIds: ['a', 'b', 'c'] }))).toBe(3);
    expect(getField('trackCount')!.get(album({ trackIds: [] }))).toBe(0);
  });

  it('album-only accessor returns undefined for a song', () => {
    expect(getField('genre')!.get(song())).toBeUndefined();
    expect(getField('trackCount')!.get(song())).toBeUndefined();
  });

  it('song-only accessor returns undefined for an album', () => {
    expect(getField('explicit')!.get(album())).toBeUndefined();
    expect(getField('sentimentKeywords')!.get(album())).toBeUndefined();
    expect(getField('lengthMs')!.get(album())).toBeUndefined();
  });

  it('song accessors read song values', () => {
    expect(getField('explicit')!.get(song({ explicit: true }))).toBe(true);
    expect(getField('lengthMs')!.get(song({ lengthMs: 1234 }))).toBe(1234);
    expect(getField('sentimentKeywords')!.get(song({ sentimentKeywords: ['joy'] }))).toEqual(['joy']);
    expect(getField('trackNumber')!.get(song({ trackNumber: 7 }))).toBe(7);
  });
});
