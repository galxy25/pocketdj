#!/usr/bin/env node
// fold-streaming-links — stamp the browser-resolved Spotify + YouTube (and, for the vinyl/
// digital indexes that lack an appleMusicId, Apple Music) canonical links from the resolver's
// ndjson cache (scripts/resolve-streaming-links.mjs) back into the CATALOG indexes the app
// reads. Sibling of fold-cloud-analysis.mjs / fold-cloud-lyrics.mjs: non-null-only, idempotent,
// side-output by default, --apply rewrites public/, --upload republishes the changed indexes.
//
// PRECEDENCE / SAFETY: only a NON-NULL cached url is stamped, and only when it differs from the
// catalog's current value — a per-service MISS (null in the cache) never erases an existing link,
// and a re-run after more of the catalog resolves touches only the newly-filled rows. The
// id-derived Apple Music links (fold-apple-music-links.mjs) already own `appleMusicUrl` on the
// Apple Music index; the cache only carries `appleMusicUrl` for songs a resolver run explicitly
// looked up (vinyl/digital), so the two folds compose without fighting.
//
// The cache is keyed by song id, so a single cache can back a fold across every index; each
// song is matched by id within whichever index(es) contain it.
//
// Usage:
//   node scripts/fold-streaming-links.mjs                       # dry run + report (no public/ write)
//   node scripts/fold-streaming-links.mjs --dry-run             # report counts only, write NOTHING
//   node scripts/fold-streaming-links.mjs --apply               # rewrite public/ index(es)
//   node scripts/fold-streaming-links.mjs --apply --upload dev,prod
//   [--cache FILE] [--limit N]

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync, createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, resolve, join, basename } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { homedir } from 'node:os';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const AWS_PROFILE = process.env.AWS_PROFILE || 'levi';
const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);
// Test seam: POCKETDJ_FOLD_INDEXES (comma list) + POCKETDJ_FOLD_OUT.
const INDEXES = process.env.POCKETDJ_FOLD_INDEXES
  ? process.env.POCKETDJ_FOLD_INDEXES.split(',').map((s) => s.trim()).filter(Boolean)
  : ['public/current-index.json', 'public/apple-music-index.json', 'public/digital-index.json'];
// Per-index CDN home (mirrors deploy.sh:77-78): vinyl + Apple Music → PROD, My Digital → DEV.
const INDEX_ENV = {
  'current-index.json': 'prod',
  'apple-music-index.json': 'prod',
  'digital-index.json': 'dev',
};
// Fields we fold, and which entity carries them.
const URL_FIELDS = ['appleMusicUrl', 'spotifyUrl', 'youtubeUrl'];

const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const has = (f) => process.argv.includes(f);
const apply = has('--apply');
const dryRun = has('--dry-run');
const uploadEnvs = (arg('--upload', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const limit = arg('--limit') ? parseInt(arg('--limit'), 10) : Infinity;
const cachePath = resolve(expand(arg('--cache', 'index-out/streaming-links/links-cache.ndjson')));

const outRoot = process.env.POCKETDJ_FOLD_OUT || join(REPO, 'index-out', 'streaming-links-fold');

async function loadCache(file) {
  const map = new Map();
  if (!existsSync(file)) return map;
  const rl = createInterface({ input: createReadStream(file, { encoding: 'utf8' }), crlfDelay: Infinity });
  for await (const ln of rl) {
    if (!ln.trim()) continue;
    try { const o = JSON.parse(ln); if (o.id) map.set(o.id, { ...(map.get(o.id) || {}), ...o }); } catch { /* skip bad line */ }
  }
  return map;
}

async function main() {
  if (!existsSync(cachePath)) { console.error('cache not found:', cachePath, '\n(run scripts/resolve-streaming-links.mjs first)'); process.exit(1); }
  const cache = await loadCache(cachePath);
  if (!dryRun) mkdirSync(outRoot, { recursive: true });
  const report = { generatedAt: new Date().toISOString(), apply, dryRun, cache: cachePath, cached: cache.size, indexes: {}, stamped: 0 };

  for (const rel of INDEXES) {
    const path = rel.startsWith('/') ? rel : join(REPO, rel);
    if (!existsSync(path)) continue;
    const idx = JSON.parse(readFileSync(path, 'utf8'));
    const r = { songs: (idx.songs || []).length, matched: 0, stamped: 0, already: 0,
                byField: Object.fromEntries(URL_FIELDS.map((f) => [f, 0])) };
    let n = 0;
    for (const s of idx.songs || []) {
      const rec = cache.get(s.id);
      if (!rec) continue;
      r.matched++;
      if (n >= limit) continue;
      let changed = false;
      for (const f of URL_FIELDS) {
        const v = rec[f];
        if (v == null) continue;                 // a miss never NULLs an existing link
        if (s[f] === v) { r.already++; continue; }
        s[f] = v; r.byField[f]++; changed = true;
      }
      if (changed) { r.stamped++; report.stamped++; n++; }
    }
    report.indexes[rel] = r;
    if (r.stamped > 0 && !dryRun) {
      const dest = apply ? path : join(outRoot, basename(rel));
      writeFileSync(dest, JSON.stringify(idx));
      r.wrote = apply ? rel : dest;
    }
  }

  if (!dryRun) writeFileSync(join(outRoot, 'report.json'), JSON.stringify(report, null, 2));
  console.error(JSON.stringify(report, null, 2));

  if (uploadEnvs.length && apply && !dryRun && report.stamped > 0) publish(report, uploadEnvs);
}

function publish(report, envs) {
  const acct = execFileSync('aws', ['sts', 'get-caller-identity', '--profile', AWS_PROFILE,
    '--query', 'Account', '--output', 'text'], { encoding: 'utf8' }).trim();
  const cf = { dev: process.env.CF_ID_DEV || 'E123GKAO9JVETP', prod: process.env.CF_ID_PROD || 'E1SP8M1SIF7Q8D' };
  const changed = Object.entries(report.indexes).filter(([, r]) => r.stamped > 0).map(([rel]) => rel);
  const byEnv = {};
  for (const rel of changed) {
    const home = INDEX_ENV[basename(rel)];
    if (!home || !envs.includes(home)) continue;
    (byEnv[home] ||= []).push(rel);
  }
  for (const [env, rels] of Object.entries(byEnv)) {
    const bucket = `pocketdj-${env}-web-${acct}`;
    for (const rel of rels) {
      const name = basename(rel);
      console.error(`▶ Publishing ${name} (streaming links) -> s3://${bucket}/${name} …`);
      execFileSync('aws', ['s3', 'cp', join(REPO, rel), `s3://${bucket}/${name}`,
        '--profile', AWS_PROFILE, '--content-type', 'application/json', '--cache-control', 'no-cache',
        '--only-show-errors'], { stdio: 'inherit' });
    }
    if (cf[env]) {
      try {
        execFileSync('aws', ['cloudfront', 'create-invalidation', '--distribution-id', cf[env],
          '--paths', ...rels.map((rel) => `/${basename(rel)}`), '--profile', AWS_PROFILE,
          '--query', 'Invalidation.Id', '--output', 'text'], { encoding: 'utf8' });
      } catch { /* best-effort (no-cache is the backstop) */ }
    }
    console.error(`✓ Streaming links published to [${env}] (${rels.map(basename).join(', ')})`);
  }
}

if (import.meta.url === (process.argv[1] ? pathToFileURL(process.argv[1]).href : '')) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
