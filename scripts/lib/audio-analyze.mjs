// Shared audio analyzer for ripped songs — used by BOTH the rip server (per-rip
// background) and the batch tool (rip-skill setlist output). For one audio file:
//   • BPM + musical key + Camelot via the pocketdj-audio Docker image (librosa)
//   • a waveform PNG via ffmpeg showwavespic → uploaded to rips/waveforms/<id>.png
// Returns the analysis; the CALLER decides what to write into the manifest.
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const ANALYZE_PY = join(REPO, '.claude/skills/analog-indexer/audio/analyze-one.py');

/**
 * @param {{file:string, songId:string, bucket:string, region?:string, profile?:string,
 *          image?:string, tmp?:string, withKey?:boolean, withWaveform?:boolean}} opts
 * @returns {Promise<{bpm:number|null, musicalKey:string|null, camelot:string|null,
 *          keyStrength:number|null, durationSec:number|null, waveform:string|null}>}
 */
export async function analyzeAudio(opts) {
  const {
    file, songId, bucket, region = 'us-west-2', profile = 'levi',
    image = process.env.AUDIO_IMAGE || 'pocketdj-audio:latest',
    tmp = join(homedir(), '.pocketdj', 'rips'), withKey = true, withWaveform = true,
  } = opts;
  const work = join(tmp, `ana-${songId}`);
  mkdirSync(work, { recursive: true });
  const mp3 = join(work, 'song.mp3');
  copyFileSync(file, mp3);

  const out = { bpm: null, musicalKey: null, camelot: null, keyStrength: null, durationSec: null, waveform: null };

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
