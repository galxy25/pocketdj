#!/usr/bin/env node
// e2e of the Discover ▸ Albums server surface — no S3, no worker, no real iTunes.
// A tiny fake "iTunes" HTTP server stands in for the Apple search/lookup API (pointed
// at via RIP_SEARCH_BASE / RIP_LOOKUP_BASE), so the rip-server's mapping is exercised
// deterministically. Asserts:
//   • GET /search (no entity)            → SONG envelope, backward compatible (unchanged)
//   • GET /search?entity=album           → album shape (collectionId → appleMusicId,
//                                           amrec_album_<id>, title/artist/artwork/trackCount/year)
//   • GET /album-tracks?id=<collectionId> → ordered track list (collection row dropped,
//                                           tracks sorted by trackNumber, id = trackId)
//
//   node scripts/test/discover-album-e2e.mjs
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 8850;
const FAKE_PORT = 8851;
const base = `http://localhost:${PORT}`;
const fakeBase = `http://localhost:${FAKE_PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fail = 0;
const ok = (c, m) => { console.log(`${c ? '  ✓' : '  ✗'} ${m}`); if (!c) fail++; };

// ── Fake iTunes API ──────────────────────────────────────────────────────────
// /search echoes the `entity` it was asked for; /lookup returns a collection row
// followed by two out-of-order tracks (so the sort is actually tested).
const fake = http.createServer((req, res) => {
  const u = new URL(req.url, fakeBase);
  const j = (obj) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
  if (u.pathname === '/search') {
    const entity = u.searchParams.get('entity');
    if (entity === 'album') {
      return j({ resultCount: 1, results: [{
        wrapperType: 'collection', collectionType: 'Album',
        collectionId: 1440913169, collectionName: 'Random Access Memories',
        artistName: 'Daft Punk', artworkUrl100: 'https://art.test/ram100.jpg',
        trackCount: 13, releaseDate: '2013-05-17T07:00:00Z',
        collectionViewUrl: 'https://music.apple.com/us/album/1440913169',
      }] });
    }
    return j({ resultCount: 1, results: [{
      wrapperType: 'track', kind: 'song', trackId: 1440913170,
      trackName: 'Get Lucky', artistName: 'Daft Punk', collectionName: 'Random Access Memories',
      artworkUrl100: 'https://art.test/gl100.jpg', trackTimeMillis: 369000,
    }] });
  }
  if (u.pathname === '/lookup') {
    // collection row first (must be dropped), then two tracks OUT of order.
    return j({ resultCount: 3, results: [
      { wrapperType: 'collection', collectionId: 1440913169, collectionName: 'Random Access Memories', artistName: 'Daft Punk' },
      { wrapperType: 'track', kind: 'song', trackId: 1440913172, trackName: 'Instant Crush', artistName: 'Daft Punk', trackNumber: 5, trackTimeMillis: 337000 },
      { wrapperType: 'track', kind: 'song', trackId: 1440913170, trackName: 'Give Life Back to Music', artistName: 'Daft Punk', trackNumber: 1, trackTimeMillis: 275000 },
    ] });
  }
  res.writeHead(404); res.end('nope');
});

const work = mkdtempSync(join(tmpdir(), 'pdj-discalbum-'));
const catalog = join(work, 'catalog.json');
writeFileSync(catalog, JSON.stringify({ manifest: { sourceType: 'digital', sourceName: 'Test' }, albums: [], songs: [] }));

const env = {
  ...process.env,
  RIP_PORT: String(PORT),
  RIP_BUCKET: 'pocketdj-test-nonexistent-bucket-xyz',
  RIP_SOURCES: catalog,
  HOME: join(work, 'home'),
  RIP_SEARCH_BASE: `${fakeBase}/search`,
  RIP_LOOKUP_BASE: `${fakeBase}/lookup`,
};
delete env.RIP_PUBLIC; delete env.RIP_TOKEN; delete env.RIP_ADMIN_TOKEN; delete env.RIP_RATE_LIMIT;

async function main() {
  await new Promise((r) => fake.listen(FAKE_PORT, r));
  const p = spawn('node', [join(REPO, 'scripts/rip-server.mjs')], { env, stdio: ['ignore', 'inherit', 'inherit'] });
  try {
    for (let i = 0; i < 50; i++) {
      try { const r = await fetch(`${base}/health`); if (r.ok) break; } catch { /* not yet */ }
      await sleep(200);
    }

    // 1) Backward-compatible SONG search (no entity param).
    {
      const r = await fetch(`${base}/search?q=get%20lucky`);
      const body = await r.json();
      const hit = (body.results || [])[0] || {};
      ok(r.status === 200, 'GET /search (no entity) → 200');
      ok(hit.songId === 'amrec_1440913170', `song hit keeps amrec_ songId (${hit.songId})`);
      ok(hit.appleMusicId === '1440913170', 'song appleMusicId = trackId');
      ok(hit.durationMs === 369000 && hit.album === 'Random Access Memories', 'song fields mapped');
      ok(hit.albumId === undefined, 'song shape has no albumId (unchanged envelope)');
    }

    // 2) Album search.
    {
      const r = await fetch(`${base}/search?entity=album&q=random%20access`);
      const body = await r.json();
      const a = (body.results || [])[0] || {};
      ok(r.status === 200, 'GET /search?entity=album → 200');
      ok(a.appleMusicId === '1440913169', `album appleMusicId = collectionId (${a.appleMusicId})`);
      ok(a.albumId === 'amrec_album_1440913169', `album provisional id = amrec_album_<id> (${a.albumId})`);
      ok(a.title === 'Random Access Memories' && a.artist === 'Daft Punk', 'album title/artist mapped');
      ok(a.artworkUrl === 'https://art.test/ram100.jpg', 'album artwork mapped');
      ok(a.trackCount === 13, 'album trackCount mapped');
      ok(a.year === 2013, `album year parsed from releaseDate (${a.year})`);
      ok(a.url === 'https://music.apple.com/us/album/1440913169', 'album deep-link (collectionViewUrl) mapped');
      ok(a.songId === undefined && a.ripped === undefined, 'album shape carries no per-song ripped/url');
    }

    // 3) Album-track expansion.
    {
      const r = await fetch(`${base}/album-tracks?id=1440913169`);
      const body = await r.json();
      const t = body.tracks || [];
      ok(r.status === 200, 'GET /album-tracks → 200');
      ok(t.length === 2, `collection row dropped, 2 tracks returned (${t.length})`);
      ok(t[0].trackNumber === 1 && t[1].trackNumber === 5, 'tracks sorted by trackNumber');
      ok(t[0].id === '1440913170' && t[0].title === 'Give Life Back to Music', 'track id = trackId, title mapped');
      ok(t[0].durationMs === 275000, 'track durationMs mapped');
    }

    // 4) Missing id → 400.
    {
      const r = await fetch(`${base}/album-tracks`);
      ok(r.status === 400, 'GET /album-tracks with no id → 400');
    }
  } finally {
    if (p.exitCode === null && p.signalCode === null) {
      const gone = new Promise((r) => p.once('exit', r));
      p.kill('SIGTERM');
      await gone;
    }
    await new Promise((r) => fake.close(r));
  }
  console.log(fail === 0 ? '\nDiscover-album e2e: PASS' : `\nDiscover-album e2e: ${fail} FAILED`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
