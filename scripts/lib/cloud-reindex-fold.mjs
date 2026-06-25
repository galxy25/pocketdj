// cloud-reindex-fold — the PURE fold that re-indexes the ANALOG catalog
// (public/current-index.json) from Apple Music + the rips manifest, with cloud values
// taking PRECEDENCE per field. Extracted from scripts/reindex-cloud-analysis.mjs so BOTH
// the offline CLI tool AND the rip-server (in-process, ITEM 10) share ONE implementation.
//
// Contract (unchanged from the CLI):
//   • EXACT Apple Music match only (findInLibrary match === 'exact'). A loose/ambiguous
//     match NEVER overwrites (a wrong length/key is worse than the analog estimate).
//   • LENGTH: cloud "Total Time" (ms) overrides analog length.
//   • BPM/KEY/CAMELOT: opportunistic, from a CLOUD manifest entry (source 'digital' &&
//     analyzed === true) — either this song's OWN id (a cloud rip of the vinyl track) or
//     the derived Apple-Music songId for the matched library entry. manifest.musicalKey
//     -> catalog key.
//   • IDEMPOTENT: the output is a deterministic function of (catalog, library, manifest).
//     Each touched song carries a `cloudReindex` provenance stamp (overwritten each run).
//
// foldCloudReindex(index, lib, manifest, {limit}) MUTATES `index` in place and returns a
// `report`. It does NOT read/write any files, fetch S3, or stamp wall-clock onto the
// catalog (the caller owns I/O + the index.manifest.cloudReindex stamp) — that keeps the
// fold byte-idempotent and safe to run inside the rip-server analysis lock.
import { createHash } from 'node:crypto';
import { findInLibrary } from './am-match.mjs';

const sha1 = (s) => createHash('sha1').update(s).digest('hex');

// Apple Music (Local) namespace — must match scripts/index-apple-music.mjs (ns =
// `digital|${sourceName}`; songId = 'sng_' + sha1(`${ns}|${persistentID}`)[:12]).
export const AM_SOURCE_NAME = 'Apple Music (Local)';
export const amSongId = (persistentID) =>
  'sng_' + sha1(`digital|${AM_SOURCE_NAME}|${persistentID}`).slice(0, 12);

// A manifest entry is a CLOUD source of truth only if it is a digital rip that has been
// analyzed (analog entries deliberately keep the catalog's suspect bpm/key).
export const isCloudEntry = (e) => !!e && e.source === 'digital' && e.analyzed === true;

export function emptyReport() {
  return {
    matched: 0,
    matchExact: 0,
    matchLoose: 0,      // counted but NOT applied
    matchNone: 0,
    lengthUpdated: 0,
    lengthAdded: 0,     // rows that had no length before
    bpmKeyUpdatedFromCloud: 0,
    cloudEntriesUsed: 0,
    matchedNoValue: 0,  // exact AM match but nothing to write (no Total Time, no cloud rip)
    unmatched: 0,       // no exact AM match (loose + none)
    changed: 0,         // songs whose length/bpm/key/camelot value actually changed this run
    lengthDelta: { gt60s: 0, gt30s: 0, le30s: 0, newlyAdded: 0 },
    lengthDeltaGt60sSamples: [],
    samples: [],
  };
}

// Fold cloud values into `index.songs` (MUTATES index). `lib` is an indexLibrary() result;
// `manifest` is the rips manifest object (songId -> entry). Returns a report. opts.limit>0
// only considers the first N songs (smoke). Does NOT touch index.manifest (caller stamps).
export function foldCloudReindex(index, lib, manifest, opts = {}) {
  const songs = index.songs || [];
  const limit = opts.limit > 0 ? Math.min(opts.limit, songs.length) : songs.length;
  const report = emptyReport();

  for (let i = 0; i < limit; i++) {
    const song = songs[i];
    const r = findInLibrary(lib, song.artist, song.name);

    if (r.match !== 'exact') {
      if (r.match === 'loose') report.matchLoose++; else report.matchNone++;
      report.unmatched++;
      continue;
    }
    report.matched++;
    report.matchExact++;

    const before = { length: song.length ?? null, bpm: song.bpm ?? null, key: song.key ?? null, camelot: song.camelot ?? null };
    // Provenance carries NO wall-clock so the catalog output is byte-idempotent.
    const prov = { persistentID: r.hit.persistentID || null, fields: [] };
    let changed = false;

    // LENGTH — cloud (Apple Music Total Time) overrides analog length. Guard on a real ms
    // value (a library entry can lack Total Time for streaming-only tracks).
    if (r.hit.lengthMs != null && Number.isFinite(r.hit.lengthMs) && r.hit.lengthMs > 0) {
      const had = song.length != null;
      const prevLength = song.length;
      if (song.length !== r.hit.lengthMs) {
        song.length = r.hit.lengthMs;
        report.lengthUpdated++;
        changed = true;
        if (!had) report.lengthAdded++;
        if (had) {
          const deltaS = Math.abs(r.hit.lengthMs - prevLength) / 1000;
          if (deltaS > 60) {
            report.lengthDelta.gt60s++;
            if (report.lengthDeltaGt60sSamples.length < 200) {
              report.lengthDeltaGt60sSamples.push({
                id: song.id, artist: song.artist, name: song.name,
                amTitle: r.hit.title, persistentID: r.hit.persistentID || null,
                beforeMs: prevLength, afterMs: r.hit.lengthMs, deltaS: Math.round(deltaS),
              });
            }
          } else if (deltaS > 30) report.lengthDelta.gt30s++;
          else report.lengthDelta.le30s++;
        } else {
          report.lengthDelta.newlyAdded++;
        }
      } else if (!had) {
        song.length = r.hit.lengthMs;
      }
      prov.length = r.hit.lengthMs;
      prov.fields.push('length');
    }

    // BPM/KEY/CAMELOT — opportunistic, from a digital+analyzed cloud rip. Precedence: (a) a
    // cloud rip of THIS song itself (manifest keyed by the song's OWN id); (b) a separately-
    // ripped DIGITAL copy of the matched Apple Music track (derived am songId).
    const derivedId = r.hit.persistentID ? amSongId(r.hit.persistentID) : null;
    const cloudSongId = isCloudEntry(manifest[song.id]) ? song.id
      : (derivedId && isCloudEntry(manifest[derivedId]) ? derivedId : null);
    if (cloudSongId) {
      const e = manifest[cloudSongId];
      let touched = false;
      if (e.bpm != null) { if (song.bpm !== e.bpm) changed = true; song.bpm = e.bpm; prov.fields.push('bpm'); touched = true; }
      if (e.musicalKey != null) { if (song.key !== e.musicalKey) changed = true; song.key = e.musicalKey; prov.fields.push('key'); touched = true; }
      if (e.camelot != null) { if (song.camelot !== e.camelot) changed = true; song.camelot = e.camelot; prov.fields.push('camelot'); touched = true; }
      if (touched) {
        report.bpmKeyUpdatedFromCloud++;
        report.cloudEntriesUsed++;
        prov.cloudSongId = cloudSongId;
      }
    }

    if (prov.fields.length) {
      song.cloudReindex = prov; // idempotent provenance stamp (overwritten each run)
      if (changed) report.changed++;
      if (report.samples.length < 25) {
        report.samples.push({
          id: song.id, artist: song.artist, name: song.name, fields: prov.fields, before,
          after: { length: song.length ?? null, bpm: song.bpm ?? null, key: song.key ?? null, camelot: song.camelot ?? null },
          persistentID: prov.persistentID,
        });
      }
    } else {
      report.matchedNoValue++; // exact match but nothing to write
    }
  }

  return report;
}
