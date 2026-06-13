// Star-map layout types.
//
// The layout module (src/starmap/layout.ts) produces a renderer-agnostic scene:
// pure {x, y, r} geometry. The current renderer is static 2D SVG; a future 3D
// renderer consumes the same data (adding a `z`). Keeping geometry separate from
// rendering is the seam that lets the visualization evolve to animated/3D later.

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
}

export interface Constellation {
  genre: string;
  label: string;
  /** Bounding box in scene coordinates. */
  x: number;
  y: number;
  w: number;
  h: number;
  /** Ids of member stars, ordered by year (for the constellation polyline). */
  starIds: string[];
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
