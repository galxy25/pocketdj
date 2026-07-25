#!/usr/bin/env node
// fold-apple-music-links — the F3 "Sharing" pipeline's FIRST, cheapest step. Derive each
// song's / album's canonical Apple Music deep-link (`appleMusicUrl`) DIRECTLY from the
// `appleMusicId` already resolved into the catalog (scripts/resolve-apple-music-catalog.mjs
// + fold-album-catalogid.mjs). No browser, no network, no API — a pure string derivation:
//
//   song:  appleMusicId "1771724281" -> https://music.apple.com/song/1771724281
//   album: appleMusicId "1771723600" -> https://music.apple.com/album/1771723600
//
// Both short forms 301-redirect on music.apple.com to the fully-localized canonical URL
// (…/us/song/<slug>/<id>), so they ARE valid canonical links and stay storefront-neutral.
//
// Only the "Apple Music (Local)" index carries appleMusicId today (~75k songs / ~9k albums);
// the vinyl + digital indexes have none, so their `appleMusicUrl` stays unset here and is
// filled (if ever) by the browser resolver's fold (scripts/fold-streaming-links.mjs).
//
// IDEMPOTENT: stamps `appleMusicUrl` only when missing or different from the derived value, so
// re-running after more ids resolve touches only the newly-eligible rows.
//
// SAFETY: dry-run by default (side-output under index-out/apple-music-links/<index>.json +
// report; nothing in public/ changes). --apply rewrites the public/ index(es) in place (the
// human commits + deploy ships them). --dry-run forces report-only (not even the side-output).
// --upload routes each CHANGED index to its home web bucket + CloudFront and invalidates it
// (current-index + apple-music-index live in PROD, digital-index in DEV — see deploy.sh:77-78).
//
// Usage:
//   node scripts/fold-apple-music-links.mjs                     # report + side-output (no public/ write)
//   node scripts/fold-apple-music-links.mjs --dry-run           # report counts only, write NOTHING
//   node scripts/fold-apple-music-links.mjs --apply             # rewrite public/ index(es)
//   node scripts/fold-apple-music-links.mjs --apply --upload dev,prod
//   [--limit N]

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve, join, basename } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const AWS_PROFILE = process.env.AWS_PROFILE || 'levi';
// Test seam: POCKETDJ_FOLD_INDEXES (comma list, absolute or repo-relative) + POCKETDJ_FOLD_OUT.
const INDEXES = process.env.POCKETDJ_FOLD_INDEXES
  ? process.env.POCKETDJ_FOLD_INDEXES.split(',').map((s) => s.trim()).filter(Boolean)
  : ['public/current-index.json', 'public/apple-music-index.json', 'public/digital-index.json'];

// Per-index CDN home (mirrors deploy.sh:77-78 + digital-sync-nightly.sh): the vinyl + Apple
// Music indexes are served from the PROD web bucket/distribution; "My Digital" from DEV.
const INDEX_ENV = {
  'current-index.json': 'prod',
  'apple-music-index.json': 'prod',
  'digital-index.json': 'dev',
};

