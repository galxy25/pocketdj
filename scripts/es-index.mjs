#!/usr/bin/env node
// PocketDJ → OpenSearch Serverless (NextGen) full-text indexer.
//
// FULL RESET each run (indexing is fast/cheap at this scale): delete the index,
// recreate it with the mapping, bulk-load every album + song from the app's
// index.json files. Searchable across: title (song + album), artist, album,
// lyrics (optional enrichment), sentiment keywords, genre, year, bpm/key, etc.
//
// Auth: SigV4 with service "aoss", credentials from the named AWS profile
// (default: levi → the Developer admin user, which the data access policy grants
// write). The browser app queries the SAME collection read-only via the
// djpocketsearch user — this script is the WRITE path only.
//
// Usage:
//   node scripts/es-index.mjs \
//     --endpoint https://<id>.us-west-2.aoss.amazonaws.com \
//     --index pocketdj \
//     --sources public/current-index.json,public/apple-music-index.json \
//     [--profile levi] [--region us-west-2] \
//     [--lyrics-base https://d2p4cubg6se03u.cloudfront.net]   # fetch /lyrics/<songId>.txt
//
// Env fallbacks: ES_ENDPOINT, ES_INDEX, AWS_PROFILE, AWS_REGION.

import { createHash, createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

// ---------------- args ----------------
function parseArgs(argv) {
  const a = {
    index: process.env.ES_INDEX || 'pocketdj',
    endpoint: process.env.ES_ENDPOINT,
    profile: process.env.AWS_PROFILE || 'levi',
    region: process.env.AWS_REGION || 'us-west-2',
    service: 'aoss',
    sources: 'public/current-index.json,public/apple-music-index.json',
    lyricsBase: null,
    lyricsConc: 24,
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i], next = () => argv[++i];
    if (k === '--endpoint') a.endpoint = next();
    else if (k === '--index') a.index = next();
    else if (k === '--sources') a.sources = next();
    else if (k === '--profile') a.profile = next();
    else if (k === '--region') a.region = next();
    else if (k === '--service') a.service = next();
    else if (k === '--lyrics-base') a.lyricsBase = next();
    else if (k === '--lyrics-conc') a.lyricsConc = parseInt(next(), 10);
  }
  return a;
}

// ---------------- SigV4 (service: aoss) ----------------
function getCreds(profile) {
  const out = execFileSync('aws', ['configure', 'export-credentials', '--profile', profile, '--format', 'process'], {
    encoding: 'utf8',
  });
  const c = JSON.parse(out);
  return { akid: c.AccessKeyId, secret: c.SecretAccessKey, token: c.SessionToken || null };
}
const sha256hex = (s) => createHash('sha256').update(s).digest('hex');
const hmac = (key, s) => createHmac('sha256', key).update(s).digest();

