// In-memory cache + write-through actions for the cross-source user collections
// (pockets + playlists). The store of record is IndexedDB (via repo); this store
// mirrors useDataStore: it holds the loaded lists, exposes async actions that
// persist then update memory, and bumps `rev` so views re-derive. Setlists are
// NOT cached here (they're per-playlist history fetched on demand).
import { create } from 'zustand';
import type { Pocket, Playlist, Setlist, PocketKind } from '../types/collections';
import { makePocket, makePlaylist } from '../types/collections';
import type { SongItem, AlbumItem } from '../types/model';
import {
  getPockets,
  getPlaylists,
  putPocket,
  deletePocket as repoDeletePocket,
  putPlaylist,
  deletePlaylist as repoDeletePlaylist,
  getSongs,
  getAlbums,
  getSetlists as repoGetSetlists,
  getSetlist as repoGetSetlist,
  putSetlist,
  deleteSetlist as repoDeleteSetlist,
} from '../storage/repo';
import {
  addSong,
  addAlbum,
  addPocket as addPocketNode,
  addText as opAddText,
  setNodeNote as opSetNodeNote,
  addSequence as opAddSequence,
  removeSequence as opRemoveSequence,
  renameSequence as opRenameSequence,
  setSequenceTarget as opSetSequenceTarget,
  moveNode as opMoveNode,
  reorderNode as opReorderNode,
  removeNode as opRemoveNode,
} from '../engine/playlistOps';
import { buildSetlist, type RealizeCtx } from '../engine/realize';
import { txn } from '../lib/log';

/** Ref to an item being dropped into a playlist (or pocket). */
export type CollectionRef = { kind: 'song' | 'album'; id: string };

interface CollectionsState {
  pockets: Pocket[];
  playlists: Playlist[];
  loading: boolean;
  /** epoch bumped on any write so views re-derive. */
  rev: number;

  load: () => Promise<void>;

  // ---- pockets ----
  createPocket: (name: string, kind?: PocketKind) => Promise<Pocket>;
  renamePocket: (id: string, name: string) => Promise<void>;
  deletePocket: (id: string) => Promise<void>;
  addSongToPocket: (pocketId: string, songId: string) => Promise<void>;
  addAlbumToPocket: (pocketId: string, albumId: string) => Promise<void>;
  /** Nest childId under parentId. Returns false (no-op) if it would create a cycle. */
  addChildPocket: (parentId: string, childId: string) => Promise<boolean>;
  removeFromPocket: (
    pocketId: string,
    ref: { kind: 'song' | 'album' | 'pocket'; id: string },
  ) => Promise<void>;

  // ---- playlists ----
  createPlaylist: (name: string) => Promise<Playlist>;
  renamePlaylist: (id: string, name: string) => Promise<void>;
  deletePlaylist: (id: string) => Promise<void>;
  /** Add a song/album/pocket to a playlist sequence (defaults to the default sequence). */
  addToPlaylist: (
    playlistId: string,
    ref: { kind: 'song' | 'album' | 'pocket'; id: string },
    sequenceNodeId?: string,
  ) => Promise<void>;
  /** Append a free-text cue (out-of-index item) to a playlist sequence. */
  addTextToPlaylist: (playlistId: string, text: string, sequenceNodeId?: string) => Promise<void>;
  /** Set/clear a performer note on a playlist item node. */
  setPlaylistNodeNote: (playlistId: string, nodeId: string, note: string | undefined) => Promise<void>;
  addSequence: (playlistId: string, name: string) => Promise<void>;
  renameSequence: (playlistId: string, sequenceNodeId: string, name: string) => Promise<void>;
  removeSequence: (playlistId: string, sequenceNodeId: string) => Promise<void>;
  setSequenceTarget: (playlistId: string, sequenceNodeId: string, targetMs?: number) => Promise<void>;
  moveNode: (playlistId: string, nodeId: string, toSequenceNodeId: string) => Promise<void>;
  /** Move a node up (-1) or down (+1) within its sequence. */
  reorderNode: (playlistId: string, nodeId: string, delta: number) => Promise<void>;
  removeNode: (playlistId: string, nodeId: string) => Promise<void>;

  // ---- setlists ----
  /** ▶ Play: realize the playlist into a frozen Setlist, persist it, return it. */
  play: (playlistId: string) => Promise<Setlist | null>;
  getSetlists: (playlistId: string) => Promise<Setlist[]>;
  deleteSetlist: (id: string) => Promise<void>;
  /** Rename a persisted setlist. */
  renameSetlist: (id: string, name: string) => Promise<Setlist | null>;
  /** Set/clear a performer note on a setlist track (by index). */
  setSetlistTrackNote: (id: string, trackIndex: number, note: string | undefined) => Promise<Setlist | null>;
}

/** Replace an entity by id (or append) in an immutable list copy. */
function upsert<T extends { id: string }>(list: T[], item: T): T[] {
  const i = list.findIndex((x) => x.id === item.id);
  if (i < 0) return [...list, item];
  const next = list.slice();
  next[i] = item;
  return next;
}

