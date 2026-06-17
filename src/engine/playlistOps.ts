// Pure, immutable tree transforms on a Playlist TEMPLATE.
//
// A Playlist is an ordered list of Sequences ("chapters"); each sequence holds
// an ordered, recursive list of PlaylistNodes (song | album | pocket | nested
// sequence). These helpers are the editing primitives the store calls — the
// store persists whatever copy we return.
//
// Contract (house rules):
//   - PURE: never mutate the input Playlist or any of its nodes. Every export
//     returns a NEW Playlist, deep-copying only the touched path (untouched
//     branches are shared by reference, which is safe because nothing mutates).
//   - DETERMINISTIC: no Date.now / Math.random here. Timestamps (createdAt /
//     updatedAt) are carried through untouched; the store stamps updatedAt when
//     it persists. (Only the top-level realize op logs; these primitives don't.)
//   - sequences[0] is the DEFAULT sequence and is ALWAYS present — addNode falls
//     back to it when a sequence id is unknown, and removeSequence refuses to
//     delete the last remaining sequence.

import {
  type Playlist,
  type PlaylistNode,
  type SequenceNode,
  type SongNode,
  type AlbumNode,
  type PocketNode,
  type TextNode,
  makeSequence,
  newNodeId,
  isSequenceNode,
  isSongNode,
  isAlbumNode,
  isPocketNode,
} from '../types/collections';

/** The default sequence (sequences[0]) — bare "add to playlist" lands here. */
export const DEFAULT_SEQUENCE = (pl: Playlist): SequenceNode => pl.sequences[0];

// ---------------------------------------------------------------------------
// internal helpers (not exported) — all build fresh structures, never mutate
// ---------------------------------------------------------------------------

/** Shallow-clone a Playlist with a replacement `sequences` array. */
function withSequences(pl: Playlist, sequences: SequenceNode[]): Playlist {
  return { ...pl, sequences };
}

/** Replace a node's children with a fresh array (returns a NEW node). */
function withChildren<N extends SequenceNode>(seq: N, children: PlaylistNode[]): N {
  return { ...seq, children };
}

/**
 * Recursively remove the node with `nodeId` from a node's `children` (and from
 * any nested sequence's children). Returns the SAME node when nothing changed.
 */
function removeNodeFrom(node: PlaylistNode, nodeId: string): PlaylistNode {
  if (!isSequenceNode(node)) return node;
  let changed = false;
  const children: PlaylistNode[] = [];
  for (const c of node.children) {
    if (c.nodeId === nodeId) {
      changed = true;
      continue; // drop it
    }
    const next = removeNodeFrom(c, nodeId);
    if (next !== c) changed = true;
    children.push(next);
  }
  return changed ? withChildren(node, children) : node;
}

/** Find a node by id anywhere in the tree (depth-first). */
function findNode(nodes: PlaylistNode[], nodeId: string): PlaylistNode | undefined {
  for (const n of nodes) {
    if (n.nodeId === nodeId) return n;
    if (isSequenceNode(n)) {
      const hit = findNode(n.children, nodeId);
      if (hit) return hit;
    }
  }
  return undefined;
}

/** Index of the top-level sequence with this id, or -1. */
function sequenceIndex(pl: Playlist, sequenceNodeId: string): number {
  return pl.sequences.findIndex((s) => s.nodeId === sequenceNodeId);
}

/**
 * Append `node` to the children of the top-level sequence at `idx` (resolved by
 * the caller; falls back to 0). Returns a NEW Playlist with that one sequence
 * deep-copied.
 */
function appendToSequenceAt(pl: Playlist, idx: number, node: PlaylistNode): Playlist {
  const target = pl.sequences[idx];
  const nextSeq = withChildren(target, [...target.children, node]);
  const sequences = pl.sequences.slice();
  sequences[idx] = nextSeq;
  return withSequences(pl, sequences);
}

// ---------------------------------------------------------------------------
// Sequence-level ops
// ---------------------------------------------------------------------------

/** Append a fresh, empty SequenceNode (chapter) to the playlist. */
export function addSequence(pl: Playlist, name: string): Playlist {
  return withSequences(pl, [...pl.sequences, makeSequence(name)]);
}

/**
 * Remove a top-level sequence by id. NEVER removes the last remaining sequence
 * (the default sequence must always exist) — that's a no-op (same reference).
 * A no-match id is also a no-op.
 */
