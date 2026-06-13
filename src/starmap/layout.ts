// Star-map layout: pure, renderer-agnostic geometry. No React, no DOM.
//
// Produces a StarMapLayout from a set of albums:
//   - Constellations = genres. Each genre's albums are packed into a bounding box.
//   - Vertical position = year (newer higher within the box).
//   - Horizontal position = seeded pseudo-random (unique shape per constellation).
//   - Deterministic: same album id -> same spot across reloads.
//
// The geometry is intentionally {x, y, r} only so a future 3D / animated renderer
// can consume the same data (adding z / time) without touching this module.
import type { AlbumItem } from '../types/model';
import type { Constellation, Planet, SolarSystem, Star, StarMapLayout } from '../types/starmap';
import { fnv1a, seededRng } from '../lib/prng';
import { computeSolarSystem } from './solarSystem';

// Re-export so callers can import either entry point.
export { computeSolarSystem };
export type { SolarSystem, Planet };

// ---- tuning constants ----
const CELL = 46; // star diameter incl. gap (px)
const STAR_R_MIN = 16;
const STAR_R_MAX = 20;
const BOX_PAD = 56; // padding between constellation boxes
const BOX_INNER_PAD = 28; // inner padding (keeps stars off the box edge / label)
const LABEL_H = 26; // headroom for the genre label above the box content
const BAND_GAP = 64; // vertical gap between shelf bands
const SCENE_MARGIN = 80;
const MIN_DIST = CELL * 0.92; // collision threshold
const RELAX_ITERS = 8;

interface BoxSpec {
  genre: string;
  label: string;
  albums: AlbumItem[];
  w: number;
  h: number;
  // assigned during packing:
  x: number;
  y: number;
}

const UNKNOWN_GENRE = 'Unknown';

function genreOf(a: AlbumItem): string {
  const g = (a.genre ?? '').trim();
  return g.length ? g : UNKNOWN_GENRE;
}

/** Deterministic star radius (stable per album). */
function starRadius(albumId: string): number {
  const t = seededRng('r:' + albumId)();
  return STAR_R_MIN + t * (STAR_R_MAX - STAR_R_MIN);
}

/** Map a year onto [0,1] where 1 = newest. Unknown year -> 0 (bottom). */
function yearFrac(year: number | undefined, minYear: number, maxYear: number): number {
  if (year == null || !isFinite(year)) return 0;
  if (maxYear === minYear) return 0.5;
  const f = (year - minYear) / (maxYear - minYear);
  return Math.max(0, Math.min(1, f));
}

