// PocketDJ Playlists, Pockets, and Setlists — the "DJ in your pocket" feature.
//
// Vocabulary (locked with Levi):
//   Pocket   — a named, REUSABLE grouping of harmonically-similar items
//              (songs/albums) that can NEST other pockets → a DAG (cycle-
//              guarded). `kind` reserves a future 'performance' pocket (a DJ-
//              curated set that deliberately breaks musical-harmony bounds);
//              only 'harmonic' is built now. Membership is type-agnostic, so the
//              'performance' kind needs no schema change later.
//   Playlist — a TEMPLATE: an ordered list of Sequences ("chapters"). A sequence
//              has a name, an optional time budget (targetMs), and ordered Nodes
//              (recursive union: song | album | pocket | sub-sequence).
//              sequences[0] is the DEFAULT sequence — bare "add to playlist"
//              lands there and is re-assignable later.
//   Setlist  — a PERSISTED INSTANCE produced by hitting ▶ Play: realize()
//              expands albums → tracks, samples over-budget pockets, and
//              autofills temporal gaps via harmonic interpolation, then FREEZES
//              the concrete ordered tracks (snapshotted so it reads standalone:
//              "yo DJ, spin these tracks, in this order"). One playlist → many
//              setlists (a performance history).
//
// Pockets/playlists/setlists are CROSS-SOURCE user collections (they may mix
// items from any data source), so — unlike MusicItem/DataSource — they carry no
// sourceId. Items are resolved by id from the catalog at view/realize time.

// ---------------------------------------------------------------------------
// Pocket
// ---------------------------------------------------------------------------

/** 'performance' is reserved/deferred — only 'harmonic' is built this iteration. */
export type PocketKind = 'harmonic' | 'performance';

/**
 * A free-text item inside a pocket — a mic cue, a line of poetry, an out-of-index
 * moment (enables a "poetry pocket"). `position` is the note's index in the pocket's
 * UNIFIED member ordering, where members are laid out in a single combined list as
 * [child pockets…, albums…, songs…, notes…] — so a note can sit *between* members.
 * Mirrors the native `PocketNote` byte-for-byte (collections schema v2).
 */
export interface PocketNote {
  /** 'pnt_' + uuid (matches native CollectionsFactory.newPocketNoteId). */
  id: string;
  text: string;
  position: number;
}

export interface Pocket {
  /** 'pkt_' + uuid. */
  id: string;
  name: string;
  kind: PocketKind;
  description?: string;
  /** Direct song members (SongItem.id). */
  songIds: string[];
  /** Direct album members (AlbumItem.id) — expanded to their tracks at realize. */
  albumIds: string[];
  /** Nested pockets (Pocket.id). Forms a DAG; adds are cycle-guarded. */
  childPocketIds: string[];
  /**
   * v2: ordered free-text items (poetry/cues), orderable AMONG the members by
   * `position` (the combined [pockets, albums, songs, notes] layout). Optional so
   * older docs/pockets without it still load (legacy pockets => treat as []).
   */
  notes?: PocketNote[];
  createdAt: number;
  updatedAt: number;
}

// ---------------------------------------------------------------------------
// Playlist template — a recursive tree of nodes grouped into sequences
// ---------------------------------------------------------------------------

export type PlaylistNode = SongNode | AlbumNode | PocketNode | SequenceNode | TextNode;

/** A single song placed directly into a sequence. */
export interface SongNode {
  nodeId: string;
  kind: 'song';
  songId: string;
  /** Optional performer note for this item (shown in the UI + carried into export). */
  note?: string;
  /**
   * Data source the item came from (attribution). Lets the UI degrade gracefully
   * when the item isn't in the loaded catalog/selected sources — it can name the
   * source ("from Apple Music (Local)") instead of showing a blank row. Optional
   * so hand-built, single-source collections need not carry it.
   */
  sourceId?: string;
}
/** A whole album (expands to its tracks at realize). */
export interface AlbumNode {
  nodeId: string;
  kind: 'album';
  albumId: string;
  note?: string;
  /** Data source attribution — see SongNode.sourceId. */
  sourceId?: string;
}
/** A reference to a pocket (resolved lazily — this is what makes auto-update free). */
export interface PocketNode {
  nodeId: string;
  kind: 'pocket';
  pocketId: string;
  note?: string;
}
/**
 * A free-text cue that is NOT backed by a catalog item — e.g. "sample of This
 * Land Is Mine Land", a mic break, or any out-of-index moment. Carried verbatim
 * into the realized setlist (as a no-audio track) and into exports.
 */
export interface TextNode {
  nodeId: string;
  kind: 'text';
  text: string;
  note?: string;
}
/** A chapter (or sub-chapter): an ordered list of child nodes with an optional time budget. */
export interface SequenceNode {
  nodeId: string;
  kind: 'sequence';
  name: string;
  /** When set, realize samples pockets + autofills temporal gaps to fit this budget. */
  targetMs?: number;
  children: PlaylistNode[];
}