export function removeSequence(pl: Playlist, sequenceNodeId: string): Playlist {
  if (pl.sequences.length <= 1) return pl;
  const idx = sequenceIndex(pl, sequenceNodeId);
  if (idx < 0) return pl;
  const sequences = pl.sequences.filter((_, i) => i !== idx);
  return withSequences(pl, sequences);
}

/** Rename a top-level sequence. No-op if the id is unknown. */
export function renameSequence(pl: Playlist, sequenceNodeId: string, name: string): Playlist {
  const idx = sequenceIndex(pl, sequenceNodeId);
  if (idx < 0) return pl;
  const sequences = pl.sequences.slice();
  sequences[idx] = { ...sequences[idx], name };
  return withSequences(pl, sequences);
}

/**
 * Set (or clear, with `undefined`) a top-level sequence's time budget. No-op if
 * the id is unknown.
 */
export function setSequenceTarget(
  pl: Playlist,
  sequenceNodeId: string,
  targetMs: number | undefined,
): Playlist {
  const idx = sequenceIndex(pl, sequenceNodeId);
  if (idx < 0) return pl;
  const sequences = pl.sequences.slice();
  sequences[idx] = { ...sequences[idx], targetMs };
  return withSequences(pl, sequences);
}

// ---------------------------------------------------------------------------
// Node-level ops
// ---------------------------------------------------------------------------

/**
 * Append `node` to the children of the named top-level sequence. If
 * `sequenceNodeId` is not a top-level sequence, the node lands in the DEFAULT
 * sequence (sequences[0]).
 */
export function addNode(pl: Playlist, sequenceNodeId: string, node: PlaylistNode): Playlist {
  const idx = sequenceIndex(pl, sequenceNodeId);
  return appendToSequenceAt(pl, idx < 0 ? 0 : idx, node);
}

/** Convenience: wrap `songId` in a SongNode and append it. */
export function addSong(pl: Playlist, sequenceNodeId: string, songId: string): Playlist {
  const node: SongNode = { nodeId: newNodeId(), kind: 'song', songId };
  return addNode(pl, sequenceNodeId, node);
}

/** Convenience: wrap `albumId` in an AlbumNode and append it. */
export function addAlbum(pl: Playlist, sequenceNodeId: string, albumId: string): Playlist {
  const node: AlbumNode = { nodeId: newNodeId(), kind: 'album', albumId };
  return addNode(pl, sequenceNodeId, node);
}

/** Convenience: wrap `pocketId` in a PocketNode and append it. */
export function addPocket(pl: Playlist, sequenceNodeId: string, pocketId: string): Playlist {
  const node: PocketNode = { nodeId: newNodeId(), kind: 'pocket', pocketId };
  return addNode(pl, sequenceNodeId, node);
}

/** Convenience: append a free-text cue (out-of-index item) to a sequence. */
export function addText(pl: Playlist, sequenceNodeId: string, text: string): Playlist {
  const node: TextNode = { nodeId: newNodeId(), kind: 'text', text };
  return addNode(pl, sequenceNodeId, node);
}

/** Recursively map the node with `nodeId`, returning the SAME tree when unchanged. */
function mapNode(
  node: PlaylistNode,
  nodeId: string,
  fn: (n: PlaylistNode) => PlaylistNode,
): PlaylistNode {
  if (node.nodeId === nodeId) return fn(node);
  if (!isSequenceNode(node)) return node;
  let changed = false;
  const children = node.children.map((c) => {
    const next = mapNode(c, nodeId, fn);
    if (next !== c) changed = true;
    return next;
  });
  return changed ? withChildren(node, children) : node;
}

/**
 * Set (or clear, with `undefined`/'') a performer note on any item node. No-op if
 * the id is unknown or the node is a sequence (sequences carry names, not notes).
 */
export function setNodeNote(pl: Playlist, nodeId: string, note: string | undefined): Playlist {
  const clean = note && note.trim() ? note.trim() : undefined;
  let changed = false;
  const sequences = pl.sequences.map((seq) => {
    const next = mapNode(
      seq,
      nodeId,
      (n) => (isSequenceNode(n) ? n : ({ ...n, note: clean } as PlaylistNode)),
    ) as SequenceNode;
    if (next !== seq) changed = true;
    return next;
  });
  return changed ? withSequences(pl, sequences) : pl;
}

