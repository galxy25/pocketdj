#!/usr/bin/env node
// PocketDJ OpenSearch A/B comparison harness.
//
// Runs the SAME set of representative music queries against TWO aoss collections
// (A = current pocketdj-search, B = a parallel scale-to-zero test collection) and
// reports, per query and in aggregate:
//   • latency p50/p95 (warm) + a separate cold-start probe (first hit after idle)
//   • result-set agreement: Jaccard overlap of top-K ids + Spearman rank correlation
//   • hit counts (are both returning the same corpus?)
//
// Read-only: issues _search + _count GETs only. Never writes/deletes. Safe to run
// against production A while B warms up. Mirrors the app's real query DSL
// (src/search/esClient.ts): multi_match title^3/artist^2/album^1.5/lyrics/sentiment^2,
// best_fields, fuzziness AUTO, operator and.
//
// Auth: SigV4 service "aoss", creds from an AWS profile (default levi → Developer,
// which the data-access policy grants read on both collections).
//
// Usage:
//   node scripts/es-ab-compare.mjs \
//     --a https://<currentId>.us-west-2.aoss.amazonaws.com \
//     --b https://<newId>.us-west-2.aoss.amazonaws.com \
//     [--index pocketdj] [--reps 7] [--k 20] [--profile levi] [--region us-west-2] \
//     [--queries path/to/queries.json]   # optional; else a built-in music query set
//
// Env fallbacks: ES_A, ES_B, ES_INDEX, AWS_PROFILE, AWS_REGION.

