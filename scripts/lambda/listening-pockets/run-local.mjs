#!/usr/bin/env node
// LISTENING POCKETS — LOCAL RUNNER. The cloud job with zero AWS: events in, results.v1 out.
//
//   node scripts/lambda/listening-pockets/run-local.mjs --events <file.json> \
//        [--features public/rec-features.json | --features-url <url>] [--now <ms>] \
//        [--out results.json] [--install <id>]
//
// `--events` accepts three shapes:
//   1. an upload batch (upload.v1: `{ v:1, installId, events:[…], places?, trips? }`)
//   2. a plain array of upload events
//   3. a raw `pocketdj-play-history.json` (the device's PlayHistoryStore document), converted on the
//      fly: playedAt → atMs (minute-floored) + ord, wasSkipped / listenedFraction → outcome,
//      tzOffsetMin (default: THIS machine's offset at that instant), listeningContext → ctx.
//      Shape 3 is how to run the job on a real history without uploading anything:
//        --events ~/Library/Containers/com.levi.pocketdj/Data/Library/Application\ Support/pocketdj-play-history.json
//
// Rows go through the SAME `cleanEvent` + `mergeEvents` as the server, so what is computed here is
// what the Lambda would compute for that upload. Prints a summary; writes the results JSON to
// `--out` (stdout when omitted and not a TTY).

import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { computeResults } from './analyze.mjs';
import { detect } from './detect.mjs';
import { indexFeatures } from './features.mjs';
import { cleanEvent, cleanLabels, mergeEvents, freshEventsDoc } from './store.mjs';
import { AWS_ENV } from '../../lib/aws-env.mjs';

const DEFAULT_FEATURES_URL = `${AWS_ENV.cdn.prod}/rec-features.json`;

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const k = a.slice(2);
    const v = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
    out[k] = v;
  }
  return out;
}

/// Outcome derivation — MIRRORS `PlayHistoryStore.PlayEvent.outcome` on the device.
export function outcomeOf(e) {
  if (e.wasSkipped === true) return 'skipped';
  if (!Number.isFinite(e.listenedFraction)) return 'unknown';
  return e.listenedFraction >= 0.5 ? 'completed' : 'partial';
}

/**
 * A device PlayHistoryStore document → upload events, the way `ListeningPocketsService` builds them:
 * minute-floored `atMs` plus `ord` (order within the stream's minute), the event's own `tzOffsetMin` or the
 * local offset at that instant.
 */
export function historyToUploadEvents(doc, { tzOffsetAt = (ms) => -new Date(ms).getTimezoneOffset() } = {}) {
  const events = (Array.isArray(doc?.events) ? doc.events : [])
    .filter((e) => e && typeof e.id === 'string' && typeof e.songId === 'string' && Number.isFinite(e.playedAt))
    .sort((a, b) => a.playedAt - b.playedAt || (a.id < b.id ? -1 : 1));
  // `ord` per (stream, minute) — the server's stream key, as `ListeningPocketsService.ordinals` does.
  const ordByMinute = new Map();
  return events.map((e) => {
    const atMs = Math.floor(e.playedAt / 60_000) * 60_000;
    const key = `${e.originInstallId ?? doc.installId ?? '-'}|${atMs}`;
    const ord = ordByMinute.get(key) || 0;
    ordByMinute.set(key, ord + 1);
    return {
      id: e.id, songId: e.songId, atMs, ord,
      tzOffsetMin: Number.isInteger(e.tzOffsetMin) ? e.tzOffsetMin : tzOffsetAt(e.playedAt),
      source: e.source ?? null, outcome: outcomeOf(e),
      fraction: Number.isFinite(e.listenedFraction) ? e.listenedFraction : null,
      originInstallId: e.originInstallId ?? null, artist: e.artist ?? null,
      carPlay: typeof e.carPlay === 'boolean' ? e.carPlay : null,
      ctx: e.listeningContext ?? null,
    };
  });
}

