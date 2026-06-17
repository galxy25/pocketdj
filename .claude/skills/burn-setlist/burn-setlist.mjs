#!/usr/bin/env node
// burn-setlist — turn a PocketDJ setlist export (CSV) into a folder of ready-to-mix
// audio files, one per song, each carved out of its raw vinyl rip using the
// segment boundaries (pointer.startMs/endMs) stored in the music index. Every audio
// file gets a sidecar .txt with the same basename holding the song's metadata.
//
// Usage:
//   node burn-setlist.mjs --setlist <csv> [options]
//
// Options:
//   --setlist <csv>      Setlist export CSV (required). Must have a "Song ID" column.
//   --index <json>       Music index (default: public/current-index.json)
//   --source <dir>       Folder holding the raw vinyl rips (default: /Volumes/RipBurnMix)
//   --out <dir>          Base output dir; a subfolder named after the setlist is created
//                        inside it (default: current working directory)
//   --name <str>         Override the setlist folder name (default: CSV basename)
//   --format <ext>       Output audio format: mp3 | wav | aiff | flac | m4a (default: mp3)
//   --bitrate <rate>     Bitrate for lossy formats (default: 320k)
//   --codec copy         Stream-copy instead of re-encoding (keeps source format; fast,
//                        cuts on the nearest frame). Default is accurate re-encode.
//   --jobs <n>           Parallel ffmpeg jobs (default: 4)
//   --limit <n>          Only burn the first n songs (handy for a test run)
//   --dry-run            Plan only: write the .txt sidecars + manifest, skip audio.
//   --overwrite          Re-burn audio even if the output file already exists.
//
// Output folder contains, per song: "NN - Artist - Title.<ext>" + "NN - Artist - Title.txt",
// plus "setlist.m3u8" (play order) and "burn-manifest.json" (machine-readable summary).

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

// ---------- arg parsing ----------
function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const flags = new Set(['dry-run', 'overwrite']);
    if (key === 'codec') { out.codec = argv[++i]; continue; }
    if (flags.has(key)) { out[key] = true; continue; }
    out[key] = argv[++i];
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const SETLIST = args.setlist;
const INDEX = args.index || 'public/current-index.json';
const SOURCE = args.source || '/Volumes/RipBurnMix';
const OUT_BASE = args.out || process.cwd();
const FORMAT = (args.format || 'mp3').toLowerCase();
const BITRATE = args.bitrate || '320k';
const COPY = args.codec === 'copy';
const JOBS = Math.max(1, parseInt(args.jobs || '4', 10));
const LIMIT = args.limit ? parseInt(args.limit, 10) : Infinity;
const DRY = !!args['dry-run'];
const OVERWRITE = !!args.overwrite;

function die(msg) { console.error(`\n✗ ${msg}\n`); process.exit(1); }
if (!SETLIST) die('Missing --setlist <csv>. See header of this script for usage.');
if (!fs.existsSync(SETLIST)) die(`Setlist CSV not found: ${SETLIST}`);
if (!fs.existsSync(INDEX)) die(`Index not found: ${INDEX}`);
if (!DRY && !fs.existsSync(SOURCE)) die(`Source dir not found: ${SOURCE}  (is the drive mounted?)`);

// ---------- tiny CSV parser (handles quotes, commas, doubled quotes) ----------
function parseCSV(text) {
  const rows = [];
  let row = [], field = '', inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; }
        else inQuotes = false;
      } else field += c;
    } else if (c === '"') inQuotes = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (c === '\r') { /* skip */ }
    else field += c;
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  return rows.filter(r => r.length > 1 || (r.length === 1 && r[0] !== ''));
}