/** Directly-placed refs in a playlist (no album/pocket expansion). For membership/filtering. */
export interface PlaylistRefs {
  songIds: Set<string>;
  albumIds: Set<string>;
  pocketIds: Set<string>;
}

/** Walk all sequences and collect the song/album/pocket ids placed directly in the template. */
export function collectPlaylistRefs(pl: Playlist): PlaylistRefs {
  const refs: PlaylistRefs = { songIds: new Set(), albumIds: new Set(), pocketIds: new Set() };
  const walk = (nodes: PlaylistNode[]) => {
    for (const n of nodes) {
      if (isSongNode(n)) refs.songIds.add(n.songId);
      else if (isAlbumNode(n)) refs.albumIds.add(n.albumId);
      else if (isPocketNode(n)) refs.pocketIds.add(n.pocketId);
      else if (isSequenceNode(n)) walk(n.children);
    }
  };
  walk(pl.sequences);
  return refs;
}

/**
 * Remove any node by `nodeId`, searching recursively through every sequence's
 * children. (Top-level sequences are NOT removable here — use removeSequence.)
 * A no-match id is a no-op (same reference).
 */
export function removeNode(pl: Playlist, nodeId: string): Playlist {
  let changed = false;
  const sequences = pl.sequences.map((seq) => {
    const next = removeNodeFrom(seq, nodeId) as SequenceNode;
    if (next !== seq) changed = true;
    return next;
  });
  return changed ? withSequences(pl, sequences) : pl;
}

/**
 * Relocate the node with `nodeId` to the END of `toSequenceNodeId`'s children.
 * The node is detached from wherever it currently lives (including nested
 * sequences). No-ops (same reference) when:
 *   - the node id isn't found,
 *   - the destination top-level sequence id isn't found, or
 *   - moving a node into itself / its own subtree (would orphan it).
 */
export function moveNode(pl: Playlist, nodeId: string, toSequenceNodeId: string): Playlist {
  const destIdx = sequenceIndex(pl, toSequenceNodeId);
  if (destIdx < 0) return pl;

  const moving = findNode(pl.sequences, nodeId);
  if (!moving) return pl;

  // Guard: can't move a node into itself or into one of its own descendants.
  if (moving.nodeId === toSequenceNodeId) return pl;
  if (isSequenceNode(moving) && findNode(moving.children, toSequenceNodeId)) return pl;

  // 1) Detach from its current home.
  const detached = removeNode(pl, nodeId);
  // 2) Append (the original node reference — untouched) to the destination.
  return appendToSequenceAt(detached, sequenceIndex(detached, toSequenceNodeId), moving);
}

/** Swap a node with its previous/next sibling inside whatever children array holds it. */
function reorderWithin(
  children: PlaylistNode[],
  nodeId: string,
  delta: number,
): { changed: boolean; children: PlaylistNode[] } {
  const i = children.findIndex((c) => c.nodeId === nodeId);
  if (i >= 0) {
    const j = i + delta;
    if (j < 0 || j >= children.length) return { changed: false, children }; // at a boundary
    const next = children.slice();
    [next[i], next[j]] = [next[j], next[i]];
    return { changed: true, children: next };
  }
  // Not at this level — recurse into nested sequences (first match wins).
  let changed = false;
  const next = children.map((c) => {
    if (changed || !isSequenceNode(c)) return c;
    const r = reorderWithin(c.children, nodeId, delta);
    if (r.changed) {
      changed = true;
      return withChildren(c, r.children);
    }
    return c;
  });
  return { changed, children: next };
}

/**
 * Move a node UP (delta -1) or DOWN (delta +1) by one position within its own
 * sequence (the children array that holds it, at any nesting depth). No-op (same
 * reference) at a boundary or if the id isn't found.
 */
export function reorderNode(pl: Playlist, nodeId: string, delta: number): Playlist {
  let changed = false;
  const sequences = pl.sequences.map((seq) => {
    if (changed) return seq;
    const r = reorderWithin(seq.children, nodeId, delta);
    if (r.changed) {
      changed = true;
      return withChildren(seq, r.children);
    }
    return seq;
  });
  return changed ? withSequences(pl, sequences) : pl;
}