export interface Playlist {
  /** 'pls_' + uuid. */
  id: string;
  name: string;
  description?: string;
  /** Chapters. sequences[0] is the default sequence and is always present. */
  sequences: SequenceNode[];
  /** Optional whole-playlist time budget (informational; per-sequence budgets drive realize). */
  targetMs?: number;
  /**
   * Set when this playlist is a MIRROR of a source-native playlist (e.g. an
   * iTunes/Apple Music user playlist). Re-importing the source refreshes mirrors
   * by stable id; hand-built playlists never carry this and are never clobbered.
   * The UI can badge the provenance and offer "refresh from source".
   */
  importedFrom?: { sourceId: string; externalId: string };
  createdAt: number;
  updatedAt: number;
}

// ---------------------------------------------------------------------------
// Setlist instance — the frozen performance produced by Play
// ---------------------------------------------------------------------------

/** How a track ended up in the setlist. */
export type TrackSource = 'explicit' | 'pocket' | 'autofill';

/**
 * DEFERRED (reserved seam): for a setlist track, a ranked track to mix it with —
 * pocket co-members first (curated harmonic similarity), falling back to raw
 * bpm+key compatibility when the track is in no pocket. Labeled "mix suggestions"
 * in the UI. Computed by src/engine/mixSuggest.ts later; the field exists now so
 * lighting it up needs no migration.
 */
export interface MixSuggestion {
  songId: string;
  artist: string;
  name: string;
  bpm: number | null;
  camelot: string | null;
  lengthMs?: number;
  /** Why suggested: shared-pocket harmonic similarity, or raw bpm+key fallback. */
  basis: 'pocket' | 'bpm-key';
  pocketId?: string;
  /** Harmonic closeness (lower = tighter), for ordering. */
  score?: number;
}

export interface SetlistTrack {
  songId: string;
  // --- snapshot so the setlist reads standalone even if the catalog/pockets change ---
  artist: string;
  name: string;
  bpm: number | null;
  camelot: string | null;
  lengthMs?: number;
  // --- provenance ---
  /** Placed explicitly, sampled from a pocket, or an autofill transition bridge. */
  source: TrackSource;
  /** Name of the sequence (chapter) this track came from. */
  sequenceName?: string;
  /** Performer note carried from the template node (and editable on the setlist). Included in export. */
  note?: string;
  /** True for a free-text cue (TextNode) with no backing catalog item / audio. */
  isText?: boolean;
  /** Pocket it was sampled from, when source === 'pocket'. */
  pocketId?: string;
  /** DEFERRED — per-track mix suggestions (see MixSuggestion). */
  mixSuggestions?: MixSuggestion[];
}

export interface Setlist {
  /** 'set_' + uuid. */
  id: string;
  /** Parent playlist template (indexed by_playlist). */
  playlistId: string;
  /** Auto-named on generation, e.g. "Family BBQ — take 3". */
  name?: string;
  /** Generation seed — re-running realize with this reproduces the setlist. */
  seed: string;
  generatedAt: number;
  /** Total runtime of the frozen track list, in ms. */
  totalMs: number;
  tracks: SetlistTrack[];
}

// ---------------------------------------------------------------------------
// id helpers, factories, and type guards
// ---------------------------------------------------------------------------

/** uuid (crypto.randomUUID where available; Math.random fallback for old runtimes/tests). */
function uid(): string {
  const c = (globalThis as { crypto?: { randomUUID?: () => string } }).crypto;
  if (c && typeof c.randomUUID === 'function') return c.randomUUID();
  return 'xxxxxxxxxxxxxxxx'.replace(/x/g, () => Math.floor(Math.random() * 16).toString(16));
}

export const newPocketId = (): string => 'pkt_' + uid();
/** 'pnt_' + uuid — matches native CollectionsFactory.newPocketNoteId. */
export const newPocketNoteId = (): string => 'pnt_' + uid();
export const newPlaylistId = (): string => 'pls_' + uid();
export const newSetlistId = (): string => 'set_' + uid();
export const newNodeId = (): string => 'nd_' + uid();

/** A fresh sequence (chapter) node. */
export function makeSequence(name: string, targetMs?: number): SequenceNode {
  return { nodeId: newNodeId(), kind: 'sequence', name, targetMs, children: [] };
}

/** A fresh, empty pocket. */
export function makePocket(name: string, kind: PocketKind = 'harmonic'): Pocket {
  const now = Date.now();
  return {
    id: newPocketId(),
    name,
    kind,
    songIds: [],
    albumIds: [],
    childPocketIds: [],
    notes: [],
    createdAt: now,
    updatedAt: now,
  };
}

/** A fresh playlist with its default sequence already present. */
export function makePlaylist(name: string): Playlist {
  const now = Date.now();
  return {
    id: newPlaylistId(),
    name,
    sequences: [makeSequence('Default')],
    createdAt: now,
    updatedAt: now,
  };
}

export const isSongNode = (n: PlaylistNode): n is SongNode => n.kind === 'song';
export const isAlbumNode = (n: PlaylistNode): n is AlbumNode => n.kind === 'album';
export const isPocketNode = (n: PlaylistNode): n is PocketNode => n.kind === 'pocket';
export const isSequenceNode = (n: PlaylistNode): n is SequenceNode => n.kind === 'sequence';
export const isTextNode = (n: PlaylistNode): n is TextNode => n.kind === 'text';

/** A fresh free-text cue node. */
export function makeTextNode(text: string): TextNode {
  return { nodeId: newNodeId(), kind: 'text', text };
}
