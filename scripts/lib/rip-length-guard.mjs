// CAPTURE LENGTH GUARD — reject under/over-ripped Apple Music captures before they are
// uploaded, registered in the manifest, or fed to the stem/analysis/lyrics/timbre offloads.
//
// Why: a real-time capture ends when Music.app stops playing. A playback cascade (another
// device/queue taking over, an interruption) stops it early, and the rip skill reads that as
// "track ended" — so a 54 s fragment of a 221 s song was accepted as `ok`, uploaded, and
// every derived artifact (stems, beat grid, waveform, lyrics, timbre) was computed from it.
//
// Pure decisions live here (rip-server.mjs listens on a port at import, so tests cannot import
// it); the two side-effecting helpers at the bottom (probe + trailing-silence trim) shell to
// ffprobe/ffmpeg and are used by scripts/rip-one.mjs, which owns the upload.
//
// MEASURED BASELINE (2026-10-14, 5,777 analysed digital captures in the live manifest vs their
// catalog length): p25 +0.05 s, p50 +1.8 s, p95 +2.3 s, p99 +8.6 s. A small cluster runs
// +10–14 s; ffmpeg on the real files shows full-level MUSIC to ~expected+7–10 s and then 2–4 s
// of digital silence (-91 dB) — i.e. Apple Music plays a slightly longer edition than the
// catalog row, plus capture stop slack. Hence: trim only the SILENT tail, never music, and
// leave a 20 s over-allowance so a longer edition is not rejected.
import { execFileSync, spawnSync } from 'node:child_process';
import { renameSync, rmSync } from 'node:fs';

export const LENGTH_GUARD_DEFAULTS = Object.freeze({
  enabled: true,
  underRatio: 0.95,     // short when measured < expected × ratio …
  underSlackMs: 5_000,  // … or more than this short — whichever ALLOWS MORE (lenient on short songs)
  overSlackMs: 20_000,  // long when measured > expected + this (after trimming a silent tail)
  silenceDb: -60,       // trailing-silence threshold (dBFS); capture slack measures at -91
  silenceMinMs: 500,    // ignore sub-half-second dips
  trimPadMs: 250,       // keep this much of the silent tail (never clip a natural decay)
});

const num = (v, d) => { const n = Number(v); return v != null && v !== '' && Number.isFinite(n) ? n : d; };

/// Env knobs (shared by rip-server.mjs and rip-one.mjs — the worker inherits the server's env).
export function lengthGuardConfig(env = process.env) {
  const d = LENGTH_GUARD_DEFAULTS;
  return {
    enabled: env.RIP_LENGTH_GUARD !== '0',
    underRatio: num(env.RIP_LENGTH_UNDER_RATIO, d.underRatio),
    underSlackMs: num(env.RIP_LENGTH_UNDER_SLACK_MS, d.underSlackMs),
    overSlackMs: num(env.RIP_LENGTH_OVER_SLACK_MS, d.overSlackMs),
    silenceDb: num(env.RIP_LENGTH_SILENCE_DB, d.silenceDb),
    silenceMinMs: num(env.RIP_LENGTH_SILENCE_MIN_MS, d.silenceMinMs),
    trimPadMs: num(env.RIP_LENGTH_TRIM_PAD_MS, d.trimPadMs),
  };
}

/// How far short of `expectedMs` a capture may be: the MORE LENIENT of the ratio and the
/// absolute slack (a 60 s song gets 5 s, a 300 s song gets 15 s).
export function underToleranceMs(expectedMs, cfg = LENGTH_GUARD_DEFAULTS) {
  return Math.max(expectedMs * (1 - cfg.underRatio), cfg.underSlackMs);
}

/// Which length to hold a capture to.
///   · digital catalog song → its catalog `length`            (source 'catalog')
///   · ad-hoc recognizer rip → the client's lengthMs          (source 'adhoc')
///   · else Music.app's own reported duration, when known     (source 'music')
///   · an ANALOG catalog song captured from Apple Music: the vinyl row's length is NOT the
///     Apple Music edition's, so only Music.app's own duration is trusted; without it → exempt.
export function resolveExpectedLength({ catalogMs = null, adhocMs = null, musicMs = null, sourceType = 'digital' } = {}) {
  const pos = (v) => (Number.isFinite(Number(v)) && Number(v) > 0 ? Math.round(Number(v)) : null);
  if (sourceType === 'analog') {
    return pos(musicMs) ? { expectedMs: pos(musicMs), source: 'music', analog: true }
      : { expectedMs: null, source: null, analog: true };
  }
  if (pos(catalogMs)) return { expectedMs: pos(catalogMs), source: 'catalog', analog: false };
  if (pos(adhocMs)) return { expectedMs: pos(adhocMs), source: 'adhoc', analog: false };
  if (pos(musicMs)) return { expectedMs: pos(musicMs), source: 'music', analog: false };
  return { expectedMs: null, source: null, analog: false };
}