import { createHash, createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

function parseArgs(argv) {
  const a = {
    a: process.env.ES_A, b: process.env.ES_B,
    index: process.env.ES_INDEX || 'pocketdj',
    profile: process.env.AWS_PROFILE || 'levi',
    region: process.env.AWS_REGION || 'us-west-2',
    service: 'aoss', reps: 7, k: 20, queries: null,
  };
  for (let i = 2; i < argv.length; i++) {
    const key = argv[i], next = () => argv[++i];
    if (key === '--a') a.a = next();
    else if (key === '--b') a.b = next();
    else if (key === '--index') a.index = next();
    else if (key === '--reps') a.reps = parseInt(next(), 10);
    else if (key === '--k') a.k = parseInt(next(), 10);
    else if (key === '--profile') a.profile = next();
    else if (key === '--region') a.region = next();
    else if (key === '--queries') a.queries = next();
  }
  return a;
}

// ---------------- SigV4 (service: aoss) — same scheme as scripts/es-index.mjs ----------------
function getCreds(profile) {
  const out = execFileSync('aws', ['configure', 'export-credentials', '--profile', profile, '--format', 'process'], { encoding: 'utf8' });
  const c = JSON.parse(out);
  return { akid: c.AccessKeyId, secret: c.SecretAccessKey, token: c.SessionToken || null };
}
const sha256hex = (s) => createHash('sha256').update(s).digest('hex');
const hmac = (key, s) => createHmac('sha256', key).update(s).digest();

function sign({ method, url, body = '', creds, region, service }) {
  const u = new URL(url);
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = sha256hex(body);
  const canonicalHeaders =
    `host:${u.host}\n` + `x-amz-content-sha256:${payloadHash}\n` + `x-amz-date:${amzDate}\n` +
    (creds.token ? `x-amz-security-token:${creds.token}\n` : '');
  const signedHeaders = 'host;x-amz-content-sha256;x-amz-date' + (creds.token ? ';x-amz-security-token' : '');
  const canonicalUri = u.pathname.split('/').map((s) => encodeURIComponent(s)).join('/') || '/';
  const canonicalQuery = u.search
    ? [...u.searchParams.entries()].sort().map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&') : '';
  const canonicalRequest = [method, canonicalUri, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const scope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256hex(canonicalRequest)].join('\n');
  const kSigning = hmac(hmac(hmac(hmac('AWS4' + creds.secret, dateStamp), region), service), 'aws4_request');
  const signature = createHmac('sha256', kSigning).update(stringToSign).digest('hex');
  const headers = {
    'x-amz-date': amzDate, 'x-amz-content-sha256': payloadHash,
    Authorization: `AWS4-HMAC-SHA256 Credential=${creds.akid}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  };
  if (creds.token) headers['x-amz-security-token'] = creds.token;
  return headers;
}

async function esGet({ endpoint, path, body, creds, region, service }) {
  const url = endpoint.replace(/\/$/, '') + path;
  const payload = body == null ? '' : JSON.stringify(body);
  const headers = sign({ method: 'POST', url, body: payload, creds, region, service });
  if (payload) headers['Content-Type'] = 'application/json';
  const t0 = process.hrtime.bigint();
  const res = await fetch(url, { method: 'POST', headers, body: payload || undefined });
  const text = await res.text();
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  return { status: res.status, ok: res.ok, text, ms };
}

// ---------------- query DSL (mirror of app esClient.buildQuery) ----------------
function buildBody(q, k) {
  return {
    size: k,
    _source: ['id', 'type', 'title', 'artist', 'album'],
    query: {
      bool: {
        must: q.trim() ? [{
          multi_match: {
            query: q, fields: ['title^3', 'artist^2', 'album^1.5', 'lyrics', 'sentiment^2'],
            type: 'best_fields', fuzziness: 'AUTO', operator: 'and',
          },
        }] : [{ match_all: {} }],
      },
    },
  };
}

// Representative music queries: exact titles/artists, genres, sentiment words, a
// misspelling (exercises fuzziness), and multi-word. Tune via --queries.
const DEFAULT_QUERIES = [
  'love', 'summer', 'midnight', 'california', 'blue',
  'stevie wonder', 'purple rain', 'nirvana', 'miles davis',
  'melancholy', 'euphoric', 'chill', 'heartbreak',
  'beethvn', 'freddy mercury', 'homecoming', 'electric', 'rain dance',
];

const pct = (arr, p) => {
  if (!arr.length) return NaN;
  const s = [...arr].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
};
const jaccard = (a, b) => {
  const A = new Set(a), B = new Set(b); if (!A.size && !B.size) return 1;
  let inter = 0; for (const x of A) if (B.has(x)) inter++;
  return inter / (A.size + B.size - inter);
};
// Spearman rank correlation on the common ids' ordering.
function spearman(idsA, idsB) {
  const common = idsA.filter((x) => idsB.includes(x));
  if (common.length < 2) return NaN;
  const rank = (ids) => Object.fromEntries(ids.map((id, i) => [id, i]));
  const ra = rank(idsA), rb = rank(idsB);
  const n = common.length;
  let d2 = 0; for (const id of common) { const d = ra[id] - rb[id]; d2 += d * d; }
  return 1 - (6 * d2) / (n * (n * n - 1));
}

async function ids(ctx, endpoint, q, k) {
  const r = await esGet({ ...ctx, endpoint, path: `/${ctx.index}/_search`, body: buildBody(q, k) });
  let hits = [], total = 0;
  try { const j = JSON.parse(r.text); hits = (j.hits?.hits || []).map((h) => h._id); total = j.hits?.total?.value ?? j.hits?.total ?? 0; }
  catch { /* leave empty */ }
  return { ms: r.ms, ok: r.ok, status: r.status, ids: hits, total };
}

async function main() {
  const a = parseArgs(process.argv);
  if (!a.a || !a.b) { console.error('Need --a and --b endpoints (or ES_A/ES_B).'); process.exit(1); }
  const creds = getCreds(a.profile);
  const ctx = { creds, region: a.region, service: a.service, index: a.index };
  const queries = a.queries ? JSON.parse(readFileSync(a.queries, 'utf8')) : DEFAULT_QUERIES;

  console.error(`A = ${a.a}`);
  console.error(`B = ${a.b}`);
  console.error(`index=${a.index}  reps=${a.reps}  k=${a.k}  queries=${queries.length}\n`);

  // Cold-start probe: the very first hit to each (B may have scaled to zero).
  const coldA = await ids(ctx, a.a, queries[0], a.k);
  const coldB = await ids(ctx, a.b, queries[0], a.k);
  console.error(`COLD-START first query "${queries[0]}":  A ${coldA.ms.toFixed(0)}ms (${coldA.status})   B ${coldB.ms.toFixed(0)}ms (${coldB.status})\n`);

  const latA = [], latB = [], overlaps = [], spears = [];
  const rows = [];
  for (const q of queries) {
    let ra, rb;
    for (let i = 0; i < a.reps; i++) { ra = await ids(ctx, a.a, q, a.k); rb = await ids(ctx, a.b, q, a.k); latA.push(ra.ms); latB.push(rb.ms); }
    const ov = jaccard(ra.ids, rb.ids); const sp = spearman(ra.ids, rb.ids);
    overlaps.push(ov); if (!Number.isNaN(sp)) spears.push(sp);
    rows.push({ q, aMs: ra.ms, bMs: rb.ms, aTot: ra.total, bTot: rb.total, ov, sp, aStatus: ra.status, bStatus: rb.status });
  }

  const f = (n, d = 0) => (Number.isNaN(n) ? ' n/a' : n.toFixed(d));
  console.log('\nquery                aMs   bMs   aHits  bHits  jaccard  spearman');
  console.log('-------------------- ----- ----- ------ ------ -------- --------');
  for (const r of rows) {
    const flag = (r.aStatus === 200 && r.bStatus === 200) ? '' : `  ⚠A:${r.aStatus} B:${r.bStatus}`;
    console.log(`${r.q.slice(0, 20).padEnd(20)} ${f(r.aMs).padStart(5)} ${f(r.bMs).padStart(5)} ${f(r.aTot).padStart(6)} ${f(r.bTot).padStart(6)} ${f(r.ov, 2).padStart(8)} ${f(r.sp, 2).padStart(8)}${flag}`);
  }
  console.log('\n=== AGGREGATE ===');
  console.log(`latency A: p50 ${f(pct(latA, 50))}ms  p95 ${f(pct(latA, 95))}ms   (n=${latA.length})`);
  console.log(`latency B: p50 ${f(pct(latB, 50))}ms  p95 ${f(pct(latB, 95))}ms   (n=${latB.length})`);
  const mean = (x) => x.reduce((s, v) => s + v, 0) / (x.length || 1);
  console.log(`result agreement: mean jaccard ${f(mean(overlaps), 3)}   mean spearman ${f(mean(spears), 3)}`);
  console.log(`(jaccard 1.0 + spearman 1.0 = B is a faithful replica of A)`);
}

main().catch((e) => { console.error(e); process.exit(1); });