const arg = (f, d) => { const i = process.argv.indexOf(f); return i >= 0 ? process.argv[i + 1] : d; };
const has = (f) => process.argv.includes(f);
const apply = has('--apply');
const dryRun = has('--dry-run');
const uploadEnvs = (arg('--upload', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const limit = arg('--limit') ? parseInt(arg('--limit'), 10) : Infinity;

// Canonical short-form deep-links (301 → localized canonical on music.apple.com).
export const songUrl = (id) => `https://music.apple.com/song/${id}`;
export const albumUrl = (id) => `https://music.apple.com/album/${id}`;

const outRoot = process.env.POCKETDJ_FOLD_OUT || join(REPO, 'index-out', 'apple-music-links');

function main() {
  if (!dryRun) mkdirSync(outRoot, { recursive: true });
  const report = { generatedAt: new Date().toISOString(), apply, dryRun, indexes: {}, stampedSongs: 0, stampedAlbums: 0 };

  for (const rel of INDEXES) {
    const path = rel.startsWith('/') ? rel : join(REPO, rel);
    if (!existsSync(path)) continue;
    const idx = JSON.parse(readFileSync(path, 'utf8'));
    const songs = idx.songs || [];
    const albums = idx.albums || [];
    const r = {
      songs: songs.length, albums: albums.length,
      songsWithId: 0, albumsWithId: 0,
      songsStamped: 0, albumsStamped: 0, songsAlready: 0, albumsAlready: 0,
    };
    let n = 0;
    for (const s of songs) {
      if (!s.appleMusicId) continue;
      r.songsWithId++;
      if (n >= limit) continue;
      const want = songUrl(s.appleMusicId);
      if (s.appleMusicUrl === want) { r.songsAlready++; continue; }
      s.appleMusicUrl = want; r.songsStamped++; n++;
    }
    let m = 0;
    for (const a of albums) {
      if (!a.appleMusicId) continue;
      r.albumsWithId++;
      if (m >= limit) continue;
      const want = albumUrl(a.appleMusicId);
      if (a.appleMusicUrl === want) { r.albumsAlready++; continue; }
      a.appleMusicUrl = want; r.albumsStamped++; m++;
    }
    report.indexes[rel] = r;
    report.stampedSongs += r.songsStamped;
    report.stampedAlbums += r.albumsStamped;

    const changed = r.songsStamped + r.albumsStamped > 0;
    if (changed && !dryRun) {
      const dest = apply ? path : join(outRoot, basename(rel));
      writeFileSync(dest, JSON.stringify(idx));
      r.wrote = apply ? rel : dest;
    }
  }

  if (!dryRun) writeFileSync(join(outRoot, 'report.json'), JSON.stringify(report, null, 2));
  console.error(JSON.stringify(report, null, 2));

  // ---- CDN publish: route each CHANGED index to its home env's bucket + invalidate ----
  // Only with --apply (public/ must already carry the folded urls) and a real change.
  if (uploadEnvs.length && apply && !dryRun && (report.stampedSongs + report.stampedAlbums) > 0) {
    publish(report, uploadEnvs);
  }
}

function publish(report, envs) {
  const acct = execFileSync('aws', ['sts', 'get-caller-identity', '--profile', AWS_PROFILE,
    '--query', 'Account', '--output', 'text'], { encoding: 'utf8' }).trim();
  const cf = { dev: process.env.CF_ID_DEV || 'E123GKAO9JVETP', prod: process.env.CF_ID_PROD || 'E1SP8M1SIF7Q8D' };
  const changed = Object.entries(report.indexes)
    .filter(([, r]) => (r.songsStamped + r.albumsStamped) > 0)
    .map(([rel]) => rel);
  // Group changed indexes by their home env, honouring the --upload filter.
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
      console.error(`▶ Publishing ${name} (apple-music links) -> s3://${bucket}/${name} …`);
      execFileSync('aws', ['s3', 'cp', join(REPO, rel), `s3://${bucket}/${name}`,
        '--profile', AWS_PROFILE, '--content-type', 'application/json', '--cache-control', 'no-cache',
        '--only-show-errors'], { stdio: 'inherit' });
    }
    if (cf[env]) {
      try {
        execFileSync('aws', ['cloudfront', 'create-invalidation', '--distribution-id', cf[env],
          '--paths', ...rels.map((rel) => `/${basename(rel)}`), '--profile', AWS_PROFILE,
          '--query', 'Invalidation.Id', '--output', 'text'], { encoding: 'utf8' });
      } catch { /* invalidation is best-effort (no-cache is the backstop) */ }
    }
    console.error(`✓ Apple Music links published to [${env}] (${rels.map(basename).join(', ')})`);
  }
}

if (import.meta.url === (process.argv[1] ? pathToFileURL(process.argv[1]).href : '')) {
  main();
}