/** Does `start` reach `target` following childPocketIds? (DFS, visited-guarded.) */
function reaches(start: string, target: string, byId: Map<string, Pocket>): boolean {
  const stack = [start];
  const seen = new Set<string>();
  while (stack.length) {
    const id = stack.pop() as string;
    if (id === target) return true;
    if (seen.has(id)) continue;
    seen.add(id);
    const p = byId.get(id);
    if (p) for (const c of p.childPocketIds) stack.push(c);
  }
  return false;
}

/** Nesting child under parent creates a cycle iff child === parent or child already reaches parent. */
function wouldCreateCycle(byId: Map<string, Pocket>, parentId: string, childId: string): boolean {
  if (parentId === childId) return true;
  return reaches(childId, parentId, byId);
}

export const useCollectionsStore = create<CollectionsState>((set, get) => {
  /** Persist a pocket and reflect it in memory. */
  async function savePocket(p: Pocket): Promise<void> {
    await putPocket(p); // stamps updatedAt + logs pocket.update
    set((s) => ({ pockets: upsert(s.pockets, p), rev: s.rev + 1 }));
  }
  /** Persist a playlist and reflect it in memory. */
  async function savePlaylist(p: Playlist): Promise<void> {
    await putPlaylist(p);
    set((s) => ({ playlists: upsert(s.playlists, p), rev: s.rev + 1 }));
  }
  const pocketById = (id: string) => get().pockets.find((p) => p.id === id);
  const playlistById = (id: string) => get().playlists.find((p) => p.id === id);

  return {
    pockets: [],
    playlists: [],
    loading: false,
    rev: 0,

    load: async () => {
      set({ loading: true });
      const [pockets, playlists] = await Promise.all([getPockets(), getPlaylists()]);
      set({ pockets, playlists, loading: false });
    },

    // ---- pockets ----
    createPocket: async (name, kind = 'harmonic') => {
      const p = makePocket(name, kind);
      await putPocket(p);
      txn('pocket.create', { id: p.id, name: p.name, kind: p.kind });
      set((s) => ({ pockets: upsert(s.pockets, p), rev: s.rev + 1 }));
      return p;
    },
    renamePocket: async (id, name) => {
      const p = pocketById(id);
      if (!p) return;
      await savePocket({ ...p, name });
    },
    deletePocket: async (id) => {
      await repoDeletePocket(id);
      // Also drop it as a child reference from any other pocket.
      const orphaned = get().pockets.filter((p) => p.childPocketIds.includes(id));
      for (const p of orphaned) {
        await putPocket({ ...p, childPocketIds: p.childPocketIds.filter((c) => c !== id) });
      }
      set((s) => ({
        pockets: s.pockets
          .filter((p) => p.id !== id)
          .map((p) =>
            p.childPocketIds.includes(id)
              ? { ...p, childPocketIds: p.childPocketIds.filter((c) => c !== id) }
              : p,
          ),
        rev: s.rev + 1,
      }));
    },
    addSongToPocket: async (pocketId, songId) => {
      const p = pocketById(pocketId);
      if (!p || p.songIds.includes(songId)) return;
      await savePocket({ ...p, songIds: [...p.songIds, songId] });
      txn('pocket.addItem', { pocketId, kind: 'song', id: songId });
    },
    addAlbumToPocket: async (pocketId, albumId) => {
      const p = pocketById(pocketId);
      if (!p || p.albumIds.includes(albumId)) return;
      await savePocket({ ...p, albumIds: [...p.albumIds, albumId] });
      txn('pocket.addItem', { pocketId, kind: 'album', id: albumId });
    },
    addChildPocket: async (parentId, childId) => {
      const p = pocketById(parentId);
      if (!p || p.childPocketIds.includes(childId)) return false;
      const byId = new Map(get().pockets.map((x) => [x.id, x]));
      if (!byId.has(childId) || wouldCreateCycle(byId, parentId, childId)) return false;
      await savePocket({ ...p, childPocketIds: [...p.childPocketIds, childId] });
      txn('pocket.addItem', { pocketId: parentId, kind: 'pocket', id: childId });
      return true;
    },
    removeFromPocket: async (pocketId, ref) => {
      const p = pocketById(pocketId);
      if (!p) return;
      const next =
        ref.kind === 'song'
          ? { ...p, songIds: p.songIds.filter((x) => x !== ref.id) }
          : ref.kind === 'album'
            ? { ...p, albumIds: p.albumIds.filter((x) => x !== ref.id) }
            : { ...p, childPocketIds: p.childPocketIds.filter((x) => x !== ref.id) };
      await savePocket(next);
    },

    // ---- playlists ----
    createPlaylist: async (name) => {
      const p = makePlaylist(name);
      await putPlaylist(p);
      txn('playlist.create', { id: p.id, name: p.name });
      set((s) => ({ playlists: upsert(s.playlists, p), rev: s.rev + 1 }));
      return p;
    },
    renamePlaylist: async (id, name) => {
      const p = playlistById(id);
      if (!p) return;
      await savePlaylist({ ...p, name });
    },
    deletePlaylist: async (id) => {
      await repoDeletePlaylist(id); // cascades setlists
      set((s) => ({ playlists: s.playlists.filter((p) => p.id !== id), rev: s.rev + 1 }));
    },
    addToPlaylist: async (playlistId, ref, sequenceNodeId) => {
      const p = playlistById(playlistId);
      if (!p) return;
      const seqId = sequenceNodeId ?? p.sequences[0].nodeId;
      const next =
        ref.kind === 'song'
          ? addSong(p, seqId, ref.id)
          : ref.kind === 'album'
            ? addAlbum(p, seqId, ref.id)
            : addPocketNode(p, seqId, ref.id);
      await savePlaylist(next);
      txn('playlist.addItem', { playlistId, kind: ref.kind, id: ref.id, sequence: seqId });
    },
    addTextToPlaylist: async (playlistId, text, sequenceNodeId) => {
      const p = playlistById(playlistId);
      if (!p || !text.trim()) return;
      const seqId = sequenceNodeId ?? p.sequences[0].nodeId;
      await savePlaylist(opAddText(p, seqId, text.trim()));
      txn('playlist.addItem', { playlistId, kind: 'text', sequence: seqId });
    },
    setPlaylistNodeNote: async (playlistId, nodeId, note) => {
      const p = playlistById(playlistId);
      if (!p) return;
      await savePlaylist(opSetNodeNote(p, nodeId, note));
    },
    addSequence: async (playlistId, name) => {
      const p = playlistById(playlistId);
      if (!p) return;
      await savePlaylist(opAddSequence(p, name));
    },
    renameSequence: async (playlistId, sequenceNodeId, name) => {
      const p = playlistById(playlistId);
      if (!p) return;
      await savePlaylist(opRenameSequence(p, sequenceNodeId, name));
    },
    removeSequence: async (playlistId, sequenceNodeId) => {
      const p = playlistById(playlistId);
      if (!p) return;
      await savePlaylist(opRemoveSequence(p, sequenceNodeId));
    },
    setSequenceTarget: async (playlistId, sequenceNodeId, targetMs) => {
      const p = playlistById(playlistId);
      if (!p) return;
      await savePlaylist(opSetSequenceTarget(p, sequenceNodeId, targetMs));
    },
    moveNode: async (playlistId, nodeId, toSequenceNodeId) => {
      const p = playlistById(playlistId);
      if (!p) return;
      await savePlaylist(opMoveNode(p, nodeId, toSequenceNodeId));
    },
    reorderNode: async (playlistId, nodeId, delta) => {
      const p = playlistById(playlistId);
      if (!p) return;
      const next = opReorderNode(p, nodeId, delta);
      if (next !== p) await savePlaylist(next);
    },
    removeNode: async (playlistId, nodeId) => {
      const p = playlistById(playlistId);
      if (!p) return;
      await savePlaylist(opRemoveNode(p, nodeId));
    },

    // ---- setlists ----
    play: async (playlistId) => {
      const playlist = playlistById(playlistId);
      if (!playlist) return null;

      // Build the realize context from the whole catalog + current pockets.
      const [songs, albums, priorSetlists] = await Promise.all([
        getSongs(),
        getAlbums(),
        repoGetSetlists(playlistId),
      ]);
      const songsById = new Map<string, SongItem>(songs.map((s) => [s.id, s]));
      const albumsById = new Map<string, AlbumItem>(albums.map((a) => [a.id, a]));
      const pocketsById = new Map<string, Pocket>(get().pockets.map((p) => [p.id, p]));
      const candidates = songs.filter((s) => s.bpm != null && s.camelot != null);
      const ctx: RealizeCtx = { songsById, albumsById, pocketsById, candidates };

      // Unique per-play seed → a fresh sampling each time; name as "<playlist> — take N".
      const seed = `${playlistId}:${Date.now()}`;
      const name = `${playlist.name} — take ${priorSetlists.length + 1}`;
      const setlist = buildSetlist(playlist, ctx, { seed, name }); // realize() logs playlist.realize
      await putSetlist(setlist); // logs setlist.create
      set((s) => ({ rev: s.rev + 1 }));
      return setlist;
    },
    getSetlists: (playlistId) => repoGetSetlists(playlistId),
    deleteSetlist: async (id) => {
      await repoDeleteSetlist(id);
      set((s) => ({ rev: s.rev + 1 }));
    },
    renameSetlist: async (id, name) => {
      const s = await repoGetSetlist(id);
      if (!s) return null;
      const next = { ...s, name };
      await putSetlist(next);
      set((st) => ({ rev: st.rev + 1 }));
      return next;
    },
    setSetlistTrackNote: async (id, trackIndex, note) => {
      const s = await repoGetSetlist(id);
      if (!s || trackIndex < 0 || trackIndex >= s.tracks.length) return null;
      const clean = note && note.trim() ? note.trim() : undefined;
      const tracks = s.tracks.slice();
      tracks[trackIndex] = { ...tracks[trackIndex], note: clean };
      const next = { ...s, tracks };
      await putSetlist(next);
      set((st) => ({ rev: st.rev + 1 }));
      return next;
    },
  };
});
