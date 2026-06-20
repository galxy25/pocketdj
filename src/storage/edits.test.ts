// The edits overlay + doc parsing/merge — pure logic, no IndexedDB needed.
import { describe, it, expect } from 'vitest';
import { applyEditToItem, parseEditsDocument, emptyEditsDocument, type EditsDocument } from './edits';
import type { AlbumItem, SongItem } from '../types/model';

const song = (over: Partial<SongItem> = {}): SongItem => ({
  id: 'sng_a',
  sourceId: 's1',
  type: 'song',
  artist: 'Orig Artist',
  name: 'Orig Name',
  sentimentKeywords: [],
  explicit: false,
  bpm: null,
  key: null,
  createdAt: 1,
  updatedAt: 1,
  ...over,
});

const album = (over: Partial<AlbumItem> = {}): AlbumItem => ({
  id: 'alb_a',
  sourceId: 's1',
  type: 'album',
  artist: 'Orig Band',
  name: 'Orig Album',
  trackIds: [],
  year: 1990,
  createdAt: 1,
  updatedAt: 1,
  ...over,
});

describe('parseEditsDocument', () => {
  it('lenient: missing version → 0, missing maps → empty, malformed → empty doc', () => {
    expect(parseEditsDocument('not json')).toEqual(emptyEditsDocument());
    expect(parseEditsDocument(null)).toEqual(emptyEditsDocument());
    expect(parseEditsDocument({ albums: { a: { name: 'x' } } })).toMatchObject({ schemaVersion: 0, albums: { a: { name: 'x' } }, songs: {} });
  });

  it('parses a native-shaped EditsDocument string', () => {
    const raw = JSON.stringify({ schemaVersion: 2, albums: { alb_a: { name: 'New' } }, songs: { sng_a: { bpm: 120 } }, meta: { platform: 'iOS' } });
    const doc = parseEditsDocument(raw);
    expect(doc.schemaVersion).toBe(2);
    expect(doc.albums['alb_a']).toEqual({ name: 'New' });
    expect(doc.songs['sng_a']).toEqual({ bpm: 120 });
    expect(doc.meta?.platform).toBe('iOS');
  });
});

describe('applyEditToItem', () => {
  const doc: EditsDocument = {
    schemaVersion: 2,
    albums: { alb_a: { name: 'Fixed Album', year: 1971 } },
    songs: { sng_a: { name: 'Fixed Song', bpm: 128, explicit: true } },
  };

  it('overlays only the set song fields, keeps the rest, never mutates input', () => {
    const s = song();
    const out = applyEditToItem(s, doc) as SongItem;
    expect(out.name).toBe('Fixed Song');
    expect(out.bpm).toBe(128);
    expect(out.explicit).toBe(true);
    expect(out.artist).toBe('Orig Artist'); // untouched
    expect(s.name).toBe('Orig Name'); // input not mutated
  });

  it('overlays album fields and drops the audioTracks override at display', () => {
    const a = album();
    const out = applyEditToItem(a, { ...doc, albums: { alb_a: { name: 'X', audioTracks: [{ trackNumber: 1, bpm: 99 }] } } }) as AlbumItem;
    expect(out.name).toBe('X');
    expect('audioTracks' in out ? out.audioTracks : undefined).toBeUndefined();
  });

  it('passes an unedited item through by identity (no-op)', () => {
    const s = song({ id: 'sng_other' });
    expect(applyEditToItem(s, doc)).toBe(s);
  });
});