export function computeLayout(albums: AlbumItem[]): StarMapLayout {
  const albumSetHash = fnv1a(
    albums
      .map((a) => a.id)
      .sort()
      .join(','),
  ).toString(16);

  // Global year range (drives vertical mapping inside every box).
  let minYear = Infinity;
  let maxYear = -Infinity;
  for (const a of albums) {
    if (a.year != null && isFinite(a.year)) {
      if (a.year < minYear) minYear = a.year;
      if (a.year > maxYear) maxYear = a.year;
    }
  }
  if (!isFinite(minYear)) {
    minYear = 0;
    maxYear = 0;
  }

  // Group by genre.
  const byGenre = new Map<string, AlbumItem[]>();
  for (const a of albums) {
    const g = genreOf(a);
    const arr = byGenre.get(g);
    if (arr) arr.push(a);
    else byGenre.set(g, [a]);
  }

  // Constellation boxes, sized ~ ceil(sqrt(count)) cells, sorted by member count
  // desc for stable placement (largest first).
  const boxes: BoxSpec[] = [...byGenre.entries()]
    .map(([genre, members]) => {
      const count = members.length;
      const cells = Math.max(1, Math.ceil(Math.sqrt(count)));
      // Expand width first if a box is too dense (give the relaxer room on X).
      const wCells = count > cells * cells - cells ? cells + 1 : cells;
      const w = wCells * CELL + BOX_INNER_PAD * 2;
      const h = cells * CELL + BOX_INNER_PAD * 2 + LABEL_H;
      return { genre, label: genre, albums: members, w, h, x: 0, y: 0 };
    })
    .sort((a, b) => b.albums.length - a.albums.length || a.genre.localeCompare(b.genre));

  // Shelf-pack boxes left->right, wrapping to the next band. Band width grows
  // with the album count so very large libraries stay roughly square.
  const totalCells = albums.length;
  const bandWidth = Math.max(
    640,
    Math.ceil(Math.sqrt(totalCells)) * CELL * 1.6 + SCENE_MARGIN * 2,
  );

  let cursorX = SCENE_MARGIN;
  let bandTop = SCENE_MARGIN;
  let bandHeight = 0;
  let sceneRight = 0;
  for (const box of boxes) {
    if (cursorX > SCENE_MARGIN && cursorX + box.w > bandWidth - SCENE_MARGIN) {
      // wrap to next band
      cursorX = SCENE_MARGIN;
      bandTop += bandHeight + BAND_GAP;
      bandHeight = 0;
    }
    box.x = cursorX;
    box.y = bandTop;
    cursorX += box.w + BOX_PAD;
    bandHeight = Math.max(bandHeight, box.h);
    sceneRight = Math.max(sceneRight, box.x + box.w);
  }

  const width = Math.max(bandWidth, sceneRight + SCENE_MARGIN);
  const height = bandTop + bandHeight + SCENE_MARGIN;

  // Place stars within each box, then relax collisions on X.
  const stars: Star[] = [];
  const constellations: Constellation[] = [];

  for (const box of boxes) {
    const boxLeft = box.x + BOX_INNER_PAD;
    const boxTop = box.y + BOX_INNER_PAD + LABEL_H;
    const boxInnerW = box.w - BOX_INNER_PAD * 2;
    const boxInnerH = box.h - BOX_INNER_PAD * 2 - LABEL_H;

    const local: Star[] = box.albums.map((a) => {
      const r = starRadius(a.id);
      const x = boxLeft + seededRng('x:' + a.id)() * boxInnerW;
      const y = boxTop + (1 - yearFrac(a.year, minYear, maxYear)) * boxInnerH;
      return {
        albumId: a.id,
        x,
        y,
        r,
        coverArtKey: a.coverArtKey,
        artist: a.artist,
        name: a.name,
        year: a.year,
      };
    });

    relaxX(local, boxLeft, boxLeft + boxInnerW);

    // Constellation polyline order: by year (then id) so it reads chronologically.
    const ordered = [...local].sort(
      (s1, s2) => (s1.year ?? -Infinity) - (s2.year ?? -Infinity) || s1.albumId.localeCompare(s2.albumId),
    );

    constellations.push({
      genre: box.genre,
      label: box.label,
      x: box.x,
      y: box.y,
      w: box.w,
      h: box.h,
      starIds: ordered.map((s) => s.albumId),
    });

    for (const s of local) stars.push(s);
  }

  return { stars, constellations, width, height, minYear, maxYear, albumSetHash };
}

/**
 * Deterministic collision relaxation: nudge overlapping stars apart on X only
 * (preserving each star's Y, which encodes its year). Uses a fixed grid bucket so
 * cost stays ~O(n) and the result is identical across reloads.
 */
function relaxX(stars: Star[], minX: number, maxX: number): void {
  if (stars.length < 2) return;
  const cell = MIN_DIST;
  for (let iter = 0; iter < RELAX_ITERS; iter++) {
    const grid = new Map<string, number[]>();
    const keyOf = (x: number, y: number) =>
      Math.floor(x / cell) + ':' + Math.floor(y / cell);
    for (let i = 0; i < stars.length; i++) {
      const k = keyOf(stars[i].x, stars[i].y);
      const arr = grid.get(k);
      if (arr) arr.push(i);
      else grid.set(k, [i]);
    }
    for (let i = 0; i < stars.length; i++) {
      const a = stars[i];
      const gx = Math.floor(a.x / cell);
      const gy = Math.floor(a.y / cell);
      for (let dx = -1; dx <= 1; dx++) {
        for (let dy = -1; dy <= 1; dy++) {
          const neigh = grid.get(gx + dx + ':' + (gy + dy));
          if (!neigh) continue;
          for (const j of neigh) {
            if (j <= i) continue;
            const b = stars[j];
            const ddx = b.x - a.x;
            const ddy = b.y - a.y;
            const dist = Math.hypot(ddx, ddy);
            if (dist >= MIN_DIST || dist === 0) {
              if (dist === 0) {
                // Identical spot: deterministic tie-break by id.
                const push = a.albumId < b.albumId ? -1 : 1;
                a.x -= push;
                b.x += push;
              }
              continue;
            }
            const overlap = (MIN_DIST - dist) / 2;
            // Move on X only; direction follows existing X delta (or id tie-break).
            const dir = ddx === 0 ? (a.albumId < b.albumId ? -1 : 1) : Math.sign(ddx);
            a.x -= dir * overlap;
            b.x += dir * overlap;
          }
        }
      }
    }
    // Clamp back into the box width.
    for (const s of stars) {
      if (s.x < minX) s.x = minX;
      else if (s.x > maxX) s.x = maxX;
    }
  }
}
