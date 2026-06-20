// User metadata edits — the PWA side of the cross-client `EditsDocument` contract.
//
// The native apps (iPhone / iPad / Mac) keep an on-device store of user metadata
// overrides — "rename this album", "fix this song's year", "set this BPM" — as a
// versioned, device-portable `EditsDocument` (see apple EditSchema.swift). Those
// edits travel inside the full-backup zip (`edits.json`) and are folded back into
// the read-only index by an offline merge tool. The PWA historically had no such
// store, so a native→PWA backup silently dropped every edit. This module closes
// that gap: it mirrors the native shape EXACTLY so a doc round-trips byte-for-byte
// in meaning, persists it in the `meta` store, and overlays it onto catalog items
// at read time (non-destructively — the underlying index item is never mutated).
//
// Design rules (kept in lockstep with EditSchema.swift):
//   1. EVERY override field is OPTIONAL — absent ⇒ "no override", keep the index
//      value. This is what makes a doc written by a newer client still apply here:
//      unknown keys are ignored, present-but-unknown shapes degrade to "no-op".
//   2. VERSIONED via `schemaVersion`; an older doc is migrated forward on merge.
//   3. ADDITIVE-ONLY — never remove/repurpose a field; add a new optional one.
//   4. Keyed by stable content-derived ids (`alb_…` / `sng_…`) so an edit applies
//      to the SAME item on every device.
import type { MusicItem } from '../types/model';
import { isAlbum } from '../types/model';
import { getMeta, setMeta } from './repo';
import { txn } from '../lib/log';

/** Current edits schema version — keep in sync with native `editsSchemaVersion`. */
export const EDITS_SCHEMA_VERSION = 2;

/** Where the edits doc lives in the `meta` store. */
export const EDITS_META_KEY = 'edits';

/** Per-segment audio-analysis override (mirrors native AudioTrackEdit / our AudioTrack). */
export interface AudioTrackEdit {
  trackNumber?: number;
  startMs?: number;
  endMs?: number;
  bpm?: number;
  key?: string;
  camelot?: string;
  keyStrength?: number;
}

/** Overridable album fields (mirrors native AlbumEdit). All optional. */
export interface AlbumEdit {
  name?: string;
  artist?: string;
  genre?: string;
  year?: number;
  country?: string;
  audioTracks?: AudioTrackEdit[];
}

/** Overridable song fields (mirrors native SongEdit). All optional. */
export interface SongEdit {
  name?: string;
  artist?: string;
  year?: number;
  trackNumber?: number;
  bpm?: number;
  key?: string;
  camelot?: string;
  explicit?: boolean;
  sentimentKeywords?: string[];
}

/** The portable envelope — byte-compatible with the native `EditsDocument`. */
export interface EditsDocument {
  schemaVersion: number;
  albums: Record<string, AlbumEdit>;
  songs: Record<string, SongEdit>;
  meta?: { exportedAt?: string; appVersion?: string; platform?: string };
}

export function emptyEditsDocument(): EditsDocument {
  return { schemaVersion: EDITS_SCHEMA_VERSION, albums: {}, songs: {} };
}

/**
 * Lenient parse of a raw `edits.json` payload (or an in-memory object). A missing
 * version ⇒ 0 (then stamped current on merge); missing maps ⇒ empty; a malformed
 * blob ⇒ an empty doc. Never throws on structurally-odd input — degrade, don't fail.
 */
export function parseEditsDocument(input: unknown): EditsDocument {
  let obj: unknown = input;
  if (typeof input === 'string') {
    try {
      obj = JSON.parse(input);
    } catch {
      return emptyEditsDocument();
    }
  }
  if (!obj || typeof obj !== 'object') return emptyEditsDocument();
  const o = obj as Record<string, unknown>;
  const albums = (o.albums && typeof o.albums === 'object' ? o.albums : {}) as Record<string, AlbumEdit>;
  const songs = (o.songs && typeof o.songs === 'object' ? o.songs : {}) as Record<string, SongEdit>;
  const schemaVersion = typeof o.schemaVersion === 'number' ? o.schemaVersion : 0;
  const meta = o.meta && typeof o.meta === 'object' ? (o.meta as EditsDocument['meta']) : undefined;
  return { schemaVersion, albums, songs, meta };
}