/// THE RULE. Returns {verdict, reason, measuredMs, expectedMs, deltaMs, toleranceMs}.
///   verdict 'skip'  — guard off / no measurement / no expected length / analog without a
///                     trusted length (reason says which; the caller logs it and accepts)
///   verdict 'short' — reason 'short-capture'
///   verdict 'long'  — reason 'long-capture'
///   verdict 'ok'    — within tolerance; `overrunMs` > 0 means a trailing-silence trim may apply
export function judgeCaptureLength({ measuredMs, expectedMs, analog = false, cfg = LENGTH_GUARD_DEFAULTS } = {}) {
  const base = { measuredMs: measuredMs ?? null, expectedMs: expectedMs ?? null };
  if (!cfg.enabled) return { ...base, verdict: 'skip', reason: 'disabled' };
  if (!(Number(measuredMs) > 0)) return { ...base, verdict: 'skip', reason: 'no-measurement' };
  if (!(Number(expectedMs) > 0)) return { ...base, verdict: 'skip', reason: analog ? 'analog-exempt' : 'no-expected-length' };
  const deltaMs = Math.round(measuredMs - expectedMs);
  const under = underToleranceMs(expectedMs, cfg);
  if (deltaMs < -under) return { ...base, verdict: 'short', reason: 'short-capture', deltaMs, toleranceMs: Math.round(under) };
  if (deltaMs > cfg.overSlackMs) return { ...base, verdict: 'long', reason: 'long-capture', deltaMs, toleranceMs: cfg.overSlackMs };
  return { ...base, verdict: 'ok', reason: null, deltaMs, overrunMs: Math.max(0, deltaMs) };
}

/// One log line with both lengths (the operator's view of the decision).
export function describeVerdict(songId, v, source) {
  const s = (ms) => (ms == null ? '?' : `${(ms / 1000).toFixed(1)}s`);
  const tag = v.verdict === 'skip' ? `skipped (${v.reason})` : v.reason || 'ok';
  return `LENGTH-GUARD ${songId} ${tag}: measured ${s(v.measuredMs)} vs expected ${s(v.expectedMs)}`
    + `${source ? ` (${source})` : ''}${v.deltaMs != null ? ` Δ${v.deltaMs >= 0 ? '+' : ''}${s(v.deltaMs)}` : ''}`;
}

/// Parse ffmpeg `silencedetect` stderr into [{startMs, endMs|null}].
export function parseSilences(stderr) {
  const out = [];
  for (const m of String(stderr || '').matchAll(/silence_(start|end): (-?[\d.]+)/g)) {
    const t = Math.round(parseFloat(m[2]) * 1000);
    if (m[1] === 'start') out.push({ startMs: Math.max(0, t), endMs: null });
    else if (out.length && out[out.length - 1].endMs == null) out[out.length - 1].endMs = t;
  }
  return out;
}

/// Where to cut a capture whose tail is silent. Only the silent run that reaches the END of the
/// file counts, and the cut never lands before `expectedMs` — so music is never trimmed, and a
/// fade-out that is still above the threshold is kept whole. Returns null for "don't trim".
export function trailingTrimMs({ durationMs, expectedMs, silences, padMs = LENGTH_GUARD_DEFAULTS.trimPadMs, endSlackMs = 150 }) {
  if (!(durationMs > 0) || !(expectedMs > 0) || durationMs <= expectedMs) return null;
  const last = (silences || [])[silences.length - 1];
  if (!last) return null;
  const reachesEnd = last.endMs == null || last.endMs >= durationMs - endSlackMs;
  if (!reachesEnd) return null;
  const cut = Math.max(expectedMs, last.startMs + padMs);
  return cut < durationMs - 50 ? Math.round(cut) : null;
}

// ── manifest audit + repair bookkeeping (POST /rip-repair) ─────────────────────────────────

/// Audit the manifest's MEASURED durationMs against the catalog with the same rule. Only
/// per-song captures (key rips/<id>.mp3, source != analog) are judged — an analog album entry's
/// durationMs is the catalog value, not a measurement. `lookupSong(id)` returns the catalog row
/// (variants resolve to their base). Analog catalog songs captured from Apple Music are exempt:
/// their only catalog length is the vinyl one.
export function auditManifestLengths(manifest, lookupSong, { cfg = LENGTH_GUARD_DEFAULTS, songIds = null } = {}) {
  const ids = songIds ? [...new Set(songIds)] : Object.keys(manifest || {});
  const violations = [];
  const skipped = { missing: 0, notPerSong: 0, analogExempt: 0, noExpectedLength: 0, noMeasurement: 0 };
  let ok = 0;
  for (const id of ids) {
    const e = manifest && manifest[id];
    if (!e) { skipped.missing++; continue; }
    if (e.source === 'analog' || e.key !== `rips/${id}.mp3`) { skipped.notPerSong++; continue; }
    const song = lookupSong ? lookupSong(id) : null;
    const exp = resolveExpectedLength({ catalogMs: song?.length, sourceType: song?.sourceType || 'digital' });
    const v = judgeCaptureLength({ measuredMs: e.durationMs, expectedMs: exp.expectedMs, analog: exp.analog, cfg });
    if (v.verdict === 'skip') {
      if (v.reason === 'analog-exempt') skipped.analogExempt++;
      else if (v.reason === 'no-measurement') skipped.noMeasurement++;
      else skipped.noExpectedLength++;
      continue;
    }
    if (v.verdict === 'ok') { ok++; continue; }
    violations.push({ songId: id, verdict: v.verdict, reason: v.reason, measuredMs: v.measuredMs,
      expectedMs: v.expectedMs, expectedSource: exp.source, deltaMs: v.deltaMs, toleranceMs: v.toleranceMs,
      analyzed: !!e.analyzed, rippedAt: e.rippedAt ?? null });
  }
  return { scanned: ids.length, ok, violations, skipped };
}

