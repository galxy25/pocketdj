#!/usr/bin/env node
// ART MIRROR — make album covers self-hosted + offline-durable.
//
// For each album with a remote cover URL, downloads it SERVER-SIDE (no browser CORS
// limits), thumbnails it to a small 256px JPEG with ffmpeg, and writes it to a local
// art dir as <albumId>.jpg. With --write-index it then rewrites each mirrored album's
// `coverArtSources` to a PROGRESSIVE list — our CDN thumbnail (root-relative, cacheable
// offline) first, the original remote URL as a backup:
//
//   coverArtSources = [
//     { type:'cdn',    url:'/art/<albumId>.jpg', cors:true  },   // default, cacheable
//     { type:'remote', url:'<original>',         cors:false },   // online-only backup
//   ]
//
// The art dir is then synced to S3 (see scripts/mirror-art.sh) and served by the same
// CloudFront that fronts the app, so the CDN URL is same-origin → the app fetches +
// thumbnails it into a durable IndexedDB blob (offline across restart).
//
//   node mirror-art.mjs [--index index-out/current/index.json] [--art-dir index-out/art]
//     [--cdn-prefix /art] [--concurrency 8] [--limit N] [--write-index]
//
// Idempotent + resumable: skips albums whose <albumId>.jpg already exists; tolerant of
// per-cover download failures (those albums keep only their remote source).
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';

function arg(f, d) {
  const i = process.argv.indexOf(f);
  return i >= 0 ? process.argv[i + 1] : d;
}
const has = (f) => process.argv.includes(f);
const indexPath = arg('--index', 'index-out/current/index.json');
const artDir = arg('--art-dir', 'index-out/art');
const cdnPrefix = arg('--cdn-prefix', '/art').replace(/\/$/, '');
const concurrency = Math.max(1, parseInt(arg('--concurrency', '8'), 10));
const limit = parseInt(arg('--limit', '0'), 10);
const delayMs = parseInt(arg('--delay-ms', '0'), 10); // polite gap before each fetch (per worker)
const writeIndex = has('--write-index');

mkdirSync(artDir, { recursive: true });
const idx = JSON.parse(readFileSync(indexPath, 'utf8'));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Descriptive UA — some hosts (Wikimedia) rate-limit/ýblock generic browser UAs on bulk
// automated access and ask for an identifying agent + contact.
const UA = 'PocketDJ-art-mirror/1.0 (https://pocketdj.app; levismschoen@gmail.com)';

// fetch with 429/503 backoff (respects Retry-After). Returns a Response or null.
async function politeFetch(url, tries = 5) {
  for (let attempt = 0; attempt < tries; attempt++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 20000);
    try {
      const res = await fetch(url, { headers: { 'User-Agent': UA }, signal: ctrl.signal });
      clearTimeout(timer);
      if (res.status === 429 || res.status === 503) {
        const ra = parseInt(res.headers.get('retry-after') || '', 10);
        const wait = Number.isFinite(ra) && ra > 0 ? ra * 1000 : Math.min(30000, 2000 * 2 ** attempt);
        await sleep(wait);
        continue;
      }
      return res;
    } catch {
      clearTimeout(timer);
      await sleep(Math.min(15000, 1000 * 2 ** attempt));
    }
  }
  return null;
}

function run(cmd, args) {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { stdio: ['ignore', 'ignore', 'ignore'] });
    p.on('error', () => resolve(1));
    p.on('close', (code) => resolve(code ?? 1));
  });
}

// download -> ffmpeg 256px jpg thumbnail -> artDir/<id>.jpg. returns true on success.
async function thumbnail(id, url) {
  const outPath = join(artDir, `${id}.jpg`);
  if (existsSync(outPath)) return true; // resumable
  const tmp = join(tmpdir(), `mirror-${id}.bin`);
  try {
    if (delayMs > 0) await sleep(delayMs);
    const res = await politeFetch(url);
    if (!res || !res.ok) return false;
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length < 256) return false; // not a real image
    writeFileSync(tmp, buf);
    // longest edge -> 256, even dims, mild compression; -y overwrite, no audio/meta
    const code = await run('ffmpeg', [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-i', tmp,
      '-vf', 'scale=if(gt(iw\\,ih)\\,256\\,-2):if(gt(iw\\,ih)\\,-2\\,256)',
      '-q:v', '5',
      outPath,
    ]);
    return code === 0 && existsSync(outPath);
  } catch {
    return false;
  } finally {
    try {
      if (existsSync(tmp)) (await import('node:fs')).rmSync(tmp, { force: true });
    } catch {
      /* ignore */
    }
  }
}

// candidates: albums with a remote cover (coverArt, or the remote entry of coverArtSources)
function remoteUrlOf(a) {
  if (a.coverArt) return a.coverArt;
  const r = (a.coverArtSources || []).find((s) => s.type === 'remote') || (a.coverArtSources || [])[0];
  return r?.url;
}
let candidates = idx.albums.filter((a) => remoteUrlOf(a));
if (limit > 0) candidates = candidates.slice(0, limit);

let ok = 0;
let fail = 0;
let done = 0;
const total = candidates.length;

async function pool(items, n) {
  let i = 0;
  async function worker() {
    while (i < items.length) {
      const a = items[i++];
      const success = await thumbnail(a.id, remoteUrlOf(a));
      if (success) ok++;
      else fail++;
      done++;
      if (done % 50 === 0 || done === total) {
        process.stderr.write(`  mirror ${done}/${total} (ok ${ok}, fail ${fail})\n`);
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker));
}

process.stderr.write(`mirror-art: ${total} albums with a remote cover -> thumbnails in ${artDir}/\n`);
await pool(candidates, concurrency);

if (writeIndex) {
  let rewritten = 0;
  for (const a of idx.albums) {
    const remote = remoteUrlOf(a);
    if (!existsSync(join(artDir, `${a.id}.jpg`))) continue; // only mirrored albums get a CDN source
    const sources = [{ type: 'cdn', url: `${cdnPrefix}/${a.id}.jpg`, cors: true }];
    if (remote) sources.push({ type: 'remote', url: remote, cors: false });
    a.coverArtSources = sources;
    rewritten++;
  }
  writeFileSync(indexPath, JSON.stringify(idx));
  process.stderr.write(`mirror-art: rewrote coverArtSources on ${rewritten} albums -> ${indexPath}\n`);
}

process.stderr.write(`done: mirror-art ok=${ok} fail=${fail} of ${total}\n`);
