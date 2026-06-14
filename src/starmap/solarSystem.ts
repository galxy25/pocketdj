// Solar-system layout for a single album: the cover is the sun, each song is a
// planet orbiting it. Pure geometry (renderer-agnostic) — the static 2D SVG view
// and any future animated/3D renderer share these {orbit, r, angle} values.
import type { AlbumItem, SongItem } from '../types/model';
import type { Planet, SolarSystem } from '../types/starmap';
import { seededRng } from '../lib/prng';

const SUN_R = 56; // visual radius of the sun (cover) — informs the innermost orbit
const RING_SPACING = 28; // distance between successive orbit rings
const FIRST_ORBIT = SUN_R + RING_SPACING; // track 1 sits here
const PLANET_R_MIN = 5;
const PLANET_R_MAX = 14;
const SCENE_PAD = 48; // breathing room past the outermost orbit

// Track-length window used to scale planet radius. Songs outside the window clamp.
const LEN_MIN_MS = 60_000; // 1:00
const LEN_MAX_MS = 360_000; // 6:00

function planetRadius(lengthMs: number | undefined): number {
  if (lengthMs == null || !isFinite(lengthMs)) return PLANET_R_MIN;
  const f = Math.max(0, Math.min(1, (lengthMs - LEN_MIN_MS) / (LEN_MAX_MS - LEN_MIN_MS)));
  return PLANET_R_MIN + f * (PLANET_R_MAX - PLANET_R_MIN);
}

export function computeSolarSystem(album: AlbumItem, songs: SongItem[]): SolarSystem {
  // Order by trackNumber so orbit assignment is stable; songs missing a track
  // number fall to the end (by id) so placement stays deterministic.
  const ordered = [...songs].sort(
    (a, b) =>
      (a.trackNumber ?? Number.MAX_SAFE_INTEGER) - (b.trackNumber ?? Number.MAX_SAFE_INTEGER) ||
      a.id.localeCompare(b.id),
  );

  const planets: Planet[] = ordered.map((song, idx) => {
    // Orbit grows with track position (track 1 innermost). Use the index so
    // duplicate / missing track numbers never collide on the same ring.
    const ring = song.trackNumber != null && isFinite(song.trackNumber) ? song.trackNumber : idx + 1;
    const orbit = FIRST_ORBIT + (ring - 1) * RING_SPACING;
    const angle = seededRng('a:' + song.id)() * Math.PI * 2;
    return {
      songId: song.id,
      trackNumber: song.trackNumber ?? idx + 1,
      name: song.name,
      orbit,
      r: planetRadius(song.lengthMs),
      angle,
      explicit: song.explicit,
      sentimentKeywords: song.sentimentKeywords ?? [],
    };
  });

  // Scene must fit the outermost orbit (+ its planet radius + padding).
  let maxReach = FIRST_ORBIT;
  for (const p of planets) maxReach = Math.max(maxReach, p.orbit + p.r);
  const size = (maxReach + SCENE_PAD) * 2;

  return {
    albumId: album.id,
    sunArtKey: album.coverArtKey,
    artist: album.artist,
    name: album.name,
    planets,
    size,
  };
}
