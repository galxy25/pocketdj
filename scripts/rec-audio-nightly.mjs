#!/usr/bin/env node
// TARGETED AUDIO ANALYSIS — the nightly half of PocketDJ's musicality features.
//
//   node scripts/rec-audio-nightly.mjs [--until 06:00] [--max N] [--queue-file f] [--dry-run]
//
// ── WHAT IT DOES ────────────────────────────────────────────────────────────────────────────────
// The device already decided WHICH songs are worth listening to: `RecAudioShortlist.select` takes
// the recommender's own candidate list, keeps the most novel and the most similar-to-recent, and
// uploads the ids (and nothing else) with the next `/events` flush. This job drains that queue.
//
// For each queued song it finds the LOCAL AUDIO the rip server already holds, runs the librosa
// timbre extractor over it (`analyze-timbre.py`, via the shared `analyzeAudio` — the same Docker
// image, the same 90-second window, the same best-effort contract as bpm/key), and posts the
// resulting vector back to the rec engine, which stores it per profile and drops the id from the
// queue.
//
// Songs with NO local audio are not analysed and are not skipped either: they are enqueued on the
// rip server's existing durable queue (`POST /rip-collection`) and left in the analysis queue for
// a later night, by which time the capture exists. That is why the job is worth running every
// night on a catalog where only 1.8% of rows have local audio today.
//
// ── THE 02:00–06:00 WINDOW, AND WHY IT STOPS RATHER THAN FINISHES ───────────────────────────────
// Same launchd slot as `am-sync-nightly` (04:00) and `digital-sync-nightly` (05:00), started at
// 02:00 so its Docker/S3 traffic is done before those begin. `--until` is a HARD DEADLINE checked
// before each song starts, never a budget it tries to fit into: a job that estimates and overruns
// is exactly the failure mode that would have this thing still analysing at 05:30 while the
// digital indexer is trying to use the same Docker daemon.
//
// Stopping early is CORRECT, not a failure, because the work is resumable at song granularity:
// every completed vector is posted and drained from the server's queue, so tomorrow starts where
// tonight stopped. Nothing is lost by cutting the night short except the night.
//
// ── STATE ───────────────────────────────────────────────────────────────────────────────────────
// ~/.pocketdj/rec-audio/state.json — { done: { songId: {v, atMs} }, ripRequested: { songId: atMs },
// lastRunAtMs, totals }. The server's queue is the source of truth for WHAT to do; this file is
// the local memory of what has already been done, so a night that cannot reach the network still
// avoids re-analysing what it analysed last week.
import { analyzeAudio, TIMBRE_VERSION } from './lib/audio-analyze.mjs';
import { execFile as execFileCb, execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { promisify } from 'node:util';

const execFile = promisify(execFileCb);

const a = {};
for (let i = 2; i < process.argv.length; i++) {
  const k = process.argv[i];
  if (k === '--dry-run') a.dryRun = true;
  else if (k === '--verbose') a.verbose = true;
  else if (k.startsWith('--')) a[k.slice(2)] = process.argv[++i];
}

const CFG = {
  // NOT `a.dryRun` read directly at each site: the flag lives in `a` and every guard reads `CFG`,
  // so leaving it out of CFG made `--dry-run` silently ineffective for the rip request — caught by
  // a smoke run that posted to the real rip server while claiming to be a dry run.
  dryRun: !!a.dryRun,
  engine: (a.engine || process.env.REC_ENGINE_BASE || '').replace(/\/$/, ''),
  enrollSecret: a['enroll-secret'] || process.env.REC_ENROLL_SECRET || '',
  ripServer: (a['rip-server'] || process.env.RIP_SERVER || 'http://localhost:8787').replace(/\/$/, ''),
  ripToken: a['rip-token'] || process.env.RIP_TOKEN || '',
  bucket: a.bucket || process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623',
  region: a.region || process.env.AWS_REGION || 'us-west-2',
  profile: a.profile || process.env.AWS_PROFILE || 'levi',
  until: a.until || '06:00',
  // A ceiling ON TOP of the clock, so a `--until` far in the future (a manual catch-up run) still
  // cannot turn into an unbounded sweep of the catalog.
  max: Number(a.max) || 120,
  // How many un-ripped songs one night may add to the rip server's queue. The rip is REAL TIME —
  // a 4-minute song takes 4 minutes — so a night can physically capture ~50. Asking for more than
  // that just parks work in someone else's queue.
  ripBudget: Number(a['rip-budget']) || 50,
  stateDir: a['state-dir'] || join(homedir(), '.pocketdj', 'rec-audio'),
  queueFile: a['queue-file'] || null,
};
const STATE_FILE = join(CFG.stateDir, 'state.json');
const TMP = join(CFG.stateDir, 'work');

const log = (...m) => console.error(`[rec-audio ${new Date().toISOString()}]`, ...m);

// ── the deadline ────────────────────────────────────────────────────────────────────────────────
/// Local-time HH:MM → an absolute epoch ms. A deadline EARLIER than now means tomorrow, which is
/// what makes `--until 06:00` correct for a job that starts at 02:00 AND for one started by hand
/// at 23:00 — the alternative (treating it as "already past") turns a manual run into a no-op.
export function deadlineMs(hhmm, now = new Date()) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(hhmm || '').trim());
  if (!m) return null;
  const h = Number(m[1]); const min = Number(m[2]);
  if (h > 23 || min > 59) return null;
  const d = new Date(now);
  d.setHours(h, min, 0, 0);
  if (d.getTime() <= now.getTime()) d.setDate(d.getDate() + 1);
  return d.getTime();
}

