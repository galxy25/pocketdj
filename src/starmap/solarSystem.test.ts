import { describe, it, expect } from 'vitest';
import { computeSolarSystem } from './solarSystem';
import type { AlbumItem, SongItem } from '../types/model';

function album(over: Partial<AlbumItem> & { id: string }): AlbumItem {
  return {
    sourceId: 's1',
    type: 'album',
    createdAt: 0,
    updatedAt: 0,
    artist: 'Artist',
    name: 'Name',
    trackIds: [],
    ...over,
  };
}
function song(over: Partial<SongItem> & { id: string }): SongItem {
  return {
    sourceId: 's1',
    type: 'song',
    createdAt: 0,
    updatedAt: 0,
    artist: 'Artist',
    name: 'Name',
    sentimentKeywords: [],
    explicit: false,
    bpm: null,
    key: null,
    ...over,
  };
}

const FIRST_ORBIT = 84; // SUN_R(56) + RING_SPACING(28)
const RING_SPACING = 28;

describe('computeSolarSystem — album mapping', () => {
  it('carries album identity onto the system', () => {
    const a = album({ id: 'alb1', coverArtKey: 'ck', artist: 'X', name: 'Y' });
    const sys = computeSolarSystem(a, []);
    expect(sys.albumId).toBe('alb1');
    expect(sys.sunArtKey).toBe('ck');
    expect(sys.artist).toBe('X');
    expect(sys.name).toBe('Y');
  });
});

describe('computeSolarSystem — orbit / planet ordering', () => {
  it('orders planets by trackNumber regardless of input order', () => {
    const a = album({ id: 'a' });
    const songs = [
      song({ id: 's3', trackNumber: 3 }),
      song({ id: 's1', trackNumber: 1 }),
      song({ id: 's2', trackNumber: 2 }),
    ];
    const sys = computeSolarSystem(a, songs);
    expect(sys.planets.map((p) => p.songId)).toEqual(['s1', 's2', 's3']);
  });

  it('orbit grows by RING_SPACING per track (track 1 innermost)', () => {
    const a = album({ id: 'a' });
    const sys = computeSolarSystem(a, [
      song({ id: 's1', trackNumber: 1 }),
      song({ id: 's2', trackNumber: 2 }),
      song({ id: 's3', trackNumber: 3 }),
    ]);
    expect(sys.planets.map((p) => p.orbit)).toEqual([
      FIRST_ORBIT,
      FIRST_ORBIT + RING_SPACING,
      FIRST_ORBIT + 2 * RING_SPACING,
    ]);
  });

  it('songs missing a trackNumber sort to the end (by id) and get sequential fallback numbers/orbits', () => {
    const a = album({ id: 'a' });
    const sys = computeSolarSystem(a, [song({ id: 'b' }), song({ id: 'a-id' })]);
    // tie-break by id: 'a-id' before 'b'
    expect(sys.planets.map((p) => p.songId)).toEqual(['a-id', 'b']);
    // fallback trackNumber = idx + 1
    expect(sys.planets.map((p) => p.trackNumber)).toEqual([1, 2]);
    expect(sys.planets.map((p) => p.orbit)).toEqual([FIRST_ORBIT, FIRST_ORBIT + RING_SPACING]);
  });

  it('honors the explicit trackNumber for the ring even with gaps', () => {
    const a = album({ id: 'a' });
    const sys = computeSolarSystem(a, [song({ id: 's5', trackNumber: 5 })]);
    expect(sys.planets[0].orbit).toBe(FIRST_ORBIT + 4 * RING_SPACING);
    expect(sys.planets[0].trackNumber).toBe(5);
  });
});

describe('computeSolarSystem — planet radius scales with length (clamped)', () => {
  const a = album({ id: 'a' });
  const rOf = (lengthMs?: number) =>
    computeSolarSystem(a, [song({ id: 's', lengthMs })]).planets[0].r;

  it('clamps to min below the window and at exactly the min length', () => {
    expect(rOf(0)).toBe(5); // below window
    expect(rOf(60_000)).toBe(5); // exactly LEN_MIN -> f=0 -> min
  });

  it('clamps to max at / above the window', () => {
    expect(rOf(360_000)).toBe(14); // exactly LEN_MAX -> f=1 -> max
    expect(rOf(999_999)).toBe(14); // above window
  });

  it('interpolates in the middle of the window', () => {
    // midpoint of [60000,360000] is 210000 -> f=0.5 -> 5 + 0.5*9 = 9.5
    expect(rOf(210_000)).toBeCloseTo(9.5, 6);
  });

  it('undefined / non-finite length -> min radius', () => {
    expect(rOf(undefined)).toBe(5);
    expect(rOf(Infinity)).toBe(5);
  });
});

describe('computeSolarSystem — angle is deterministic per song id', () => {
  it('same song id yields the same angle across runs, in [0, 2π)', () => {
    const a = album({ id: 'a' });
    const s = song({ id: 'fixed-song', trackNumber: 1 });
    const angle1 = computeSolarSystem(a, [s]).planets[0].angle;
    const angle2 = computeSolarSystem(a, [s]).planets[0].angle;
    expect(angle1).toBe(angle2);
    expect(angle1).toBeGreaterThanOrEqual(0);
    expect(angle1).toBeLessThan(Math.PI * 2);
  });

  it('different song ids generally yield different angles', () => {
    const a = album({ id: 'a' });
    const angA = computeSolarSystem(a, [song({ id: 'one', trackNumber: 1 })]).planets[0].angle;
    const angB = computeSolarSystem(a, [song({ id: 'two', trackNumber: 1 })]).planets[0].angle;
    expect(angA).not.toBe(angB);
  });
});

describe('computeSolarSystem — passthrough fields + scene size', () => {
  it('copies explicit + sentimentKeywords (defaulting to [])', () => {
    const a = album({ id: 'a' });
    const sys = computeSolarSystem(a, [
      song({ id: 's1', trackNumber: 1, explicit: true, sentimentKeywords: ['love'] }),
    ]);
    expect(sys.planets[0].explicit).toBe(true);
    expect(sys.planets[0].sentimentKeywords).toEqual(['love']);
  });

  it('empty album -> size accommodates just the first orbit ring (no planets)', () => {
    const a = album({ id: 'a' });
    const sys = computeSolarSystem(a, []);
    expect(sys.planets).toEqual([]);
    // size = (FIRST_ORBIT + SCENE_PAD(48)) * 2
    expect(sys.size).toBe((FIRST_ORBIT + 48) * 2);
  });

  it('size grows to fit the outermost orbit + its planet radius + padding', () => {
    const a = album({ id: 'a' });
    const sys = computeSolarSystem(a, [
      song({ id: 's1', trackNumber: 1, lengthMs: 360_000 }),
      song({ id: 's5', trackNumber: 5, lengthMs: 360_000 }),
    ]);
    const outerOrbit = FIRST_ORBIT + 4 * RING_SPACING;
    const outerPlanetR = 14;
    expect(sys.size).toBe((outerOrbit + outerPlanetR + 48) * 2);
  });
});
