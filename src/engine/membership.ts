// Which songs are "already in" a set of selected playlists/pockets — powers the
// browser's "exclude songs already in playlist/pocket" filter. A song counts as a
// member of a collection if it's placed directly (by songId) OR its owning album
// is placed (by albumId), so we never need to expand albums to their tracks: we
// just check the song's own albumId against the collection's placed album ids.
import type { Playlist, Pocket } from '../types/collections';
import type { SongItem } from '../types/model';
import { collectPlaylistRefs } from './playlistOps';

export interface MemberSets {
  songIds: Set<string>;
  albumIds: Set<string>;
}

function addPocket(pocketId: string, byId: Map<string, Pocket>, acc: MemberSets, seen: Set<string>): void {
  if (seen.has(pocketId)) return; // cycle / revisit guard (pockets form a DAG)
  seen.add(pocketId);
  const p = byId.get(pocketId);
  if (!p) return;
  p.songIds.forEach((x) => acc.songIds.add(x));
  p.albumIds.forEach((x) => acc.albumIds.add(x));
  p.childPocketIds.forEach((c) => addPocket(c, byId, acc, seen));
}

/** Union of placed song/album ids across the selected collection ids (pls_/pkt_). */
export function membersOf(selectedIds: Set<string>, playlists: Playlist[], pockets: Pocket[]): MemberSets {
  const acc: MemberSets = { songIds: new Set(), albumIds: new Set() };
  const byId = new Map(pockets.map((p) => [p.id, p]));
  for (const id of selectedIds) {
    if (id.startsWith('pkt_')) {
      addPocket(id, byId, acc, new Set());
    } else {
      const pl = playlists.find((p) => p.id === id);
      if (!pl) continue;
      const refs = collectPlaylistRefs(pl);
      refs.songIds.forEach((x) => acc.songIds.add(x));
      refs.albumIds.forEach((x) => acc.albumIds.add(x));
      const seen = new Set<string>();
      refs.pocketIds.forEach((pid) => addPocket(pid, byId, acc, seen)); // pockets referenced by the playlist
    }
  }
  return acc;
}

/** True when the song is already in one of the selected collections (member sets). */
export function isMember(song: SongItem, m: MemberSets): boolean {
  return m.songIds.has(song.id) || (!!song.albumId && m.albumIds.has(song.albumId));
}