/// Any of the three input shapes → `{ installId, events, places, trips, shape }`.
export function toUpload(input, { install } = {}) {
  if (Array.isArray(input)) {
    return { installId: install || 'LOCAL-RUNNER', events: input, places: null, trips: null, shape: 'events' };
  }
  if (input && typeof input === 'object' && Array.isArray(input.events)) {
    if ('schemaVersion' in input || input.events.some((e) => e && 'playedAt' in e)) {
      return { installId: install || input.installId || 'LOCAL-HISTORY', events: historyToUploadEvents(input),
        places: null, trips: null, shape: 'history' };
    }
    return { installId: install || input.installId || 'LOCAL-RUNNER', events: input.events,
      places: input.places ?? null, trips: input.trips ?? null, shape: 'upload' };
  }
  throw new Error('unrecognised --events input: expected an upload batch, an event array, or a play-history document');
}

/// The server's ingest path, in memory: clean every row, merge per id, attach the label snapshot.
export function buildEventsDoc(upload, nowMs) {
  const doc = freshEventsDoc(nowMs);
  const rows = []; let rejected = 0;
  for (const e of upload.events) {
    const r = cleanEvent(e, upload.installId, nowMs);
    if (r) rows.push(r); else rejected += 1;
  }
  const merged = mergeEvents(doc, rows, nowMs);
  if (Array.isArray(upload.places) || Array.isArray(upload.trips)) {
    doc.labels = { ...cleanLabels(upload.places, upload.trips), atMs: nowMs };
  }
  return { doc, rejected, merged };
}

async function loadFeaturesFrom({ file, url }) {
  if (file) return indexFeatures(JSON.parse(readFileSync(resolve(file), 'utf8')));
  const res = await fetch(url, { signal: AbortSignal.timeout(60_000) });
  if (!res.ok) throw new Error(`features fetch failed: HTTP ${res.status}`);
  return indexFeatures(await res.json());
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.events || args.events === true) {
    console.error('usage: run-local.mjs --events <file.json> [--features <file> | --features-url <url>] [--now <ms>] [--out <file>] [--install <id>]');
    process.exit(2);
  }
  const nowMs = args.now && args.now !== true ? Number(args.now) : Date.now();
  if (!Number.isFinite(nowMs)) throw new Error('--now must be epoch ms');
  const upload = toUpload(JSON.parse(readFileSync(resolve(args.events), 'utf8')),
    { install: typeof args.install === 'string' ? args.install : undefined });
  const features = await loadFeaturesFrom({
    file: typeof args.features === 'string' ? args.features : null,
    url: typeof args['features-url'] === 'string' ? args['features-url'] : DEFAULT_FEATURES_URL,
  });
  const { doc, rejected } = buildEventsDoc(upload, nowMs);
  const results = computeResults(doc, features, { nowMs });
  const { sessions } = detect(doc.events);

  const json = `${JSON.stringify(results, null, 2)}\n`;
  if (typeof args.out === 'string') writeFileSync(resolve(args.out), json);
  else if (!process.stdout.isTTY) process.stdout.write(json);

  const log = (s) => console.error(s);
  log(`[run-local] input: ${upload.shape} · ${upload.events.length} events (${rejected} rejected, ${doc.events.length} stored)`);
  log(`[run-local] features: ${features.byId.size} songs · baseline ${results.baseline.plays} plays${results.baseline.thin ? ' (thin)' : ''}`);
  log(`[run-local] sessions: ${sessions.length} · pockets: ${results.pockets.length} · patterns: ${results.patterns.length}`);
  for (const p of results.patterns.slice(0, 10)) log(`  pattern  ${p.id}  ${p.occurrences}× / ${p.distinctDays}d  ${p.title}`);
  for (const p of results.pockets.slice(0, 10)) {
    log(`  pocket   ${p.id}  ${p.localDate} ${String(Math.floor(p.localStartHour)).padStart(2, '0')}h  ${p.memberCount} songs (${p.skippedCount} skipped)  ${p.title}`);
  }
  if (typeof args.out === 'string') log(`[run-local] wrote ${args.out}`);
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('run-local.mjs')) {
  main().catch((e) => { console.error(`[run-local] ${e.message}`); process.exit(1); });
}
