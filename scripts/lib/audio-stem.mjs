// Shared Demucs stem separator for ripped songs — used by the rip server's stem queue.
// For one audio file: run Demucs (htdemucs by default) -> 4 stems (vocals/drums/bass/other),
// upload each to rips/stems/<songId>/<stem>.<ext> on the PUBLIC rips bucket, and return the
// S3 keys. The CALLER writes the manifest (mirrors audio-analyze.mjs's contract).
//
// The Demucs child is run via async spawn (NOT execFileSync): a separation takes minutes,
// so a synchronous call would freeze the single-threaded rip-server event loop (no /health,
// no rips, no cancels) AND leave the queue watchdog inert. opts.child.p is set to the live
// process so the rip server can group-kill it on timeout/cancel.
import { spawn, execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, rmSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const STEM_PY = join(REPO, '.claude/skills/analog-indexer/stems/separate-one.py');

// THE single model knob — same env the rip server's CFG.demucsModel reads. v3 fallback:
// POCKETDJ_DEMUCS_MODEL=hdemucs_mmi (or mdx_extra).
export const STEMS_MODEL = process.env.POCKETDJ_DEMUCS_MODEL || 'htdemucs';
// Bump ONLY on an algorithm/output change so /backfill-stems re-runs stale entries. Separate
// from ANALYSIS_VERSION so a Demucs change never triggers a beatgrid re-run (and vice versa).
export const STEMS_VERSION = 1;
export const STEM_NAMES = ['vocals', 'drums', 'bass', 'other'];

/**
 * Separate ONE file into 4 stems and upload them to rips/stems/<songId>/<stem>.<ext>.
 * @param {{file:string, songId:string, bucket:string, region?:string, profile?:string,
 *          model?:string, runtime?:string, device?:string, image?:string, venv?:string,
 *          format?:string, bitrate?:string, tmp?:string, child?:{p:any}}} opts
 * @returns {Promise<{ok:boolean, stems:Object|null, model:string, stemBytes:number|null, format:string}>}
 *   stems is the {vocals,drums,bass,other} map of S3 KEYS. The caller writes the manifest.
 */
export async function separateStems(opts) {
  const {
    file, songId, bucket, region = 'us-west-2', profile = 'levi',
    model = STEMS_MODEL,
    runtime = process.env.POCKETDJ_DEMUCS_RUNTIME || 'native',
    device = (process.env.POCKETDJ_DEMUCS_RUNTIME || 'native') === 'docker'
      ? 'cpu' : (process.env.POCKETDJ_DEMUCS_DEVICE || 'mps'),
    image = process.env.POCKETDJ_STEM_IMAGE || 'pocketdj-stems:latest',
    venv = process.env.POCKETDJ_STEM_VENV || join(homedir(), '.pocketdj', '.venv-stems'),
    format = process.env.POCKETDJ_STEM_FORMAT || 'mp3',
    bitrate = process.env.POCKETDJ_STEM_BITRATE || '256',
    tmp = join(homedir(), '.pocketdj', 'rips'),
    child = { p: null },          // shared handle so the server watchdog/cancel can kill the run
  } = opts;

  const out = { ok: false, stems: null, model, stemBytes: null, format };
  if (!existsSync(STEM_PY)) return out;

  const work = join(tmp, `stem-${songId}`);
  mkdirSync(work, { recursive: true });
  const ext = format === 'flac' ? 'flac' : 'mp3';
  const contentType = format === 'flac' ? 'audio/flac' : 'audio/mpeg';
  try {
    copyFileSync(file, join(work, 'song.mp3'));
    copyFileSync(STEM_PY, join(work, 'separate-one.py'));
    const senv = { STEM_MODEL: model, STEM_DEVICE: device, STEM_FORMAT: format, STEM_BITRATE: String(bitrate) };

    // --- async spawn (NOT execFileSync): event loop stays live, child is watchdog-killable ---
    const stdout = await new Promise((res, rej) => {
      let proc;
      let buf = '';
      if (runtime === 'docker') {
        proc = spawn('docker',
          ['run', '--rm', '--entrypoint', 'python',
            ...Object.entries(senv).flatMap(([k, v]) => ['-e', `${k}=${v}`]),
            '-v', `${work}:/work`, image, '/work/separate-one.py', '/work/song.mp3'],
          { detached: true });
      } else {
        proc = spawn(join(venv, 'bin', 'python'),
          [join(work, 'separate-one.py'), join(work, 'song.mp3')],
          { detached: true, env: { ...process.env, ...senv, PYTORCH_ENABLE_MPS_FALLBACK: '1' } });
      }
      child.p = proc;                                  // register for the server watchdog/cancel
      proc.stdout.on('data', (d) => { buf += d; });
      proc.on('error', rej);
      proc.on('close', (code) => (code === 0 ? res(buf) : rej(new Error(`demucs exit ${code}`))));
    });

    const lines = stdout.trim().split('\n').filter(Boolean);
    if (!lines.length) return out;
    const j = JSON.parse(lines.pop());
    if (!j.ok || !j.stems) return out;

    const stems = {};
    let bytes = 0;
    for (const name of STEM_NAMES) {
      const local = join(work, j.stems[name]);
      const key = `rips/stems/${songId}/${name}.${ext}`;
      execFileSync('aws', ['s3', 'cp', local, `s3://${bucket}/${key}`,
        '--content-type', contentType, '--profile', profile, '--region', region],
        { stdio: 'ignore' });
      stems[name] = key;
      try { bytes += statSync(local).size; } catch { /* ignore */ }
    }
    out.ok = true;
    out.stems = stems;
    out.model = j.model || model;
    out.stemBytes = bytes || null;
  } catch { /* best-effort: never wedge the queue. A partial upload is harmless (no manifest stamp). */ }
  finally {
    child.p = null;
    rmSync(work, { recursive: true, force: true });
  }
  return out;
}
