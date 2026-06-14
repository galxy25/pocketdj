// Star-map layout types.
//
// The layout module (src/starmap/layout.ts) produces a renderer-agnostic scene:
// pure {x, y, r} geometry. The current renderer is static 2D SVG; a future 3D
// renderer consumes the same data (adding a `z`). Keeping geometry separate from
// rendering is the seam that lets the visualization evolve to animated/3D later.

/**
 * Star-map tier. Tier 1 = top categories (constellations are categories, album
 * stars NOT directly clickable). Tier 2 = sub-genres (album stars ARE clickable).
 */
export type Tier = 1 | 2;

export interface Star {
  albumId: string;
  /** Scene coordinates. */
  x: number;
  y: number;
  /** Radius (star size). */
  r: number;
  coverArtKey?: string;
  /** Convenience copies for labels/tooltips/tests without a second lookup. */
  artist: string;
  name: string;
  year?: number;
  /** Tier-1 category this album maps to (from constellationMap.categorize). */
  category: string;
  /** Tier-2 sub-genre within `category`. */
  subgenre: string;
  /**
   * Whether THIS star is the click target in the current layout's tier.
   * false on tier 1 (the constellation is the click target; stars render
   * dimmed underneath the hazy overlay); true on tier 2 (click -> solar system).
   */
  clickable: boolean;
}

export interface Constellation {
  /**
   * Stable grouping key for this constellation. On tier 1 this is the category
   * name; on tier 2 it is the sub-genre name. Used for keys + data-testids.
   * (Kept named `genre` for backward compatibility with existing renderer/tests.)
   */
  genre: string;
  /** Human-readable label drawn on the map. */
  label: string;
  /** Bounding box in scene coordinates. */
  x: number;
  y: number;
  w: number;
  h: number;
  /** Ids of member stars, ordered by year (for the constellation polyline). */
  starIds: string[];
  /** Tier this constellation belongs to (1 = category, 2 = sub-genre). */
  tier: Tier;
  /** The tier-1 category this constellation belongs to (always set). */
  category: string;
  /** The tier-2 sub-genre (only set when tier === 2). */
  subgenre?: string;
}

export interface StarMapLayout {
  stars: Star[];
  constellations: Constellation[];
  width: number;
  height: number;
  /** Year range mapped onto the vertical axis. */
  minYear: number;
  maxYear: number;
  /** Content hash of the album set this layout was computed for (cache key). */
  albumSetHash: string;
  /** Tier this layout was computed for (1 = categories, 2 = sub-genres). */
  tier: Tier;
  /**
   * When set, the layout is a FOCUSED tier-2 drill-in showing only this
   * category's sub-genre constellations. Undefined for the global tier-1 view
   * and the global tier-2 view (all sub-genres at once).
   */
  focusCategory?: string;
}

// ---------------------------------------------------------------------------
// NEBULA layout — the BPM / KEY star-map modes.
//
// In BPM/KEY modes a constellation (a bpm range or a key) is NOT one star per
// album/song. It is a hazy NEBULA: a soft glow of radius `r` holding a SEEDED,
// DECORATIVE scatter of ~15–30 small faint stars (NOT 1:1 with songs), a label,
// and the song COUNT. Clicking a nebula opens the browser pre-filtered (`filter`)
// to exactly that constellation's songs. Produced by computeNebulaLayout().
// ---------------------------------------------------------------------------

/** One decorative scatter star inside a nebula (relative to the SCENE, not the
 * nebula center — already offset). Purely visual; carries no song identity. */
export interface NebulaStar {
  x: number;
  y: number;
  r: number;
}

/**
 * The browser filter that selects exactly this nebula's songs, or `null` for the
 * catch-all "Unknown" nebula (missing bpm/key has no clean predicate). Shape
 * mirrors a FilterClause (src/types/filter.ts) minus the runtime `id`. Re-declared
 * here (instead of imported from ../starmap/grouping) so the type module has no
 * dependency on the grouping module; the two MUST stay in sync.
 */
export type NebulaFilter =
  | { field: 'bpm'; op: 'between'; min: number; max: number }
  | { field: 'camelot' | 'key'; op: 'eq'; value: string };

/** One nebula = one constellation (bpm range or key) in BPM/KEY mode. */
export interface Nebula {
  /** Stable grouping key + data-testid suffix + scatter seed (e.g. "120", "8A"). */
  id: string;
  /** Human display label drawn on the map (e.g. "120–130", "8A", "A minor"). */
  label: string;
  /** Number of songs in this constellation (shown as the caption, drives `r`). */
  songCount: number;
  /** Nebula center in scene coordinates. */
  x: number;
  y: number;
  /** Glow radius (size ~ sqrt(songCount)); the scatter stars sit within it. */
  r: number;
  /** Browser filter selecting these songs (null for the "Unknown" nebula). */
  filter: NebulaFilter | null;
  /** Seeded decorative scatter (~15–30 stars), already in scene coordinates. */
  stars: NebulaStar[];
}

export interface NebulaLayout {
  nebulae: Nebula[];
  width: number;
  height: number;
  /**
   * Content hash of the constellation set this layout was computed for (cache
   * key). Derived from constellation ids + counts, so the layout caches per
   * (song set + mode) like the genre layout's albumSetHash. Named to match the
   * StarMapLayout cache plumbing in StarMapScene.
   */
  albumSetHash: string;
}

export interface Planet {
  songId: string;
  trackNumber: number;
  name: string;
  /** Orbit radius from the sun. */
  orbit: number;
  /** Planet radius (size ~ length). */
  r: number;
  /** Static angle (radians), seeded by song id. */
  angle: number;
  explicit: boolean;
  sentimentKeywords: string[];
}

export interface SolarSystem {
  albumId: string;
  sunArtKey?: string;
  artist: string;
  name: string;
  planets: Planet[];
  /** Scene size. */
  size: number;
}
