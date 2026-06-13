// The MANIFEST — the index doubling as a record of what each sub-indexer has done.
//
// The pipeline is a chain of stages: metadata -> lyrics -> sentiment -> [audio].
// Each album record carries a `stages` map giving the per-item, per-stage status,
// so any stage can be re-run SELECTIVELY (process only the items where its stage
// is pending/failed) and we always know "how far each indexer got".
//
//   record.stages = {
//     metadata:  { status:'done'|'unmatched', at, source },
//     lyrics:    { status:'done'|'pending'|'failed', at, found },   // found = #songs w/ lyrics
//     sentiment: { status:'done'|'pending'|'failed', at, tagged },  // tagged = #songs tagged
//     audio:     { status:'pending' },                              // future (needs the audio file)
//   }
//
// Pure helpers (no network). The manifest persists as JSONL keyed by candidateIndex.

import { readFileSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { join } from 'node:path';

export const STAGES = ['metadata', 'lyrics', 'sentiment', 'audio'];

// In the STREAMING pipeline each stage owns an append-only file; the index/manifest
// is derived from FILE MEMBERSHIP (which stage's file contains the album) plus the
// carried-forward data. This is the source of truth for `status` and `merge`.
const STAGE_FILES = [
  ['metadata', 'enriched.jsonl'],
  ['lyrics', 'lyrics.jsonl'],
  ['sentiment', 'sentiment.jsonl'],
];

export function buildFromStages(dir) {
  const map = new Map();
  for (const [stage, fname] of STAGE_FILES) {
    for (const r of readJsonl(join(dir, fname))) {
      const ci = r.candidateIndex;
      if (ci == null) continue;
      const prev = map.get(ci);
      const merged = { ...(prev || {}), ...r }; // later stage carries forward + supersedes
      merged.stages = { ...(prev?.stages || {}) };
      if (stage === 'metadata') {
        merged.stages.metadata = { status: r.status === 'matched' ? 'done' : 'unmatched' };
      } else if (stage === 'lyrics') {
        merged.stages.lyrics = { status: 'done', found: (r.tracks || []).filter((t) => t.lyricsStatus === 'found').length };
      } else if (stage === 'sentiment') {
        merged.stages.sentiment = {
          status: 'done',
          tagged: (r.tracks || []).filter((t) => (t.sentimentKeywords || []).length && t.sentimentSource !== 'failed').length,
        };
      }
      map.set(ci, merged);
    }
  }
  return map;
}

export function readJsonl(path) {
  if (!existsSync(path)) return [];
  const out = [];
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      /* skip partial line */
    }
  }
  return out;
}

/** Load the manifest as a Map keyed by candidateIndex. */
export function loadManifest(path) {
  const map = new Map();
  for (const r of readJsonl(path)) map.set(r.candidateIndex, r);
  return map;
}

/** Persist atomically (write temp + rename), sorted by candidateIndex. */
export function saveManifest(path, map) {
  const recs = [...map.values()].sort((a, b) => (a.candidateIndex ?? 0) - (b.candidateIndex ?? 0));
  const tmp = path + '.tmp';
  writeFileSync(tmp, recs.map((r) => JSON.stringify(r)).join('\n') + '\n');
  renameSync(tmp, path);
}

function stamp(rec, stage, status, extra = {}) {
  rec.stages = rec.stages || {};
  rec.stages[stage] = { status, at: new Date().toISOString(), ...extra };
}

/**
 * Fold a stage's output records into the manifest by candidateIndex (merging
 * data fields), and stamp `stages[stage]`. `deriveStatus(rec)` returns
 * {status, extra} for the stamp. New records (metadata stage) are added.
 */
export function foldStage(map, records, stage, deriveStatus) {
  for (const r of records) {
    const ci = r.candidateIndex;
    if (ci == null) continue;
    const prev = map.get(ci);
    // r carries the full record forward; keep prev.stages, take r's data.
    const merged = { ...(prev || {}), ...r };
    if (prev?.stages) merged.stages = { ...prev.stages, ...(r.stages || {}) };
    const { status, extra } = deriveStatus(merged);
    stamp(merged, stage, status, extra);
    map.set(ci, merged);
  }
  return map;
}

/** Items whose `stage` is not yet 'done' (or 'unmatched' for metadata). */
export function pendingForStage(map, stage, { includeUnmatched = false } = {}) {
  const out = [];
  for (const rec of map.values()) {
    const st = rec.stages?.[stage]?.status;
    if (st === 'done') continue;
    if (st === 'unmatched' && !includeUnmatched) continue;
    out.push(rec);
  }
  return out;
}

/** Reset a stage's status for items matching `predicate` -> they become pending again. */
export function resetStage(map, stage, predicate = () => true) {
  let n = 0;
  for (const rec of map.values()) {
    if (rec.stages?.[stage] && predicate(rec)) {
      delete rec.stages[stage];
      n++;
    }
  }
  return n;
}

/** Per-stage coverage counts + a few headline numbers. */
export function statusReport(map) {
  const total = map.size;
  const perStage = {};
  for (const s of STAGES) perStage[s] = { done: 0, pending: 0, other: 0 };
  let albumsMatched = 0;
  let songs = 0;
  let songsWithLyrics = 0;
  let songsTagged = 0;
  for (const rec of map.values()) {
    if (rec.status === 'matched') albumsMatched++;
    for (const t of rec.tracks || []) {
      songs++;
      if (t.lyricsStatus === 'found') songsWithLyrics++;
      if (t.sentimentSource && t.sentimentSource !== 'failed' && (t.sentimentKeywords || []).length) songsTagged++;
    }
    for (const s of STAGES) {
      const st = rec.stages?.[s]?.status;
      if (st === 'done') perStage[s].done++;
      else if (!st || st === 'pending') perStage[s].pending++;
      else perStage[s].other++;
    }
  }
  return { total, albumsMatched, songs, songsWithLyrics, songsTagged, perStage };
}