// ── local state ─────────────────────────────────────────────────────────────────────────────────
function loadState() {
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf8')); } catch { /* fresh */ }
  return { v: 1, done: {}, ripRequested: {}, lastRunAtMs: 0, totals: { analyzed: 0, ripQueued: 0 } };
}
function saveState(s) {
  mkdirSync(dirname(STATE_FILE), { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(s));
}

// ── the rip manifest: which songs have local audio, and WHICH FILE ──────────────────────────────
/// ANALOG entries carry an ALBUM-level `key` (the whole side) and a per-song `cutKey`. Reading
/// `key` for an analog song analyses the WHOLE ALBUM and hands every track on it an identical
/// vector — measured, not hypothesised: the first calibration run did exactly that and two artist
/// groups came back with a pairwise timbre distance of exactly 0.0000 across eight songs each.
/// `analyzeBeatgridForSong` in the rip server follows the same rule for the same reason.
export function sourceKeyFor(entry) {
  if (!entry) return null;
  return entry.source === 'analog' ? (entry.cutKey || null) : (entry.key || null);
}

async function loadManifest() {
  const out = await execFile('aws', ['s3', 'cp', `s3://${CFG.bucket}/rips/manifest.json`, '-',
                                     '--profile', CFG.profile, '--region', CFG.region],
                             { maxBuffer: 256 * 1024 * 1024 });
  return JSON.parse(out.stdout || '{}');
}

// ── the engine ──────────────────────────────────────────────────────────────────────────────────
async function fetchQueue() {
  if (CFG.queueFile) {
    const doc = JSON.parse(readFileSync(CFG.queueFile, 'utf8'));
    return doc.profiles || [];
  }
  if (!CFG.engine || !CFG.enrollSecret) {
    log('no --engine / REC_ENROLL_SECRET — nothing to drain');
    return [];
  }
  const r = await fetch(`${CFG.engine}/audio/queue`, {
    headers: { 'x-pocketdj-enroll': CFG.enrollSecret },
  });
  if (!r.ok) throw new Error(`/audio/queue ${r.status}: ${(await r.text()).slice(0, 200)}`);
  const doc = await r.json();
  if (doc.timbreVersion && doc.timbreVersion !== TIMBRE_VERSION) {
    // Not fatal, but it means the two halves disagree about what the numbers MEAN, so say so
    // loudly rather than quietly mixing calibrations into one corpus.
    log(`WARNING: engine expects timbre v${doc.timbreVersion}, this worker produces v${TIMBRE_VERSION}`);
  }
  return doc.profiles || [];
}

async function postFeatures(profileHash, features, done) {
  if (CFG.dryRun || !CFG.engine || !CFG.enrollSecret) {
    log(`dry-run: would post ${features.length} vector(s), ${done.length} drain(s)`);
    return;
  }
  const r = await fetch(`${CFG.engine}/audio/features`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-pocketdj-enroll': CFG.enrollSecret },
    body: JSON.stringify({ p: profileHash, features, done }),
  });
  if (!r.ok) throw new Error(`/audio/features ${r.status}: ${(await r.text()).slice(0, 200)}`);
  const ack = await r.json();
  log(`posted ${features.length} vector(s) → accepted=${ack.accepted} drained=${ack.drained} corpus=${ack.stored}`);
}

/// Ask the rip server to capture songs that have no local audio yet, on its OWN durable queue.
/// Fire-and-forget by design: the capture is real-time and this job is not going to wait four
/// minutes per song holding a night open. They stay queued server-side for analysis and get
/// picked up on a later night once the manifest carries them.
async function requestRips(ids) {
  if (!ids.length || CFG.dryRun) return 0;
  try {
    const r = await fetch(`${CFG.ripServer}/rip-collection`, {
      method: 'POST',
      headers: { 'content-type': 'application/json',
                 ...(CFG.ripToken ? { authorization: `Bearer ${CFG.ripToken}` } : {}) },
      body: JSON.stringify({ songIds: ids }),
    });
    if (!r.ok) { log(`rip-collection ${r.status} — skipped this night`); return 0; }
    const doc = await r.json();
    log(`rip queue: ${JSON.stringify(doc.counts || {})}`);
    return ids.length;
  } catch (e) {
    log(`rip server unreachable (${e.message}) — analysis-only night`);
    return 0;
  }
}

