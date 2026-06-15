// Single source of truth for filterable/sortable fields. Drives the FilterBuilder
// (which fields, which operators, numeric => "between") and the sort control.
import type { FieldDef, FilterOp } from '../types/filter';
import type { MusicItem, AlbumItem, SongItem } from '../types/model';
import { categorize, CATEGORY_NAMES } from '../starmap/constellationMap';
import { MUSICAL_KEYS, CAMELOT_KEYS } from '../lib/camelot';

const STR_OPS: FilterOp[] = ['eq', 'neq', 'in'];
const NUM_OPS: FilterOp[] = ['eq', 'neq', 'in', 'between'];
const TAG_OPS: FilterOp[] = ['in', 'eq', 'neq']; // string[]: in = intersection, eq = contains
const BOOL_OPS: FilterOp[] = ['eq'];

interface FieldDefWithGet extends FieldDef {
  get: (item: MusicItem) => unknown;
}

const album = (fn: (a: AlbumItem) => unknown) => (i: MusicItem) => (i.type === 'album' ? fn(i) : undefined);
const song = (fn: (s: SongItem) => unknown) => (i: MusicItem) => (i.type === 'song' ? fn(i) : undefined);

export const FIELDS: FieldDefWithGet[] = [
  // shared-ish (each item type has its own accessor)
  { id: 'artist', label: 'Artist', appliesTo: ['album', 'song'], kind: 'string', numeric: false, ops: STR_OPS, sortable: true,
    get: (i) => (i as AlbumItem | SongItem).artist },
  { id: 'name', label: 'Title', appliesTo: ['album', 'song'], kind: 'string', numeric: false, ops: STR_OPS, sortable: true,
    get: (i) => (i as AlbumItem | SongItem).name },
  { id: 'year', label: 'Year', appliesTo: ['album', 'song'], kind: 'number', numeric: true, ops: NUM_OPS, sortable: true,
    get: (i) => (i as AlbumItem | SongItem).year },
  { id: 'fileType', label: 'File type', appliesTo: ['album', 'song'], kind: 'string', numeric: false, ops: STR_OPS, sortable: true,
    get: (i) => (i as AlbumItem | SongItem).fileType },

  // Genre: filters on the TOP-LEVEL category for BOTH albums and songs (same as the star
  // map), so e.g. "genre = soul" returns the same album set the soul constellation shows.
  // Albums map their raw genre string through categorize() here (display/edit keep the raw
  // genre); songs already carry the derived category.
  { id: 'genre', label: 'Genre', appliesTo: ['album', 'song'], kind: 'string', numeric: false, ops: STR_OPS, sortable: true,
    options: CATEGORY_NAMES,
    get: (i) => (i.type === 'album' ? categorize((i as AlbumItem).genre).category : (i as SongItem).genre) },

  // album-only
  { id: 'country', label: 'Country', appliesTo: ['album'], kind: 'string', numeric: false, ops: STR_OPS, sortable: true,
    get: album((a) => a.country) },
  { id: 'trackCount', label: 'Track count', appliesTo: ['album'], kind: 'number', numeric: true, ops: NUM_OPS, sortable: true,
    get: album((a) => a.trackIds.length) },

  // song-only
  { id: 'trackNumber', label: 'Track #', appliesTo: ['song'], kind: 'number', numeric: true, ops: NUM_OPS, sortable: true,
    get: song((s) => s.trackNumber) },
  { id: 'lengthMs', label: 'Length', appliesTo: ['song'], kind: 'number', numeric: true, ops: NUM_OPS, sortable: true,
    get: song((s) => s.lengthMs) },
  { id: 'explicit', label: 'Explicit', appliesTo: ['song'], kind: 'boolean', numeric: false, ops: BOOL_OPS, sortable: true,
    get: song((s) => s.explicit) },
  { id: 'sentimentKeywords', label: 'Sentiment', appliesTo: ['song'], kind: 'string[]', numeric: false, ops: TAG_OPS, sortable: false,
    get: song((s) => s.sentimentKeywords) },
  { id: 'bpm', label: 'BPM', appliesTo: ['song'], kind: 'number', numeric: true, ops: NUM_OPS, sortable: true,
    get: song((s) => s.bpm) },
  { id: 'key', label: 'Key', appliesTo: ['song'], kind: 'string', numeric: false, ops: STR_OPS, sortable: true,
    options: MUSICAL_KEYS,
    get: song((s) => s.key) },
  // Camelot sorts in harmonic-wheel order (see sortEngine), NOT alphabetically.
  { id: 'camelot', label: 'Key (Camelot)', appliesTo: ['song'], kind: 'string', numeric: false, ops: STR_OPS, sortable: true,
    options: CAMELOT_KEYS,
    get: song((s) => s.camelot) },
];

const BY_ID = new Map(FIELDS.map((f) => [f.id, f]));

export function getField(id: string): FieldDefWithGet | undefined {
  return BY_ID.get(id);
}

/** Fields available for a given item type (drives the FilterBuilder + SortControl). */
export function fieldsFor(type: 'album' | 'song'): FieldDefWithGet[] {
  return FIELDS.filter((f) => f.appliesTo.includes(type));
}
