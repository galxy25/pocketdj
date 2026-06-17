// Best-effort TEMPLATE rollups (song count + runtime) for a playlist sequence,
// computed from a partial catalog map the view has already resolved. This is the
// PRE-realize estimate shown in the editor; the exact totals come from realize()
// at Play time. Songs use lengthMs (fallback DEFAULT_TRACK_MS); albums expand via
// trackIds; pockets via their direct songIds/albumIds (nested pockets included).
import type { MusicItem, AlbumItem } from '../types/model';
import { isAlbum, isSong } from '../types/model';
import type { Pocket, PlaylistNode, SequenceNode } from '../types/collections';
import { isSongNode, isAlbumNode, isPocketNode, isSequenceNode, isTextNode } from '../types/collections';
import { DEFAULT_TRACK_MS } from './realize';

export interface SeqStats {
  /** Number of songs the sequence will contribute (text cues excluded). */
  songs: number;
  /** Estimated runtime in ms. */
  ms: number;
}

function albumMs(a: AlbumItem, itemsById: Map<string, MusicItem>): { songs: number; ms: number } {
  let songs = 0;
  let ms = 0;
  for (const tid of a.trackIds) {
    songs++;
    const t = itemsById.get(tid);
    ms += t && isSong(t) && t.lengthMs ? t.lengthMs : DEFAULT_TRACK_MS;
  }
  // Prefer the analyzed album duration when no per-track lengths were resolved.
  if (ms === a.trackIds.length * DEFAULT_TRACK_MS && a.audioDurationSec) ms = a.audioDurationSec * 1000;
  return { songs, ms };
}

function pocketStats(
  pocketId: string,
  pocketsById: Map<string, Pocket>,
  itemsById: Map<string, MusicItem>,
  seen: Set<string>,
): SeqStats {
  if (seen.has(pocketId)) return { songs: 0, ms: 0 };
  seen.add(pocketId);
  const p = pocketsById.get(pocketId);
  if (!p) return { songs: 0, ms: 0 };
  let songs = 0;
  let ms = 0;
  for (const sid of p.songIds) {
    songs++;
    const s = itemsById.get(sid);
    ms += s && isSong(s) && s.lengthMs ? s.lengthMs : DEFAULT_TRACK_MS;
  }
  for (const aid of p.albumIds) {
    const a = itemsById.get(aid);
    if (a && isAlbum(a)) {
      const r = albumMs(a, itemsById);
      songs += r.songs;
      ms += r.ms;
    }
  }
  for (const cid of p.childPocketIds) {
    const r = pocketStats(cid, pocketsById, itemsById, seen);
    songs += r.songs;
    ms += r.ms;
  }
  return { songs, ms };
}

/** Roll up one node (recursing into sub-sequences). */
export function nodeStats(
  node: PlaylistNode,
  pocketsById: Map<string, Pocket>,
  itemsById: Map<string, MusicItem>,
): SeqStats {
  if (isTextNode(node)) return { songs: 0, ms: 0 };
  if (isSongNode(node)) {
    const s = itemsById.get(node.songId);
    return { songs: 1, ms: s && isSong(s) && s.lengthMs ? s.lengthMs : DEFAULT_TRACK_MS };
  }
  if (isAlbumNode(node)) {
    const a = itemsById.get(node.albumId);
    return a && isAlbum(a) ? albumMs(a, itemsById) : { songs: 0, ms: 0 };
  }
  if (isPocketNode(node)) return pocketStats(node.pocketId, pocketsById, itemsById, new Set());
  if (isSequenceNode(node)) return seqStats(node, pocketsById, itemsById);
  return { songs: 0, ms: 0 };
}

/** Roll up a whole sequence (all children). */
export function seqStats(
  seq: SequenceNode,
  pocketsById: Map<string, Pocket>,
  itemsById: Map<string, MusicItem>,
): SeqStats {
  let songs = 0;
  let ms = 0;
  for (const c of seq.children) {
    const r = nodeStats(c, pocketsById, itemsById);
    songs += r.songs;
    ms += r.ms;
  }
  return { songs, ms };
}