// ── one song ────────────────────────────────────────────────────────────────────────────────────
async function analyzeOne(songId, srcKey, entry) {
  const work = join(TMP, songId);
  mkdirSync(work, { recursive: true });
  const local = join(work, 'song.mp3');
  try {
    execFileSync('aws', ['s3', 'cp', `s3://${CFG.bucket}/${srcKey}`, local,
                         '--profile', CFG.profile, '--region', CFG.region], { stdio: 'ignore' });
    // bpm/key ride along ONLY when the manifest has none. 10.6% of the catalog carries a tempo
    // today, so for most songs this is a genuine second win off ONE download — and for the ones
    // that already have it, skipping the second Docker run is half the night back.
    const needKey = !Number.isFinite(entry?.bpm);
    const r = await analyzeAudio({
      file: local, songId, bucket: CFG.bucket, region: CFG.region, profile: CFG.profile,
      tmp: work, withKey: needKey, withWaveform: false, withBeatgrid: false, withTimbre: true,
    });
    return r;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

// ── the night ───────────────────────────────────────────────────────────────────────────────────
async function main() {
  const startedAt = Date.now();
  const until = deadlineMs(CFG.until);
  if (until == null) { console.error(`bad --until ${CFG.until}`); process.exit(2); }
  log(`start — deadline ${new Date(until).toISOString()} (${Math.round((until - startedAt) / 60000)} min), max ${CFG.max}`);

  const state = loadState();
  const profiles = await fetchQueue();
  if (!profiles.length) { log('queue empty — nothing to do'); return; }

  const manifest = await loadManifest();
  log(`manifest: ${Object.keys(manifest).length} songs with local audio`);

  let analyzed = 0; let skipped = 0; let failed = 0; let ripQueued = 0;
  const timings = [];

  for (const { p, songIds } of profiles) {
    const features = []; const done = []; const wantRip = [];
    for (const songId of songIds) {
      if (Date.now() >= until) { log('DEADLINE — stopping cleanly'); break; }
      if (analyzed >= CFG.max) { log(`--max ${CFG.max} reached — stopping cleanly`); break; }

      const already = state.done[songId];
      if (already && already.v === TIMBRE_VERSION) { done.push(songId); skipped += 1; continue; }

      const entry = manifest[songId];
      const srcKey = sourceKeyFor(entry);
      if (!srcKey) {
        // No local audio. Queue a capture (once — `ripRequested` is what stops a song with no
        // Apple Music match from being re-requested every night forever) and leave it queued.
        if (!state.ripRequested[songId] && wantRip.length < CFG.ripBudget) {
          wantRip.push(songId);
          state.ripRequested[songId] = Date.now();
        }
        continue;
      }

      const t0 = Date.now();
      try {
        const r = await analyzeOne(songId, srcKey, entry);
        const ms = Date.now() - t0;
        timings.push(ms);
        if (r.timbre?.f) {
          features.push({ songId, v: r.timbre.v, f: r.timbre.f });
          state.done[songId] = { v: r.timbre.v, atMs: Date.now() };
          analyzed += 1;
          if (a.verbose) log(`  ✓ ${songId} ${ms} ms  ${JSON.stringify(r.timbre.f)}`);
          else log(`  ✓ ${songId} ${ms} ms${r.bpm ? ` (+bpm ${r.bpm})` : ''}`);
        } else {
          // The extractor ran and produced nothing usable (corrupt capture, a file ffmpeg cannot
          // decode). DRAIN it rather than retry forever — a permanently undecodable song at the
          // head of the queue is how a resumable job becomes a stuck one.
          done.push(songId);
          state.done[songId] = { v: TIMBRE_VERSION, atMs: Date.now(), empty: true };
          failed += 1;
          log(`  ✗ ${songId} produced no vector — draining`);
        }
      } catch (e) {
        // A TRANSIENT failure (S3 hiccup, Docker restarting): leave it in the queue, do not mark
        // it done. Tomorrow retries it.
        failed += 1;
        log(`  ✗ ${songId}: ${e.message}`);
      }
      saveState(state);
    }

    if (wantRip.length) {
      ripQueued += await requestRips(wantRip);
      saveState(state);
    }
    if (features.length || done.length) {
      try { await postFeatures(p, features, done); } catch (e) { log(`post failed: ${e.message}`); }
    }
  }

  state.lastRunAtMs = Date.now();
  state.totals = {
    analyzed: (state.totals?.analyzed || 0) + analyzed,
    ripQueued: (state.totals?.ripQueued || 0) + ripQueued,
  };
  saveState(state);

  const mins = ((Date.now() - startedAt) / 60000).toFixed(1);
  const avg = timings.length ? Math.round(timings.reduce((x, y) => x + y, 0) / timings.length) : 0;
  log(`done in ${mins} min — analyzed ${analyzed} (avg ${avg} ms), skipped ${skipped}, `
      + `failed ${failed}, rips queued ${ripQueued}; corpus now ${Object.keys(state.done).length}`);
}

if (process.argv[1] && process.argv[1].endsWith('rec-audio-nightly.mjs')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