/// Every S3 object derived from (or being) a per-song capture: the rip itself, the stems prefix,
/// the beat-grid sidecar, the waveform, the lyrics sidecar and every timbre version's sidecar.
/// Keys recorded on the entry are included too — but ONLY keys that name this song id, so a
/// malformed entry can never steer a delete at a shared object (an album mp3, another song).
export function repairTargetsFor(songId, e, { timbreVersions = [1] } = {}) {
  const objects = new Set([
    `rips/${songId}.mp3`,
    `rips/analysis/${songId}.json`,
    `rips/waveforms/${songId}.png`,
    `rips/lyrics/${songId}.json`,
    ...timbreVersions.map((v) => `rips/timbre/v${v}/${songId}.json`),
  ]);
  const recorded = [e?.key, e?.waveform, e?.beatgrid, e?.lyrics, e?.timbre,
    ...Object.values((e && e.stems) || {})];
  const ownsId = (k) => typeof k === 'string' && k.startsWith('rips/')
    && k.split('/').some((seg) => seg === songId || seg.startsWith(`${songId}.`));
  for (const k of recorded) if (ownsId(k) && !k.startsWith(`rips/stems/${songId}/`)) objects.add(k);
  return { objects: [...objects].sort(), prefixes: [`rips/stems/${songId}/`] };
}

/// A timbre result row measured BEFORE a song was repaired describes the deleted audio. Drop
/// those rows so neither reconcile (which would re-stamp the fresh entry with the stale vector)
/// nor the backstop sweep (which filters candidates on this map) treats the song as measured.
export function dropPreRepairRows(doneRows, repaired) {
  if (!doneRows || !repaired) return 0;
  let n = 0;
  for (const [id, r] of Object.entries(repaired)) {
    const row = doneRows.get(id);
    if (row && r && Number.isFinite(r.at) && (row.atMs || 0) < r.at) { doneRows.delete(id); n++; }
  }
  return n;
}

// ── side-effecting helpers (rip-one.mjs) ───────────────────────────────────────────────────

/// Duration of an audio file in ms (ffprobe), or null.
export function probeDurationMs(file, { ffprobe = 'ffprobe' } = {}) {
  try {
    const out = execFileSync(ffprobe, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    const s = parseFloat(String(out).trim());
    return Number.isFinite(s) && s > 0 ? Math.round(s * 1000) : null;
  } catch { return null; }
}

/// Measure → (trim a silent tail past expected) → judge. Mutates `file` in place when it trims.
/// Returns {verdict…, trimmedFromMs?} — the caller decides what a short/long verdict means.
export function guardCaptureFile(file, { expectedMs, analog = false, cfg = LENGTH_GUARD_DEFAULTS, ffmpeg = 'ffmpeg', ffprobe = 'ffprobe', log = () => {} } = {}) {
  let measuredMs = probeDurationMs(file, { ffprobe });
  let trimmedFromMs = null;
  if (cfg.enabled && measuredMs && expectedMs > 0 && measuredMs > expectedMs) {
    const r = spawnSync(ffmpeg, ['-hide_banner', '-nostats', '-i', file,
      '-af', `silencedetect=noise=${cfg.silenceDb}dB:d=${cfg.silenceMinMs / 1000}`, '-f', 'null', '-'], { encoding: 'utf8' });
    const cut = trailingTrimMs({ durationMs: measuredMs, expectedMs, silences: parseSilences(r.stderr), padMs: cfg.trimPadMs });
    if (cut) {
      const tmp = file.replace(/(\.[^.]+)?$/, '.trim$1');
      const t = spawnSync(ffmpeg, ['-y', '-hide_banner', '-loglevel', 'error', '-i', file, '-t', (cut / 1000).toFixed(3),
        '-map', '0:a:0', '-c', 'copy', tmp], { encoding: 'utf8' });
      const after = t.status === 0 ? probeDurationMs(tmp, { ffprobe }) : null;
      if (after) {
        renameSync(tmp, file);
        log(`LENGTH-GUARD trimmed silent tail ${(measuredMs / 1000).toFixed(1)}s → ${(after / 1000).toFixed(1)}s`);
        trimmedFromMs = measuredMs; measuredMs = after;
      } else { try { rmSync(tmp, { force: true }); } catch { /* best effort */ } }
    }
  }
  const v = judgeCaptureLength({ measuredMs, expectedMs, analog, cfg });
  return trimmedFromMs ? { ...v, trimmedFromMs } : v;
}