/** Sign one request; returns headers to send. host derived from the URL. */
function sign({ method, url, body = '', creds, region, service }) {
  const u = new URL(url);
  const host = u.host;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, ''); // YYYYMMDDTHHMMSSZ
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = sha256hex(body);

  const canonicalHeaders =
    `host:${host}\n` +
    `x-amz-content-sha256:${payloadHash}\n` +
    `x-amz-date:${amzDate}\n` +
    (creds.token ? `x-amz-security-token:${creds.token}\n` : '');
  const signedHeaders = 'host;x-amz-content-sha256;x-amz-date' + (creds.token ? ';x-amz-security-token' : '');

  // canonical URI: encode each path segment (keep '/'); aoss paths are simple.
  const canonicalUri = u.pathname.split('/').map((seg) => encodeURIComponent(seg)).join('/') || '/';
  const canonicalQuery = u.search
    ? [...u.searchParams.entries()].sort().map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&')
    : '';
  const canonicalRequest = [method, canonicalUri, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].join('\n');

  const scope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256hex(canonicalRequest)].join('\n');
  const kDate = hmac('AWS4' + creds.secret, dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  const kSigning = hmac(kService, 'aws4_request');
  const signature = createHmac('sha256', kSigning).update(stringToSign).digest('hex');

  const headers = {
    'x-amz-date': amzDate,
    'x-amz-content-sha256': payloadHash,
    Authorization: `AWS4-HMAC-SHA256 Credential=${creds.akid}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  };
  if (creds.token) headers['x-amz-security-token'] = creds.token;
  return headers;
}

async function esRequest({ method, endpoint, path, body, creds, region, service, contentType = 'application/json' }) {
  const url = endpoint.replace(/\/$/, '') + path;
  const payload = body == null ? '' : typeof body === 'string' ? body : JSON.stringify(body);
  const headers = sign({ method, url, body: payload, creds, region, service });
  if (payload) headers['Content-Type'] = contentType;
  const res = await fetch(url, { method, headers, body: payload || undefined });
  const text = await res.text();
  return { status: res.status, ok: res.ok, text };
}

// ---------------- mapping ----------------
const MAPPING = {
  settings: { 'index.knn': false },
  mappings: {
    properties: {
      id: { type: 'keyword' },
      type: { type: 'keyword' }, // album | song
      title: { type: 'text', fields: { kw: { type: 'keyword', ignore_above: 256 } } },
      artist: { type: 'text', fields: { kw: { type: 'keyword', ignore_above: 256 } } },
      album: { type: 'text', fields: { kw: { type: 'keyword', ignore_above: 256 } } },
      albumId: { type: 'keyword' },
      lyrics: { type: 'text' },
      sentiment: { type: 'text', fields: { kw: { type: 'keyword' } } },
      genre: { type: 'keyword' },
      year: { type: 'integer' },
      bpm: { type: 'integer' },
      key: { type: 'keyword' },
      camelot: { type: 'keyword' },
      explicit: { type: 'boolean' },
      sourceType: { type: 'keyword' }, // analog | digital
      source: { type: 'keyword' }, // sourceName
      trackNumber: { type: 'integer' },
    },
  },
};

// ---------------- build docs from an index.json ----------------
function* docsFrom(index) {
  const sourceName = index.manifest?.sourceName || index.manifest?.source || 'unknown';
  const sourceType = index.manifest?.sourceType || 'analog';
  const albumName = new Map((index.albums || []).map((a) => [a.id, a.name]));
  for (const a of index.albums || []) {
    yield {
      id: a.id, type: 'album', title: a.name, artist: a.artist, album: a.name, albumId: a.id,
      genre: a.genre, year: a.year, sourceType, source: sourceName,
    };
  }
  for (const s of index.songs || []) {
    yield {
      id: s.id, type: 'song', title: s.name, artist: s.artist,
      album: s.albumId ? albumName.get(s.albumId) : undefined, albumId: s.albumId,
      sentiment: (s.sentimentKeywords || []).join(' ') || undefined,
      genre: s.genre, year: s.year, bpm: s.bpm ?? undefined, key: s.key ?? undefined,
      camelot: s.camelot ?? undefined, explicit: !!s.explicit, trackNumber: s.trackNumber,
      sourceType, source: sourceName,
      _lyricsId: s.lyrics ? null : s.id, // marker for optional CDN lyric fetch
      lyrics: s.lyrics || undefined,
    };
  }
}

// ---------------- bounded-concurrency map (for optional lyric fetch) ----------------
async function pMap(items, fn, conc) {
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(conc, items.length) }, async () => {
    while (i < items.length) { const idx = i++; out[idx] = await fn(items[idx], idx); }
  }));
  return out;
}

async function main() {
  const a = parseArgs(process.argv);
  if (!a.endpoint) { console.error('Missing --endpoint (or ES_ENDPOINT)'); process.exit(1); }
  const creds = getCreds(a.profile);
  const ctx = { endpoint: a.endpoint, creds, region: a.region, service: a.service };
  const base = `/${a.index}`;

  // gather docs
  const files = a.sources.split(',').map((s) => s.trim()).filter(Boolean);
  const docs = [];
  for (const f of files) {
    const idx = JSON.parse(readFileSync(f, 'utf8'));
    for (const d of docsFrom(idx)) docs.push(d);
    console.error(`  loaded ${f}`);
  }
  console.error(`Total docs: ${docs.length}`);

  // optional lyrics enrichment from the CDN (per-song .txt)
  if (a.lyricsBase) {
    const songs = docs.filter((d) => d.type === 'song' && !d.lyrics);
    console.error(`Fetching lyrics for ${songs.length} songs from ${a.lyricsBase}/lyrics/<id>.txt …`);
    let got = 0;
    await pMap(songs, async (d) => {
      try {
        const r = await fetch(`${a.lyricsBase}/lyrics/${d.id}.txt`);
        if (r.ok) { const t = (await r.text()).trim(); if (t && !t.startsWith('<')) { d.lyrics = t; got++; } }
      } catch { /* skip */ }
    }, a.lyricsConc);
    console.error(`  lyrics found: ${got}`);
  }
  for (const d of docs) delete d._lyricsId;

  // FULL RESET: delete + recreate index
  const del = await esRequest({ method: 'DELETE', path: base, ...ctx });
  console.error(`DELETE ${a.index}: ${del.status}${del.status === 404 ? ' (did not exist)' : ''}`);
  const cre = await esRequest({ method: 'PUT', path: base, body: MAPPING, ...ctx });
  if (!cre.ok) { console.error(`CREATE failed (${cre.status}): ${cre.text}`); process.exit(1); }
  console.error(`CREATE ${a.index}: ${cre.status}`);

  // bulk load in batches
  const BATCH = 1500;
  let indexed = 0, errors = 0;
  for (let i = 0; i < docs.length; i += BATCH) {
    const slice = docs.slice(i, i + BATCH);
    let ndjson = '';
    for (const d of slice) {
      // keep `id` IN the source too (it's also the doc _id) so hits carry it.
      ndjson += JSON.stringify({ index: { _index: a.index, _id: d.id } }) + '\n' + JSON.stringify(d) + '\n';
    }
    const r = await esRequest({ method: 'POST', path: `/${a.index}/_bulk`, body: ndjson, contentType: 'application/x-ndjson', ...ctx });
    if (!r.ok) { console.error(`bulk batch ${i} HTTP ${r.status}: ${r.text.slice(0, 300)}`); errors += slice.length; continue; }
    try { const j = JSON.parse(r.text); if (j.errors) { const e = j.items.filter((it) => it.index?.error); errors += e.length; if (e.length) console.error(`  batch ${i}: ${e.length} item errors e.g.`, JSON.stringify(e[0].index.error).slice(0, 200)); } } catch { /* ignore */ }
    indexed += slice.length;
    if (i % (BATCH * 10) === 0) console.error(`  …${indexed}/${docs.length}`);
  }
  console.error(`✓ indexed ${indexed} docs (${errors} errors) into ${a.index}`);
  // refresh so docs are searchable immediately
  await esRequest({ method: 'POST', path: `/${a.index}/_refresh`, ...ctx }).catch(() => {});
  const cnt = await esRequest({ method: 'GET', path: `/${a.index}/_count`, ...ctx });
  console.error(`_count: ${cnt.text}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
