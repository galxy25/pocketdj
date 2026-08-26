// Pure helpers for the CLOUD TIMBRE lane, factored out of rip-server.mjs so they can be unit
// tested. rip-server.mjs is an executable script — it listens on a port at import time — so
// anything a test needs to assert has to live here, not there.
import { TIMBRE_VERSION } from './audio-analyze.mjs';

/// The audio a timbre vector would be measured from. Analog songs analyse their per-song CUT,
/// never the shared album file — every track on a side shares one raw file, and the cut is what
/// keeps them from sharing one vector.
export const timbreKeyFor = (e) => (e && (e.source === 'analog' ? e.cutKey : e.key)) || null;

/// LAYER 1 of idempotence: a song already analysed at the current version is never enqueued, so
/// "add a song that is already analysed" is a no-op before a single byte moves.
export const wantTimbre = (e) => !!timbreKeyFor(e) && ((e?.timbreVersion ?? 0) < TIMBRE_VERSION);

/// Chunk [id, key, source] triples into SQS job bodies. Deduped by song id, stable order,
/// bounded batch size — adding a 500-song collection must become ~10 messages, not 500
/// uncoordinated jobs. `dedup:false` rides along only on a FORCED re-analysis: without it the
/// worker's skip-if-exists would re-stamp a stale-version sidecar as current and the song could
/// never be regenerated (the offloadStem/offloadLyrics contract, mirrored).
export function buildTimbreBatches(entries, { size = 50, dedup = true, batchId } = {}) {
  const seen = new Set();
  const songs = [];
  for (const [id, key, source] of entries || []) {
    if (!id || !key || seen.has(id)) continue;
    seen.add(id);
    songs.push(source === 'analog' ? { id, key, kind: 's3-cut' } : { id, key });
  }
  const out = [];
  const n = Math.max(1, size);
  for (let i = 0; i < songs.length; i += n) {
    out.push({
      kind: 'timbre', v: 1,
      batchId: batchId ? `${batchId}_${(i / n).toString(36)}` : `tb_${Date.now()}_${(i / n).toString(36)}`,
      songs: songs.slice(i, i + n),
      ...(dedup ? {} : { dedup: false }),
    });
  }
  return out;
}

/// The staleness signal. A corpus that stops growing is invisible without a number that says so —
/// public/timbre.json froze for 14 days and nothing anywhere reported it.
export function timbreHealth(manifest, now = Date.now()) {
  let analysed = 0; let outstanding = 0; let oldest = null;
  for (const e of Object.values(manifest || {})) {
    if (!timbreKeyFor(e)) continue;
    if ((e.timbreVersion ?? 0) >= TIMBRE_VERSION) { analysed += 1; continue; }
    outstanding += 1;
    const at = e.rippedAt ?? e.ingestedAt ?? e.at ?? null;
    if (Number.isFinite(at) && (oldest == null || at < oldest)) oldest = at;
  }
  return { analysed, outstanding, timbreVersion: TIMBRE_VERSION,
    oldestOutstandingAgeMs: oldest == null ? null : now - oldest };
}
