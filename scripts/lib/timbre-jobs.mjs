// Pure helpers for the CLOUD TIMBRE lane, factored out of rip-server.mjs so they can be unit
// tested. rip-server.mjs is an executable script — it listens on a port at import time — so
// anything a test needs to assert has to live here, not there.
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
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
    const kind = cloudKindFor({ source });
    songs.push(kind === 's3-cut' ? { id, key, kind } : { id, key });
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
  let analysed = 0; let outstanding = 0; let failed = 0; let oldest = null;
  for (const e of Object.values(manifest || {})) {
    if (!timbreKeyFor(e)) continue;
    if ((e.timbreVersion ?? 0) >= TIMBRE_VERSION) { e.timbrePermanent ? (failed += 1) : (analysed += 1); continue; }
    outstanding += 1;
    const at = e.rippedAt ?? e.ingestedAt ?? e.at ?? null;
    if (Number.isFinite(at) && (oldest == null || at < oldest)) oldest = at;
  }
  return { analysed, outstanding, failed, timbreVersion: TIMBRE_VERSION,
    oldestOutstandingAgeMs: oldest == null ? null : now - oldest };
}

// ── PROVENANCE: WHICH BYTES A VECTOR WAS MEASURED FROM ─────────────────────────────────────────
// Three input classes produce vectors in this corpus (timbre-batch.mjs's `kind`):
//   · s3-song   — the per-song digital rip.
//   · vinyl-cut — an ffmpeg STREAM COPY of the song's own window out of the raw album file on
//                 POCKETDJ_ANALOG_BASE. No re-encode; the raws are often AIFF/PCM.
//   · s3-cut    — the BURNED per-song cut mp3 on S3: a lossy re-encode of different bytes.
// s3-song and vinyl-cut are how the 15,489-vector corpus was measured (5,101 + 10,388). s3-cut is
// the cloud lane's only option for an analog song, because /Volumes/RipBurnMix is not on EC2.
//
// So for ONE analog song, `vinyl-cut` and `s3-cut` are not two runs of the same measurement —
// they are measurements of two different files, and the parity gate cannot speak for the pair
// (all 120 parity songs are s3-song). Mixing them inside one corpus is the mixed-calibration
// failure this lane exists to avoid, and it is worse than a stale corpus because nothing in the
// artifact records which axis-set a given row belongs to.
//
// RANK, therefore, is not recency: for a given song id a HIGHER-ranked src is never replaced by a
// lower-ranked one, whatever the timestamps say. Within one class, last-write-wins as before.
export const TIMBRE_SRC_RANK = { 's3-song': 2, 'vinyl-cut': 2, 's3-cut': 1 };
export const timbreSrcRank = (src) => TIMBRE_SRC_RANK[src] ?? 0;

/// The input class the CLOUD lane would use for a manifest entry. Single definition — buildTimbreBatches
/// stamps the job with it and the provenance gate compares against it.
export const cloudKindFor = (e) => (e && e.source === 'analog' ? 's3-cut' : 's3-song');

/// Pure: NDJSON result rows -> id -> {v, src, ok, permanent, atMs}, keeping the best row per id by
/// (rank, atMs). `permanent` rows count as measured: an engine that RAN and found nothing usable
/// must never wedge the queue re-running a song that can never succeed.
export function indexResultRows(rows) {
  const done = new Map();
  for (const r of rows || []) {
    if (!r || !r.id || r.v !== TIMBRE_VERSION || !(r.ok || r.permanent)) continue;
    const row = { v: r.v, src: r.src || null, ok: !!r.ok, permanent: !!r.permanent,
      atMs: Number.isFinite(r.atMs) ? r.atMs : 0 };
    const cur = done.get(r.id);
    if (cur) {
      const dr = timbreSrcRank(row.src) - timbreSrcRank(cur.src);
      if (dr < 0 || (dr === 0 && row.atMs <= cur.atMs)) continue;
    }
    done.set(r.id, row);
  }
  return done;
}

/// RECONCILE the manifest against the durable result corpus.
///
/// The manifest stamp is the ongoing record of "analysed", but it is NOT where the existing
/// corpus lives: the warm-batch driver's durable state has always been <results>/*.ndjson, and
/// 15,489 vectors were measured before any stamp existed. Without this, every one of those songs
/// reads as outstanding forever — the sweep re-runs them on EC2 500 at a time, /health reports a
/// permanent five-thousand-song backlog, and the staleness warning cries wolf nightly.
///
/// Stamps `timbrePermanent` rather than pretending a failed song has a vector, so timbreHealth
/// can report `failed` separately from `analysed` instead of overcounting coverage.
/// Returns counts; mutates entries in place (the caller saves).
export function reconcileTimbreStamps(manifest, doneRows, now = Date.now()) {
  let stamped = 0; let failed = 0;
  const bySrc = {};
  for (const [id, row] of doneRows || []) {
    const e = manifest && manifest[id];
    if (!e || !timbreKeyFor(e)) continue;
    if ((e.timbreVersion ?? 0) >= TIMBRE_VERSION) continue;
    e.timbreVersion = row.v;
    e.timbreAt = row.atMs || now;
    if (row.src) e.timbreSrc = row.src;
    if (row.ok) { stamped += 1; bySrc[row.src || '?'] = (bySrc[row.src || '?'] || 0) + 1; }
    else { e.timbrePermanent = true; failed += 1; }
  }
  return { stamped, failed, bySrc };
}

/// THE PROVENANCE GATE. True when enqueueing this entry on the cloud lane would REPLACE a vector
/// measured from different bytes. Consulted even under `force`, because the whole point of a
/// forced re-analysis is a re-measurement of the SAME audio at a new calibration — not a silent
/// swap of the audio underneath it. `allowSrcChange` is the deliberate operator opt-out.
export function crossesTimbreProvenance(e, doneRow, { allowSrcChange = false } = {}) {
  if (allowSrcChange || !doneRow || !doneRow.ok || !doneRow.src) return false;
  return timbreSrcRank(cloudKindFor(e)) < timbreSrcRank(doneRow.src);
}

/// Read the durable result corpus off disk into the index above. Local shard-N.ndjson and the
/// cloud's cloud.ndjson alike — both are *.ndjson in the same dir, which is exactly why the cloud
/// lane writes there. Same loader semantics as timbre-batch.mjs's loadDone() and fold-timbre.mjs's
/// readResults(); a torn tail line from a crash is skipped and that song simply re-runs.
export function readResultRows(dir) {
  if (!dir || !existsSync(dir)) return new Map();
  const rows = [];
  for (const f of readdirSync(dir).sort()) {
    if (!f.endsWith('.ndjson')) continue;
    for (const line of readFileSync(join(dir, f), 'utf8').split('\n')) {
      if (!line.trim()) continue;
      try { rows.push(JSON.parse(line)); } catch { /* torn tail line */ }
    }
  }
  return indexResultRows(rows);
}
