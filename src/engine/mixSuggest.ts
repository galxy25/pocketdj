// Mix-suggestion engine — a RESERVED-but-implemented seam.
//
// For a given song, rank OTHER songs to mix it with. Two-tier strategy:
//   PRIMARY  — pocket co-members: every song that shares a pocket with the seed
//              (curated harmonic similarity), ranked by the blended
//              harmonicDistance ascending. basis 'pocket', pocketId set.
//   FALLBACK — when fewer than `limit` pocket co-members exist, fill from the
//              broad candidate pool by raw bpm+key closeness
//              (camelotDistance + bpmDistance, nulls skipped). basis 'bpm-key'.
//
// Each result is a self-contained MixSuggestion SNAPSHOT (artist/name/bpm/camelot
// frozen at compute time) so a setlist reads standalone even if the catalog or
// pockets later change. Pocket matches always rank ahead of bpm-key fills.
//
// PURE + DETERMINISTIC: no mutation of inputs, no DB/React/network, no randomness.
// All similarity math delegates to ./harmonics (single source of truth). Only the
// top-level realize op logs; this seam emits NO transcript lines (primitives are
// silent) — it is invoked from within realize/UI wiring, not as a standalone op.

import type { SongItem } from '../types/model';
import type { MixSuggestion, Pocket, SetlistTrack } from '../types/collections';
import { keyToCamelot } from '../lib/camelot';
import { camelotDistance, bpmDistance, harmonicDistance } from './harmonics';
import type { HarmonicWeights } from './harmonics';

/** Default number of mix suggestions to return per seed song. */
const DEFAULT_LIMIT = 5;

export interface MixCtx {
  /** Catalog lookup: SongItem.id -> SongItem (resolves pocket co-member ids). */
  songsById: Map<string, SongItem>;
  /** All pockets to scan for shared membership with the seed. */
  pockets: Pocket[];
  /** Broad candidate pool for the bpm+key fallback fill. */
  candidates: SongItem[];
}

/**
 * The best Camelot code we can show for a song snapshot: prefer the explicit
 * `camelot` field, else derive it from the musical `key` (so a song with a key
 * but no Camelot still snapshots a usable wheel code), else null.
 */
function snapshotCamelot(s: SongItem): string | null {
  return s.camelot ?? keyToCamelot(s.key) ?? null;
}

/** Freeze a candidate song into a MixSuggestion snapshot. */
function toSuggestion(
  s: SongItem,
  basis: MixSuggestion['basis'],
  score: number,
  pocketId?: string,
): MixSuggestion {
  return {
    songId: s.id,
    artist: s.artist,
    name: s.name,
    bpm: s.bpm,
    camelot: snapshotCamelot(s),
    lengthMs: s.lengthMs,
    basis,
    ...(pocketId !== undefined ? { pocketId } : {}),
    score,
  };
}

/**
 * Raw bpm+key closeness used by the fallback tier: camelotDistance + bpmDistance,
 * each DROPPED when null (missing audio) so a partial-audio song still ranks on
 * whatever axis it has. Returns null only when BOTH axes are unavailable — such a
 * candidate is unrankable and excluded from the bpm-key fill.
 */
function bpmKeyDistance(a: SongItem, b: SongItem): number | null {
  const cam = camelotDistance(a.camelot, b.camelot); // number | null
  const bpm = bpmDistance(a.bpm, b.bpm); // number | null
  if (cam == null && bpm == null) return null;
  return (cam ?? 0) + (bpm ?? 0);
}

/**
 * Rank OTHER songs to mix `song` with.
 *
 * PRIMARY tier — pocket co-members: for every pocket that lists `song.id` in its
 * `songIds`, gather the other direct song members (resolved via ctx.songsById),
 * ranked by harmonicDistance(song, other) ascending (lower = tighter). Each gets
 * basis 'pocket' and the pocketId of the FIRST pocket that surfaced it. A song
 * that co-occurs in several pockets is suggested ONCE (first occurrence wins;
 * scanning pockets in array order keeps this deterministic).
 *
 * FALLBACK tier — when the pocket tier yields fewer than `limit`, fill the
 * remainder from ctx.candidates by raw bpm+key closeness (bpmKeyDistance),
 * skipping the seed, anything already suggested, and candidates with no usable
 * bpm/key axis. basis 'bpm-key', no pocketId.
 *
 * Excludes `song` itself and de-dupes by songId. Returns up to `limit` results,
 * POCKET matches first (each tier internally sorted by ascending score), then the
 * bpm-key fills. Pure + deterministic — ties resolve to encounter order via a
 * STABLE sort, and we never mutate inputs.
 */
export function suggestMixes(
  song: SongItem,
  ctx: MixCtx,
  limit: number = DEFAULT_LIMIT,
  weights?: HarmonicWeights,
): MixSuggestion[] {
  if (!Number.isFinite(limit) || limit <= 0) return [];

  // De-dupe across tiers (and guard against the seed leaking in).
  const seen = new Set<string>([song.id]);

  // --- PRIMARY: pocket co-members ------------------------------------------
  const pocketHits: MixSuggestion[] = [];
  for (const pocket of ctx.pockets) {
    if (!pocket.songIds.includes(song.id)) continue;
    for (const memberId of pocket.songIds) {
      if (seen.has(memberId)) continue;
      const member = ctx.songsById.get(memberId);
      if (!member) continue; // unresolved id — skip, never throw
      seen.add(memberId);
      const score = harmonicDistance(song, member, weights);
      pocketHits.push(toSuggestion(member, 'pocket', score, pocket.id));
    }
  }
  // Stable sort by tightness (lower harmonicDistance first); ties keep
  // encounter order, which is deterministic given the input arrays.
  pocketHits.sort((a, b) => (a.score ?? 0) - (b.score ?? 0));

  // Pocket matches always come first; cap the whole result at `limit`.
  const results = pocketHits.slice(0, limit);
  if (results.length >= limit) return results;

  // --- FALLBACK: raw bpm+key closeness from the broad pool -----------------
  const fills: MixSuggestion[] = [];
  for (const cand of ctx.candidates) {
    if (seen.has(cand.id)) continue;
    const dist = bpmKeyDistance(song, cand);
    if (dist == null) continue; // unrankable (no bpm AND no key) — skip
    seen.add(cand.id);
    fills.push(toSuggestion(cand, 'bpm-key', dist));
  }
  fills.sort((a, b) => (a.score ?? 0) - (b.score ?? 0));

  for (const f of fills) {
    if (results.length >= limit) break;
    results.push(f);
  }
  return results;
}

/**
 * Populate `.mixSuggestions` on each setlist track (for later UI wiring).
 *
 * Returns COPIES of the input tracks — the originals are NEVER mutated. For each
 * track we resolve its seed SongItem from ctx.songsById and attach
 * suggestMixes(seed, …); a track whose songId is missing from the catalog is
 * passed through as a shallow copy with no suggestions (we don't fabricate one).
 *
 * Pure + deterministic. `limit` defaults to suggestMixes's own default.
 */
export function suggestMixesForSetlist(
  tracks: SetlistTrack[],
  ctx: MixCtx,
  limit: number = DEFAULT_LIMIT,
): SetlistTrack[] {
  return tracks.map((track) => {
    const seed = ctx.songsById.get(track.songId);
    if (!seed) return { ...track };
    return { ...track, mixSuggestions: suggestMixes(seed, ctx, limit) };
  });
}