/** Read the persisted edits doc (empty if none stored yet). */
export async function getEditsDocument(): Promise<EditsDocument> {
  const stored = await getMeta<EditsDocument>(EDITS_META_KEY);
  return stored ? parseEditsDocument(stored) : emptyEditsDocument();
}

/** Persist a doc verbatim (stamped to the current schema version). */
export async function putEditsDocument(doc: EditsDocument): Promise<void> {
  const out: EditsDocument = { ...doc, schemaVersion: EDITS_SCHEMA_VERSION };
  await setMeta(EDITS_META_KEY, out);
  txn('edits.put', { albums: Object.keys(out.albums).length, songs: Object.keys(out.songs).length });
}

/**
 * Merge an incoming edits doc into the persisted one (imported value WINS per id —
 * same semantics as the native EditsStore.importData). Returns the merged doc.
 */
export async function mergeEditsDocument(incoming: EditsDocument): Promise<EditsDocument> {
  const inc = parseEditsDocument(incoming);
  const current = await getEditsDocument();
  const merged: EditsDocument = {
    schemaVersion: EDITS_SCHEMA_VERSION,
    albums: { ...current.albums, ...inc.albums },
    songs: { ...current.songs, ...inc.songs },
    meta: inc.meta ?? current.meta,
  };
  await putEditsDocument(merged);
  txn('edits.merge', {
    albumsIn: Object.keys(inc.albums).length,
    songsIn: Object.keys(inc.songs).length,
    albums: Object.keys(merged.albums).length,
    songs: Object.keys(merged.songs).length,
  });
  return merged;
}

/** Serialize the persisted doc for export as an `edits.json` entry (fresh meta). */
export async function buildEditsJson(platform = 'web'): Promise<string> {
  const doc = await getEditsDocument();
  const out: EditsDocument = {
    ...doc,
    schemaVersion: EDITS_SCHEMA_VERSION,
    meta: { exportedAt: new Date().toISOString(), platform },
  };
  return JSON.stringify(out);
}

// ---------------------------------------------------------------------------
// Overlay — apply an edit onto a catalog item (non-destructive)
// ---------------------------------------------------------------------------

/** Pick only the override fields that are actually set (not undefined/null). */
function defined<T extends object>(e: T): Partial<T> {
  const out: Partial<T> = {};
  for (const k of Object.keys(e) as (keyof T)[]) {
    if (e[k] !== undefined && e[k] !== null) out[k] = e[k];
  }
  return out;
}

/**
 * Return a copy of `item` with its matching album/song edit applied. Unset edit
 * fields keep the original value. The input item is never mutated. Items with no
 * edit pass through unchanged (referential identity preserved).
 */
export function applyEditToItem(item: MusicItem, doc: EditsDocument): MusicItem {
  if (isAlbum(item)) {
    const e = doc.albums[item.id];
    if (!e) return item;
    const o = defined(e);
    // audioTracks isn't applied here (the PWA's album audioTracks live on the item
    // and aren't reshaped at read time); the override travels for the merge tool.
    const { audioTracks, ...fields } = o;
    void audioTracks;
    return { ...item, ...fields };
  }
  const e = doc.songs[item.id];
  if (!e) return item;
  return { ...item, ...defined(e) };
}

/** Overlay a whole list of items with the given doc (or the persisted one). */
export async function applyEditsToItems(items: MusicItem[], doc?: EditsDocument): Promise<MusicItem[]> {
  const d = doc ?? (await getEditsDocument());
  if (Object.keys(d.albums).length === 0 && Object.keys(d.songs).length === 0) return items;
  return items.map((it) => applyEditToItem(it, d));
}
