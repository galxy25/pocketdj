#!/usr/bin/env node
// scripts/index-digital-files.mjs
// ---------------------------------------------------------------------------
// Indexer for a "digital files" source: a directory tree of raw audio files.
// Folder convention (see docs/design/digital-files-source.md):
//   <root>/<artist>/<album>/<track>.<ext>     album tracks
//   <root>/<artist>/<single>.<ext>            a single (one-track album)
//   <root>/<single>.<ext>                     a single, artist = "Unknown"
//   <album>/[Disc N]/ siblings                merged into ONE album w/ disc numbers
//   a loose image in an album folder          album art (else embedded ID3 art)
// Only audio files DIRECTLY in an album folder are tracks; deeper nesting
// (Ableton project scaffolding etc.) and non-audio/non-image files are ignored.
//
// Produces BOTH artifacts that make a song work end to end:
//   1. public/digital-index.json   (browsable catalog, sourceName "My Digital")
//   2. rips/manifest.json entries  (streamable + burnable from S3, zero rip step)
// and uploads:
//   - rips/<songId>.mp3            256k audio  (PUBLIC rips bucket)
//   - art/<albumId>.jpg            256px cover (web/catalog bucket)
//   - rips/analysis/<songId>.json + rips/waveforms/<songId>.png (via analyzeAudio)
// Manifest writes go THROUGH the rip-server's POST /ingest-digital (the live
// in-memory manifest is the single writer — never edit rips/manifest.json directly).
//
// Stages are resumable & idempotent (stable content-derived ids; each stage skips
// already-done work). Stems are NOT done here — trigger POST /backfill-stems after.
//
// Usage:
//   node scripts/index-digital-files.mjs --root "/Volumes/RipBurnMix 1/Pocket DJ" \
//        [--source-name "My Digital"] [--artist BANKS] [--limit N] \
//        [--no-analyze] [--no-ingest] [--no-publish] [--dry-run] [--env dev]
// ---------------------------------------------------------------------------
import { execFileSync } from 'node:child_process';
import {
  readdirSync, existsSync, mkdirSync, writeFileSync, appendFileSync, readFileSync, statSync,
} from 'node:fs';
import { join, basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { normalize } from '../.claude/skills/analog-indexer/lib/normalize.js';
import { analyzeAudio } from './lib/audio-analyze.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');

// ---------------- args ----------------
function parseArgs(argv) {
  const a = { root: null, sourceName: 'My Digital', artist: null, limit: 0, env: 'dev',
    analyze: true, ingest: true, publish: true, dryRun: false,
    work: join(homedir(), '.pocketdj', 'digital'),
    ripServer: process.env.RIP_SERVER_URL || 'http://127.0.0.1:8787',
    bucket: 'pocketdj-rips-011183829623', region: 'us-west-2', profile: 'levi' };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const next = () => argv[++i];
    if (k === '--root') a.root = next();
    else if (k === '--source-name') a.sourceName = next();
    else if (k === '--artist') a.artist = next();
    else if (k === '--limit') a.limit = Number(next()) || 0;
    else if (k === '--env') a.env = next();
    else if (k === '--work') a.work = next();
    else if (k === '--rip-server') a.ripServer = next();
    else if (k === '--no-analyze') a.analyze = false;
    else if (k === '--no-ingest') a.ingest = false;
    else if (k === '--no-publish') a.publish = false;
    else if (k === '--dry-run') a.dryRun = true;
    else throw new Error(`unknown arg: ${k}`);
  }
  if (!a.root) throw new Error('--root is required');
  if (!existsSync(a.root)) throw new Error(`root not found: ${a.root}`);
  return a;
}
const ARGS = parseArgs(process.argv);
const NS = `digital|${ARGS.sourceName}`;

// ---------------- ids (namespaced by source so digital never collides w/ vinyl/AM) ----------------
const sha1 = (s) => createHash('sha1').update(s).digest('hex');
const albumIdFor = (artist, album) => 'alb_' + sha1(`${NS}|${normalize(artist)}|${normalize(album)}`).slice(0, 12);
const songIdFor = (albId, disc, track) => 'sng_' + sha1(`${albId}|${disc || 1}|${track || 0}`).slice(0, 12);