// ---------- filesystem-safe names ----------
function safeName(s) {
  return String(s)
    .replace(/[\/\\:*?"<>|]/g, '-')   // reserved on common filesystems
    .replace(/[\x00-\x1f]/g, '')       // control chars
    .replace(/\s+/g, ' ')
    .replace(/\.+$/, '')               // no trailing dots
    .trim()
    .slice(0, 120);
}

function msToClock(ms) {
  if (ms == null) return '—';
  const totalSec = ms / 1000;
  const m = Math.floor(totalSec / 60);
  const s = (totalSec - m * 60);
  return `${m}:${s.toFixed(3).padStart(6, '0')}`;
}

// ---------- load index ----------
const idx = JSON.parse(fs.readFileSync(INDEX, 'utf8'));
const songById = new Map((idx.songs || []).map(s => [s.id, s]));
const albumById = new Map((idx.albums || []).map(a => [a.id, a]));

// ---------- parse setlist ----------
const rows = parseCSV(fs.readFileSync(SETLIST, 'utf8'));
if (!rows.length) die('Setlist CSV is empty.');
const header = rows[0].map(h => h.trim());
const colIdx = (name) => header.findIndex(h => h.toLowerCase() === name.toLowerCase());
const cSongId = colIdx('Song ID');
if (cSongId < 0) die('Setlist CSV has no "Song ID" column.');
const cNum = colIdx('#');
const cArtist = colIdx('Artist');
const cTitle = colIdx('Title');
const cBpm = colIdx('BPM');
const cKey = colIdx('Key');
const cLen = colIdx('Length');
const cSource = colIdx('Source');
const cSeq = colIdx('Sequence');

const setName = safeName(args.name || path.basename(SETLIST).replace(/\.[^.]+$/, '')) || 'setlist';
const OUT_DIR = path.join(OUT_BASE, setName);
fs.mkdirSync(OUT_DIR, { recursive: true });

// ---------- build the work list ----------
const dataRows = rows.slice(1).slice(0, LIMIT);
const pad = String(dataRows.length).length;
const jobsList = [];
const problems = [];

dataRows.forEach((r, i) => {
  const songId = (r[cSongId] || '').trim();
  const pos = cNum >= 0 ? (r[cNum] || '').trim() : String(i + 1);
  const csvArtist = cArtist >= 0 ? r[cArtist] : '';
  const csvTitle = cTitle >= 0 ? r[cTitle] : '';
  const song = songById.get(songId);
  if (!song) { problems.push(`row ${pos}: song id ${songId} (${csvArtist} – ${csvTitle}) not in index`); return; }
  const ptr = song.pointer || {};
  if (!ptr.filename) { problems.push(`row ${pos}: ${song.artist} – ${song.name} has no source filename in index`); return; }
  if (ptr.startMs == null || ptr.endMs == null) { problems.push(`row ${pos}: ${song.artist} – ${song.name} has no segment timestamps`); return; }
  const album = albumById.get(song.albumId);
  const order = String(pos).padStart(pad, '0');
  const base = safeName(`${order} - ${song.artist || csvArtist} - ${song.name || csvTitle}`);
  jobsList.push({
    order, pos, song, album, ptr, base,
    csv: {
      bpm: cBpm >= 0 ? r[cBpm] : '', key: cKey >= 0 ? r[cKey] : '',
      length: cLen >= 0 ? r[cLen] : '', source: cSource >= 0 ? r[cSource] : '',
      sequence: cSeq >= 0 ? r[cSeq] : '',
    },
    audioExt: COPY ? (song.fileType || path.extname(ptr.filename).slice(1) || 'mp3') : FORMAT,
  });
});

console.log(`\nBurning "${setName}" → ${OUT_DIR}`);
console.log(`  songs: ${jobsList.length}/${dataRows.length}   source: ${SOURCE}   format: ${COPY ? 'copy' : FORMAT + ' @ ' + BITRATE}${DRY ? '   [DRY RUN]' : ''}`);
if (problems.length) {
  console.log(`\n  ⚠ ${problems.length} song(s) skipped:`);
  for (const p of problems) console.log(`     - ${p}`);
}
console.log('');

// ---------- sidecar metadata text ----------
function buildSidecar(j) {
  const { song, album, ptr, csv } = j;
  const camelot = song.camelot || '—';
  const key = song.key || '—';
  const sentiment = (song.sentimentKeywords || []).join(', ') || '—';
  const albumName = album?.name || '—';
  const durMs = (ptr.endMs - ptr.startMs);

  const L = [];
  L.push(`${song.artist || ''} — ${song.name || ''}`);
  L.push('='.repeat(60));
  L.push('');
  // The fields the DJ wants up top, in order:
  L.push(`BPM:        ${song.bpm ?? '—'}`);
  L.push(`Key:        ${key}  (Camelot ${camelot})`);
  L.push(`Sentiment:  ${sentiment}`);
  L.push(`Album:      ${albumName}`);
  L.push('');
  L.push('-- Setlist position --');
  L.push(`  number:    ${j.pos}`);
  L.push(`  sequence:  ${csv.sequence || '—'}`);
  L.push(`  source:    ${csv.source || '—'}`);
  L.push(`  target BPM:${csv.bpm ? ' ' + csv.bpm : ' —'}`);
  L.push(`  target Key:${csv.key ? ' ' + csv.key : ' —'}`);
  L.push('');
  L.push('-- Segment (carved from raw rip) --');
  L.push(`  source file: ${ptr.filename}`);
  L.push(`  start:       ${msToClock(ptr.startMs)}  (${ptr.startMs} ms)`);
  L.push(`  end:         ${msToClock(ptr.endMs)}  (${ptr.endMs} ms)`);
  L.push(`  duration:    ${msToClock(durMs)}  (${durMs} ms)`);
  L.push(`  output:      ${j.base}.${j.audioExt}`);
  L.push('');
  L.push('-- Song metadata --');
  for (const [k, v] of Object.entries(song)) {
    if (k === 'pointer') continue;
    L.push(`  ${k}: ${Array.isArray(v) ? v.join(', ') : (v == null ? '—' : (typeof v === 'object' ? JSON.stringify(v) : v))}`);
  }
  L.push('');
  L.push('-- Album metadata --');
  if (album) {
    for (const [k, v] of Object.entries(album)) {
      if (k === 'trackList' || k === 'audioTracks') { L.push(`  ${k}: [${(v || []).length} entries]`); continue; }
      L.push(`  ${k}: ${Array.isArray(v) ? v.join(', ') : (v == null ? '—' : (typeof v === 'object' ? JSON.stringify(v) : v))}`);
    }
  } else {
    L.push('  (album not found in index)');
  }
  L.push('');
  L.push('-- Raw JSON --');
  L.push(JSON.stringify({ song, album }, null, 2));
  L.push('');
  return L.join('\n');
}

// ---------- ffmpeg one segment ----------
function burnOne(j) {
  return new Promise((resolve) => {
    const src = path.join(SOURCE, j.ptr.filename);
    const outAudio = path.join(OUT_DIR, `${j.base}.${j.audioExt}`);
    if (!fs.existsSync(src)) { resolve({ j, ok: false, err: `source missing: ${src}` }); return; }
    if (!OVERWRITE && fs.existsSync(outAudio)) { resolve({ j, ok: true, skipped: true, outAudio }); return; }

    const startSec = (j.ptr.startMs / 1000).toFixed(3);
    const durSec = ((j.ptr.endMs - j.ptr.startMs) / 1000).toFixed(3);
    const md = [
      ['title', j.song.name || ''],
      ['artist', j.song.artist || ''],
      ['album', j.album?.name || ''],
      ['track', String(j.pos)],
      ['date', String(j.song.year || j.album?.year || '')],
      ['genre', j.album?.genre || ''],
      ['comment', `BPM ${j.song.bpm ?? '?'} | ${j.song.key || '?'} (${j.song.camelot || '?'}) | ${(j.song.sentimentKeywords || []).join(', ')}`],
    ];
    const a = ['-y', '-hide_banner', '-loglevel', 'error',
      '-ss', startSec, '-t', durSec, '-i', src, '-map', '0:a:0', '-vn'];
    if (COPY) a.push('-c:a', 'copy');
    else {
      if (FORMAT === 'mp3') a.push('-c:a', 'libmp3lame', '-b:a', BITRATE, '-id3v2_version', '3');
      else if (FORMAT === 'm4a') a.push('-c:a', 'aac', '-b:a', BITRATE);
      else if (FORMAT === 'flac') a.push('-c:a', 'flac');
      else if (FORMAT === 'wav') a.push('-c:a', 'pcm_s16le');
      else if (FORMAT === 'aiff') a.push('-c:a', 'pcm_s16be');
      else a.push('-b:a', BITRATE);
    }
    for (const [k, v] of md) if (v) a.push('-metadata', `${k}=${v}`);
    a.push(outAudio);

    const p = spawn('ffmpeg', a);
    let stderr = '';
    p.stderr.on('data', d => { stderr += d; });
    p.on('error', e => resolve({ j, ok: false, err: e.message }));
    p.on('close', code => resolve({ j, ok: code === 0, outAudio, err: code === 0 ? null : (stderr.trim() || `ffmpeg exit ${code}`) }));
  });
}

// ---------- run ----------
async function main() {
  // sidecars + m3u8 always written (even on dry run)
  const m3u = ['#EXTM3U'];
  for (const j of jobsList) {
    fs.writeFileSync(path.join(OUT_DIR, `${j.base}.txt`), buildSidecar(j));
    const dur = Math.round((j.ptr.endMs - j.ptr.startMs) / 1000);
    m3u.push(`#EXTINF:${dur},${j.song.artist} - ${j.song.name}`);
    m3u.push(`${j.base}.${j.audioExt}`);
  }
  fs.writeFileSync(path.join(OUT_DIR, 'setlist.m3u8'), m3u.join('\n') + '\n');

  const results = [];
  if (!DRY) {
    let next = 0, done = 0;
    async function worker() {
      while (next < jobsList.length) {
        const j = jobsList[next++];
        const r = await burnOne(j);
        results.push(r);
        done++;
        const tag = r.skipped ? 'skip' : (r.ok ? 'ok  ' : 'FAIL');
        process.stdout.write(`  [${String(done).padStart(pad)}/${jobsList.length}] ${tag}  ${j.base}.${j.audioExt}${r.ok ? '' : '  — ' + r.err}\n`);
      }
    }
    await Promise.all(Array.from({ length: Math.min(JOBS, jobsList.length) }, worker));
  }

  // manifest
  const manifest = {
    setlist: setName,
    sourceCsv: path.resolve(SETLIST),
    index: path.resolve(INDEX),
    source: SOURCE,
    format: COPY ? 'copy' : FORMAT,
    bitrate: COPY ? null : BITRATE,
    burnedAt: new Date().toISOString(),
    total: dataRows.length,
    burned: jobsList.length,
    skippedSongs: problems,
    tracks: jobsList.map(j => ({
      pos: j.pos, songId: j.song.id, artist: j.song.artist, title: j.song.name,
      audio: `${j.base}.${j.audioExt}`, text: `${j.base}.txt`,
      bpm: j.song.bpm, key: j.song.key, camelot: j.song.camelot,
      album: j.album?.name || null,
      sourceFile: j.ptr.filename, startMs: j.ptr.startMs, endMs: j.ptr.endMs,
    })),
  };
  fs.writeFileSync(path.join(OUT_DIR, 'burn-manifest.json'), JSON.stringify(manifest, null, 2));

  const failed = results.filter(r => !r.ok);
  const burned = results.filter(r => r.ok && !r.skipped).length;
  const skipped = results.filter(r => r.skipped).length;
  console.log(`\n${DRY ? 'Planned' : 'Done'}: ${OUT_DIR}`);
  if (!DRY) console.log(`  audio: ${burned} burned, ${skipped} already present, ${failed.length} failed`);
  console.log(`  sidecars: ${jobsList.length} .txt   playlist: setlist.m3u8   manifest: burn-manifest.json`);
  if (failed.length) { console.log('\n  ✗ failures:'); for (const f of failed) console.log(`     - ${f.j.base}: ${f.err}`); process.exit(1); }
}

main().catch(e => die(e.stack || e.message));
