// Shared audio analyzer for ripped songs — used by BOTH the rip server (per-rip
// background) and the batch tool (rip-skill setlist output). For one audio file:
//   • BPM + musical key + Camelot via the pocketdj-audio Docker image (librosa)
//   • a waveform PNG via ffmpeg showwavespic → uploaded to rips/waveforms/<id>.png
// Returns the analysis; the CALLER decides what to write into the manifest.
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, rmSync, existsSync, writeFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const ANALYZE_PY = join(REPO, '.claude/skills/analog-indexer/audio/analyze-one.py');
const BEATGRID_PY = join(REPO, '.claude/skills/analog-indexer/audio/analyze-beatgrid.py');
const TIMBRE_PY = join(REPO, '.claude/skills/analog-indexer/audio/analyze-timbre.py');
// Bump when the beat-grid algorithm changes so /backfill-beatgrids re-runs stale entries.
export const ANALYSIS_VERSION = 1;
// Bump when analyze-timbre.py changes what its scalars MEAN (a new axis, a re-calibrated lo/hi).
// The nightly rec-audio job re-analyzes anything stamped below this, which is what lets a
// recalibration reach the corpus without a manual sweep. Held separately from ANALYSIS_VERSION
// so a beat-grid change does not invalidate a timbre corpus that took weeks of nights to build.
export const TIMBRE_VERSION = 1;

/**
 * @param {{file:string, songId:string, bucket:string, region?:string, profile?:string,
 *          image?:string, tmp?:string, withKey?:boolean, withWaveform?:boolean,
 *          withBeatgrid?:boolean, withTimbre?:boolean}} opts
 * @returns {Promise<{bpm:number|null, musicalKey:string|null, camelot:string|null,
 *          keyStrength:number|null, durationSec:number|null, waveform:string|null,
 *          beatgrid:object|null, beatgridKey:string|null, timbre:object|null}>}
 */
export async function analyzeAudio(opts) {
  const {
    file, songId, bucket, region = 'us-west-2', profile = 'levi',
    image = process.env.AUDIO_IMAGE || 'pocketdj-audio:latest',
    tmp = join(homedir(), '.pocketdj', 'rips'),
    withKey = true, withWaveform = true, withBeatgrid = false, withTimbre = false,
  } = opts;
  const work = join(tmp, `ana-${songId}`);
  mkdirSync(work, { recursive: true });
  const mp3 = join(work, 'song.mp3');
  copyFileSync(file, mp3);

  const out = {
    bpm: null, musicalKey: null, camelot: null, keyStrength: null, durationSec: null,
    waveform: null, beatgrid: null, beatgridKey: null, timbre: null,
  };

  // --- BPM / key / Camelot (Docker librosa) ---
  if (withKey && existsSync(ANALYZE_PY)) {
    try {
      copyFileSync(ANALYZE_PY, join(work, 'analyze-one.py'));
      const res = execFileSync('docker',
        ['run', '--rm', '--entrypoint', 'python', '-v', `${work}:/work`, image, '/work/analyze-one.py', '/work/song.mp3'],
        { encoding: 'utf8', timeout: 180000 });
      const j = JSON.parse(res.trim().split('\n').filter(Boolean).pop());
      if (j.ok) { out.bpm = j.bpm; out.musicalKey = j.key; out.camelot = j.camelot; out.keyStrength = j.keyStrength; out.durationSec = j.durationSec; }
    } catch { /* analysis is best-effort */ }
  }

  // --- beat grid (Docker librosa): per-beat + downbeat timestamps → manifest scalars + a lazy
  //     sidecar rips/analysis/<id>.json (mirrors the waveform-PNG sidecar so manifest.json stays
  //     lean). Run on the burned file the deck OPENS (digital mp3 / analog per-song cut) so
  //     firstDownbeatMs is relative to that file's 0:00. ---
  if (withBeatgrid && existsSync(BEATGRID_PY)) {
    try {
      copyFileSync(BEATGRID_PY, join(work, 'analyze-beatgrid.py'));
      const res = execFileSync('docker',
        ['run', '--rm', '--entrypoint', 'python', '-v', `${work}:/work`, image, '/work/analyze-beatgrid.py', '/work/song.mp3'],
        { encoding: 'utf8', timeout: 180000 });
      const j = JSON.parse(res.trim().split('\n').filter(Boolean).pop());
      if (j.ok) {
        out.beatgrid = {
          firstBeatMs: j.firstBeatMs, firstDownbeatMs: j.firstDownbeatMs, beatGridBpm: j.beatGridBpm,
          beatsPerBar: j.beatsPerBar, tempoVar: j.tempoVar, tempoConfidence: j.tempoConfidence,
          gridResidualMs: j.gridResidualMs, steady: j.steady,
        };
        const key = `rips/analysis/${songId}.json`;
        const sidecar = join(work, 'analysis.json');
        writeFileSync(sidecar, JSON.stringify({
          version: ANALYSIS_VERSION, analyzer: 'librosa-beatgrid',
          ...out.beatgrid, beatsMs: j.beatsMs || [], downbeatsMs: j.downbeatsMs || [],
        }));
        execFileSync('aws', ['s3', 'cp', sidecar, `s3://${bucket}/${key}`, '--content-type', 'application/json', '--profile', profile, '--region', region], { stdio: 'ignore' });
        out.beatgridKey = key;
      }
    } catch { /* beat grid is best-effort */ }
  }

  // --- TIMBRE vector (Docker librosa): the "musicality" features the recommendation engine
  //     scores against — bright / punch / busy / dynamic / … See analyze-timbre.py. Off by
  //     default: only the nightly rec-audio job asks for it, so no rip pays for it. ---
  if (withTimbre && existsSync(TIMBRE_PY)) {
    try {
      copyFileSync(TIMBRE_PY, join(work, 'analyze-timbre.py'));
      const res = execFileSync('docker',
        ['run', '--rm', '--entrypoint', 'python', '-v', `${work}:/work`, image, '/work/analyze-timbre.py', '/work/song.mp3'],
        { encoding: 'utf8', timeout: 180000 });
      const j = JSON.parse(res.trim().split('\n').filter(Boolean).pop());
      if (j.ok && j.f) {
        // The RAW block rides along when the engine produced one — see analyze-timbre.py for why
        // keeping it makes the next rail change arithmetic instead of a multi-day sweep.
        out.timbre = { v: TIMBRE_VERSION, f: j.f,
                       ...(j.r && typeof j.r === 'object' ? { r: j.r } : {}) };
        if (out.durationSec == null && Number.isFinite(j.durationSec)) out.durationSec = j.durationSec;
      }
    } catch { /* timbre is best-effort, exactly like bpm/key above */ }
  }

  // --- waveform PNG (ffmpeg) → S3 rips/waveforms/<songId>.png ---
  if (withWaveform) {
    try {
      const png = join(work, 'waveform.png');
      execFileSync('ffmpeg', ['-y', '-i', mp3, '-filter_complex', 'showwavespic=s=1200x240:colors=#7aa2ff', '-frames:v', '1', png], { stdio: 'ignore' });
      const key = `rips/waveforms/${songId}.png`;
      execFileSync('aws', ['s3', 'cp', png, `s3://${bucket}/${key}`, '--content-type', 'image/png', '--profile', profile, '--region', region], { stdio: 'ignore' });
      out.waveform = key;
    } catch { /* waveform is best-effort */ }
  }

  rmSync(work, { recursive: true, force: true });
  return out;
}