// ---------------- file classification ----------------
const AUDIO_EXT = new Set(['mp3', 'm4a', 'wav', 'aif', 'aiff', 'flac', 'alac', 'aac', 'ogg', 'oga', 'opus', 'wma']);
const IMAGE_EXT = new Set(['jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'bmp', 'tiff']);
const extOf = (name) => { const m = name.toLowerCase().match(/\.([a-z0-9]+)$/); return m ? m[1] : ''; };
const listDir = (dir) => { try { return readdirSync(dir, { withFileTypes: true }).filter((d) => !d.name.startsWith('.')); } catch { return []; } };

// "Ultimate Aaliyah [Disc 2]" -> { base:"Ultimate Aaliyah", disc:2 }; "CD1" suffix too.
function parseDisc(folder) {
  const m = folder.match(/^(.*?)[\s_-]*[\[(]?\s*(?:disc|cd)\s*(\d+)\s*[\])]?\s*$/i);
  if (m && m[1].trim()) return { base: m[1].trim(), disc: Number(m[2]) };
  return { base: folder, disc: null };
}

// Strip extension + leading "01 " / "1-01 " / "1.01 " track prefixes → a display title.
function cleanTitle(filename) {
  let t = filename.replace(/\.[a-z0-9]+$/i, '');
  t = t.replace(/^\s*\d{1,2}\s*[-_.]\s*\d{1,2}[\s._-]+/, ''); // 1-01 / 1.01
  t = t.replace(/^\s*\d{1,3}[\s._-]+/, '');                    // 01
  return t.trim() || filename.replace(/\.[a-z0-9]+$/i, '');
}
// Leading numeric hint from a filename: "1-05 ..." -> 5, "07 ..." -> 7, else null.
function trackHintFromName(filename) {
  let m = filename.match(/^\s*\d{1,2}\s*[-_.]\s*(\d{1,2})[\s._-]/);
  if (m) return Number(m[1]);
  m = filename.match(/^\s*(\d{1,3})[\s._-]/);
  if (m) return Number(m[1]);
  return null;
}

// ---------------- ffprobe ----------------
function probe(file) {
  try {
    const out = execFileSync('ffprobe', ['-v', 'quiet', '-print_format', 'json',
      '-show_format', '-show_streams', file], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    return JSON.parse(out);
  } catch { return null; }
}
const tag = (tags, name) => {
  if (!tags) return null;
  const k = Object.keys(tags).find((x) => x.toLowerCase() === name);
  const v = k ? tags[k] : null;
  return (v == null || v === '') ? null : String(v);
};
const firstInt = (s) => { if (s == null) return null; const m = String(s).match(/\d+/); return m ? Number(m[0]) : null; };
const hasAttachedPic = (info) => !!(info?.streams || []).some((s) => s.codec_type === 'video' && (s.disposition?.attached_pic === 1 || s.disposition?.attached_pic === true));

// ---------------- walk → flat track candidates ----------------
function walk(root, artistFilter) {
  const out = []; // {folderArtist, srcPath, albumFolderBase, disc, isSingle, albumFolderPath|null}
  for (const top of listDir(root)) {
    const topPath = join(root, top.name);
    if (top.isDirectory()) {
      if (artistFilter && top.name !== artistFilter) continue;
      const folderArtist = top.name;
      for (const sub of listDir(topPath)) {
        const subPath = join(topPath, sub.name);
        if (sub.isDirectory()) {
          const { base, disc } = parseDisc(sub.name);
          for (const f of listDir(subPath)) {
            if (f.isFile() && AUDIO_EXT.has(extOf(f.name)))
              out.push({ folderArtist, srcPath: join(subPath, f.name), albumFolderBase: base, disc: disc || 1, isSingle: false, albumFolderPath: subPath });
          }
        } else if (sub.isFile() && AUDIO_EXT.has(extOf(sub.name))) {
          out.push({ folderArtist, srcPath: subPath, albumFolderBase: null, disc: 1, isSingle: true, albumFolderPath: topPath });
        }
      }
    } else if (top.isFile() && AUDIO_EXT.has(extOf(top.name))) {
      if (artistFilter) continue;
      out.push({ folderArtist: 'Unknown', srcPath: topPath, albumFolderBase: null, disc: 1, isSingle: true, albumFolderPath: root });
    }
  }
  return out;
}

// Pick an album-art SOURCE file: a loose image in the album folder (cover/folder/front
// preferred) wins; else null (caller falls back to embedded ID3 art).
function looseArt(folderPath) {
  const imgs = listDir(folderPath).filter((f) => f.isFile() && IMAGE_EXT.has(extOf(f.name))).map((f) => f.name);
  if (!imgs.length) return null;
  const pref = ['cover', 'folder', 'front', 'album', 'art'];
  imgs.sort((a, b) => {
    const ra = pref.findIndex((p) => a.toLowerCase().startsWith(p));
    const rb = pref.findIndex((p) => b.toLowerCase().startsWith(p));
    return (ra < 0 ? 99 : ra) - (rb < 0 ? 99 : rb) || a.localeCompare(b);
  });
  return join(folderPath, imgs[0]);
}

const SCALE = "scale='if(gt(iw,ih),256,-2)':'if(gt(iw,ih),-2,256)'"; // longest edge -> 256, even dims

async function main() {
  const W = ARGS.work;
  for (const d of ['audio', 'art']) mkdirSync(join(W, d), { recursive: true });
  const analyzedPath = join(W, 'analyzed.jsonl');
  const analyzedCache = new Map();
  if (existsSync(analyzedPath)) {
    for (const line of readFileSync(analyzedPath, 'utf8').split('\n').filter(Boolean)) {
      try { const r = JSON.parse(line); analyzedCache.set(r.songId, r); } catch { /* skip */ }
    }
  }

  const ACCT = ARGS.bucket.split('-').pop(); // 011183829623
  const WEB_BUCKET = `pocketdj-${ARGS.env}-web-${ACCT}`;

  console.error(`▶ Digital indexer — root="${ARGS.root}" source="${ARGS.sourceName}"${ARGS.artist ? ` artist=${ARGS.artist}` : ''}`);
  let candidates = walk(ARGS.root, ARGS.artist);
  console.error(`  walk: ${candidates.length} audio file(s)`);
  if (ARGS.limit) candidates = candidates.slice(0, ARGS.limit);

  // ---- pass 1: read ID3, resolve album/title/track, group ----
  const albums = new Map(); // albumId -> {id, artist, name, year, genre, artFolderPath, coverSrcEmbed, tracks:[]}
  for (const c of candidates) {
    const info = probe(c.srcPath);
    const tags = info?.format?.tags || {};
    const durationSec = Number(info?.format?.duration) || null;
    const fileName = basename(c.srcPath);

    const title = tag(tags, 'title') || cleanTitle(fileName);
    const albumArtist = c.folderArtist;                              // grouping key (stable)
    const songArtist = tag(tags, 'artist') || albumArtist;          // display (may be "feat")
    const albumName = c.isSingle ? (tag(tags, 'album') || title) : (c.albumFolderBase || tag(tags, 'album') || title);
    const disc = firstInt(tag(tags, 'disc')) || c.disc || 1;
    // `||` (not `??`): a literal "0/13" TRCK tag → firstInt 0, which is an invalid track number;
    // fall back to the filename hint (then to sequential) rather than keeping 0.
    const trackHint = firstInt(tag(tags, 'track')) || trackHintFromName(fileName);
    const year = firstInt(tag(tags, 'date')) || firstInt(tag(tags, 'year'));
    const genre = tag(tags, 'genre');

    const albId = albumIdFor(albumArtist, albumName);
    if (!albums.has(albId)) albums.set(albId, { id: albId, artist: albumArtist, name: albumName, year, genre, artFolderPath: c.albumFolderPath, embedPic: null, tracks: [] });
    const alb = albums.get(albId);
    if (!alb.year && year) alb.year = year;
    if (!alb.genre && genre) alb.genre = genre;
    if (!alb.embedPic && hasAttachedPic(info)) alb.embedPic = c.srcPath;
    alb.tracks.push({ srcPath: c.srcPath, title, songArtist, disc, trackHint, durationSec, fileName });
  }

  // ---- assign final, unique track numbers per (album,disc) ----
  for (const alb of albums.values()) {
    const byDisc = new Map();
    for (const t of alb.tracks) { if (!byDisc.has(t.disc)) byDisc.set(t.disc, []); byDisc.get(t.disc).push(t); }
    for (const [disc, list] of byDisc) {
      list.sort((a, b) => (a.trackHint ?? 999) - (b.trackHint ?? 999) || a.fileName.localeCompare(b.fileName));
      const used = new Set();
      let next = 1;
      for (const t of list) {
        let n = t.trackHint;
        if (n == null || used.has(n)) { while (used.has(next)) next++; n = next; }
        used.add(n);
        t.track = n;
        // songId keys on (album, disc, track). For tracks WITHOUT a tag/filename number, `track`
        // is the positional fallback — stable for a FIXED file set (deterministic sort), but it
        // shifts if the album's files change between indexings. That's acceptable for the re-burn
        // workflow (same files); a content-stable id is a future migration (see design doc §11).
        t.songId = songIdFor(alb.id, disc, n);
      }
    }
  }

  // ---- pass 2: transcode + art + upload + analyze; build index + ingest entries ----
  const idxAlbums = [];
  const idxSongs = [];
  const entries = []; // for POST /ingest-digital
  let nTranscoded = 0; let nUploaded = 0; let nAnalyzed = 0; let nArt = 0;

  const aws = (args) => execFileSync('aws', [...args, '--profile', ARGS.profile, '--region', ARGS.region], { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  const s3size = (key, bucket) => { try { const o = JSON.parse(aws(['s3api', 'head-object', '--bucket', bucket, '--key', key])); return Number(o.ContentLength) || 0; } catch { return -1; } };

  for (const alb of [...albums.values()].sort((a, b) => `${a.artist}|${a.name}`.localeCompare(`${b.artist}|${b.name}`))) {
    // --- album art ---
    let coverArt = null;
    const artOut = join(W, 'art', `${alb.id}.jpg`);
    const loose = looseArt(alb.artFolderPath);
    const artSrc = loose || alb.embedPic;        // loose image overrides embedded ID3 art
    alb._artSrc = artSrc;
    if (!ARGS.dryRun && artSrc) {
      try {
        if (!existsSync(artOut)) {
          const isEmbed = !loose && artSrc === alb.embedPic;
          const ffArgs = isEmbed
            ? ['-y', '-i', artSrc, '-map', '0:v:0', '-vf', SCALE, '-frames:v', '1', artOut]
            : ['-y', '-i', artSrc, '-vf', SCALE, '-frames:v', '1', artOut];
          execFileSync('ffmpeg', ffArgs, { stdio: 'ignore' });
        }
        if (existsSync(artOut) && statSync(artOut).size > 0) {
          aws(['s3', 'cp', artOut, `s3://${WEB_BUCKET}/art/${alb.id}.jpg`, '--content-type', 'image/jpeg', '--cache-control', 'public,max-age=31536000,immutable']);
          coverArt = `/art/${alb.id}.jpg`; nArt++;
        }
      } catch (e) { console.error(`  ! art failed for ${alb.artist} — ${alb.name}: ${e.message}`); }
    }

    const trackList = [];
    for (const t of alb.tracks.sort((a, b) => a.disc - b.disc || a.track - b.track)) {
      const mp3 = join(W, 'audio', `${t.songId}.mp3`);
      // --- transcode → 256k mp3 (skip if already produced) ---
      if (!ARGS.dryRun && !(existsSync(mp3) && statSync(mp3).size > 0)) {
        try {
          execFileSync('ffmpeg', ['-y', '-i', t.srcPath, '-map', '0:a:0', '-map_metadata', '-1',
            '-codec:a', 'libmp3lame', '-b:a', '256k',
            '-metadata', `title=${t.title}`, '-metadata', `artist=${t.songArtist}`,
            '-metadata', `album=${alb.name}`, '-metadata', `track=${t.track}`,
            '-id3v2_version', '3', mp3], { stdio: 'ignore' });
          nTranscoded++;
        } catch (e) { console.error(`  ! transcode failed: ${t.srcPath}: ${e.message}`); continue; }
      }
      const bytes = existsSync(mp3) ? statSync(mp3).size : 0;
      const durationMs = t.durationSec ? Math.round(t.durationSec * 1000) : null;
      const key = `rips/${t.songId}.mp3`;

      // --- upload audio (skip if same-size object already in S3) ---
      if (!ARGS.dryRun && bytes > 0 && s3size(key, ARGS.bucket) !== bytes) {
        try { aws(['s3', 'cp', mp3, `s3://${ARGS.bucket}/${key}`, '--content-type', 'audio/mpeg', '--cache-control', 'public,max-age=31536000,immutable']); nUploaded++; }
        catch (e) { console.error(`  ! upload failed: ${key}: ${e.message}`); continue; }
      }

      // --- analyze (BPM/key/camelot + beat grid + waveform), resumable via analyzed.jsonl ---
      let an = analyzedCache.get(t.songId) || null;
      if (ARGS.analyze && !ARGS.dryRun && !an && bytes > 0) {
        try {
          const r = await analyzeAudio({ file: mp3, songId: t.songId, bucket: ARGS.bucket, region: ARGS.region, profile: ARGS.profile, withKey: true, withWaveform: true, withBeatgrid: true });
          const got = { songId: t.songId, bpm: r.bpm, musicalKey: r.musicalKey, camelot: r.camelot, waveform: r.waveform, beatgrid: r.beatgrid, beatgridKey: r.beatgridKey };
          // analyzeAudio is best-effort and NEVER throws — a Docker/ffmpeg failure returns all-null.
          // Caching that would mark the song "analyzed" and skip it forever. Only cache a real result
          // so a transient failure (Docker down) is retried on the next run.
          if (got.bpm == null && got.musicalKey == null && !got.beatgrid && !got.waveform) {
            console.error(`  ~ analysis empty (will retry next run): ${t.songId}`);
          } else {
            an = got;
            appendFileSync(analyzedPath, JSON.stringify(an) + '\n');
            analyzedCache.set(t.songId, an); nAnalyzed++;
          }
        } catch (e) { console.error(`  ! analyze failed: ${t.songId}: ${e.message}`); }
      }

      // --- index song + ingest entry ---
      idxSongs.push({
        id: t.songId, albumId: alb.id, artist: t.songArtist, name: t.title,
        trackNumber: t.track, year: alb.year || null,
        bpm: an?.bpm ?? null, key: an?.musicalKey ?? null, camelot: an?.camelot ?? null,
        length: durationMs, fileType: 'mp3', pointer: { disc: t.disc, track: t.track, timestamps: null },
      });
      entries.push({
        songId: t.songId, key, source: 'digital', albumId: alb.id, ext: 'mp3',
        durationMs, bytes: bytes || null, name: t.title, artist: t.songArtist,
        bpm: an?.bpm ?? null, musicalKey: an?.musicalKey ?? null, camelot: an?.camelot ?? null,
        waveform: an?.waveform ?? null, beatgrid: an?.beatgrid ?? null, beatgridKey: an?.beatgridKey ?? null,
      });
      trackList.push(t.songId);
    }

    idxAlbums.push({ id: alb.id, artist: alb.artist, name: alb.name, coverArt, genre: alb.genre || null, year: alb.year || null, trackList, fileType: 'mp3' });
  }

  // ---- assemble + write index ----
  const index = {
    manifest: {
      source: 'Digital Audio Files', generatedAt: new Date().toISOString(), schemaVersion: '1.0.0',
      sourceType: 'digital', sourceName: ARGS.sourceName,
      counts: { albums: idxAlbums.length, songs: idxSongs.length },
      deferredFields: ['lyrics', 'sentimentKeywords', 'stems'],
    },
    albums: idxAlbums, songs: idxSongs, playlists: [],
  };
  const outIndex = join(REPO, 'public', 'digital-index.json');
  if (!ARGS.dryRun) writeFileSync(outIndex, JSON.stringify(index));
  else writeFileSync(join(W, 'dry-index.json'), JSON.stringify(index));   // for id-churn diffing
  console.error(`  index: ${idxAlbums.length} albums, ${idxSongs.length} songs`);
  console.error(`  transcoded=${nTranscoded} uploaded=${nUploaded} art=${nArt} analyzed=${nAnalyzed}`);

  if (ARGS.dryRun) {
    for (const al of idxAlbums) {
      const alb = albums.get(al.id);
      const art = alb?._artSrc ? (looseArt(alb.artFolderPath) ? 'loose-img' : 'embedded') : 'NO ART';
      console.error(`\n  ${al.artist} — ${al.name}  [${al.id}]  (${al.trackList.length} tracks · ${al.year || '?'} · ${al.genre || '?'} · art:${art})`);
      for (const sid of al.trackList) {
        const s = idxSongs.find((x) => x.id === sid);
        console.error(`     ${s.pointer.disc}-${String(s.trackNumber).padStart(2, '0')}  ${s.name}  «${s.artist}»  ${s.length ? Math.round(s.length / 1000) + 's' : '?'}`);
      }
    }
  }

  // ---- POST /ingest-digital (the rip-server merges into the live manifest) ----
  if (ARGS.ingest && !ARGS.dryRun && entries.length) {
    ingest(entries).then((r) => console.error(`  ingest: ${JSON.stringify(r)}`))
      .catch((e) => console.error(`  ! ingest failed: ${e.message} — retry: curl -XPOST ${ARGS.ripServer}/ingest-digital`));
  }

  // ---- publish index + invalidate CloudFront ----
  if (ARGS.publish && !ARGS.dryRun) {
    try {
      aws(['s3', 'cp', outIndex, `s3://${WEB_BUCKET}/digital-index.json`, '--content-type', 'application/json', '--cache-control', 'no-cache']);
      const CF = ARGS.env === 'prod' ? 'E1SP8M1SIF7Q8D' : 'E123GKAO9JVETP';
      aws(['cloudfront', 'create-invalidation', '--distribution-id', CF, '--paths', '/digital-index.json']);
      console.error(`  published digital-index.json -> ${WEB_BUCKET} (CF ${CF} invalidated)`);
    } catch (e) { console.error(`  ! publish failed: ${e.message}`); }
  }
  console.error('✓ done');
}

/// /ingest-digital sits behind the rip server's ADMIN tier since the public (Funnel)
/// promotion. Unattended runs (digital-sync-nightly) read the same machine-local env
/// file the server does; explicit env vars win. No token (fresh dev box) ⇒ no header,
/// which a tokenless local server accepts.
function authHeader() {
  let token = process.env.RIP_ADMIN_TOKEN || process.env.RIP_TOKEN || '';
  if (!token) {
    try {
      const env = readFileSync(join(homedir(), '.pocketdj', 'rip-server.env'), 'utf8');
      token = env.match(/^RIP_ADMIN_TOKEN=(.+)$/m)?.[1]?.trim()
        || env.match(/^RIP_TOKEN=(.+)$/m)?.[1]?.trim() || '';
    } catch { /* no env file — tokenless local dev */ }
  }
  return token ? { authorization: `Bearer ${token}` } : {};
}

async function ingest(entries) {
  // Chunk so a giant body doesn't strain the server; each chunk saves once.
  const out = { added: 0, updated: 0, skipped: 0 };
  for (let i = 0; i < entries.length; i += 200) {
    const chunk = entries.slice(i, i + 200);
    const res = await fetch(`${ARGS.ripServer}/ingest-digital`, {
      method: 'POST', headers: { 'content-type': 'application/json', ...authHeader() },
      body: JSON.stringify({ entries: chunk }),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const j = await res.json();
    out.added += j.added || 0; out.updated += j.updated || 0; out.skipped += j.skipped || 0;
  }
  return out;
}

await main();
