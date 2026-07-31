#!/usr/bin/env node
// backfill-streaming-links — SUPERVISOR for the F3 Sharing browser backfill. It drives
// resolve-streaming-links.mjs over the full catalog with TIGHT, ADAPTIVE rate-limiting and a
// monitorable status file, so a multi-day ~94k-song run stays polite and self-corrects.
//
// Why a supervisor (not just the resolver): the resolver runs at a FIXED --delay-ms and treats a
// bot-wall (blocked → empty results) the same as a legitimate low-confidence miss. This wrapper
// runs the resolver in bounded CHUNKS and, after each chunk, reads its hit/miss tally to decide:
//   • BACK OFF when the chunk miss-rate spikes past --miss-backoff (a rate-limit / bot-wall signal):
//     slow the per-song delay (×1.5, capped at --max-delay-ms) AND sleep a --cooldown-ms cool-down.
//   • EASE the delay back toward --floor-delay-ms when a chunk comes back healthy.
//   • ABORT after --max-stalls consecutive stalled cool-downs (a hard block a human must look at,
//     rather than hammering a wall for hours).
// It processes each --index in turn and stops when the resolver reports every song cached.
//
// MONITOR: it writes a live status JSON (--status) and appends a human log (--log). Watch with:
//   watch -n5 'cat ~/.pocketdj/streaming-links/status.json'      # or: tail -f <log>
// Resumable + safe to kill: the resolver's ndjson cache is the source of truth; re-run to continue.
//
// Usage:
//   node scripts/backfill-streaming-links.mjs --index apple-music --index current --index digital
//     [--cache ~/.pocketdj/streaming-links/links-cache.ndjson]
//     [--chunk 120] [--floor-delay-ms 2200] [--max-delay-ms 9000] [--start-delay-ms 2600]
//     [--miss-backoff 0.6] [--cooldown-ms 300000] [--max-stalls 6]
//     [--services spotify,youtube] [--min-score 60]
//     [--status ~/.pocketdj/streaming-links/status.json] [--log ~/.pocketdj/streaming-links/backfill.log]
//     [--nav-timeout-ms 30000] [--retry-misses]
//
// --retry-misses re-attempts songs the first crawl cached as null (a miss). Without it the
// resolver skips anything already cached, hit OR miss, so a second supervised pass would
// find nothing to do. Point it at a fresh --status/--log so the completed run stays intact.

import { spawn } from 'node:child_process';
import { mkdirSync, appendFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const expand = (p) => (p && p.startsWith('~') ? p.replace(/^~/, homedir()) : p);

function parseArgs(argv) {
  const a = {
    indexes: [],
    cache: '~/.pocketdj/streaming-links/links-cache.ndjson',
    chunk: 120,
    floorDelayMs: 2200,
    maxDelayMs: 9000,
    startDelayMs: 2600,
    missBackoff: 0.6,
    cooldownMs: 5 * 60 * 1000,
    maxStalls: 6,
    services: 'spotify,youtube',
    minScore: 60,
    navTimeoutMs: 30000,
    retryMisses: false,
    status: '~/.pocketdj/streaming-links/status.json',
    log: '~/.pocketdj/streaming-links/backfill.log',
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i]; const next = () => argv[++i];
    if (k === '--index') a.indexes.push(next());
    else if (k === '--cache') a.cache = next();
    else if (k === '--chunk') a.chunk = parseInt(next(), 10);
    else if (k === '--floor-delay-ms') a.floorDelayMs = parseInt(next(), 10);
    else if (k === '--max-delay-ms') a.maxDelayMs = parseInt(next(), 10);
    else if (k === '--start-delay-ms') a.startDelayMs = parseInt(next(), 10);
    else if (k === '--miss-backoff') a.missBackoff = parseFloat(next());
    else if (k === '--cooldown-ms') a.cooldownMs = parseInt(next(), 10);
    else if (k === '--max-stalls') a.maxStalls = parseInt(next(), 10);
    else if (k === '--services') a.services = next();
    else if (k === '--min-score') a.minScore = parseInt(next(), 10);
    else if (k === '--nav-timeout-ms') a.navTimeoutMs = parseInt(next(), 10);
    else if (k === '--retry-misses') a.retryMisses = true;
    else if (k === '--status') a.status = next();
    else if (k === '--log') a.log = next();
  }
  if (!a.indexes.length) a.indexes = ['apple-music'];
  return a;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const iso = () => new Date().toISOString();

// Run ONE resolver chunk; capture its stderr and parse the tally it prints.
// Returns { done, hits, miss, ratePerMin, raw }.
function runChunk(args, delayMs, index) {
  return new Promise((res, rej) => {
    const cliArgs = [
      join(REPO, 'scripts', 'resolve-streaming-links.mjs'),
      '--index', index,
      '--cache', expand(args.cache),
      '--limit', String(args.chunk),
      '--delay-ms', String(delayMs),
      '--min-score', String(args.minScore),
      '--services', args.services,
      '--nav-timeout-ms', String(args.navTimeoutMs),
    ];
    if (args.retryMisses) cliArgs.push('--retry-misses');
    const child = spawn(process.execPath, cliArgs, { cwd: REPO });
    let err = '';
    child.stderr.on('data', (d) => { err += d.toString(); });
    child.stdout.on('data', () => {});
    child.on('error', rej);
    child.on('close', () => {
      // `✓ resolved N songs @ ~R/min`  and per-service `  spotify: hits=H miss=M`
      const doneM = err.match(/resolved\s+(\d+)\s+songs\s+@\s+~?(\d+)\/min/);
      const done = doneM ? parseInt(doneM[1], 10) : 0;
      const ratePerMin = doneM ? parseInt(doneM[2], 10) : 0;
      let hits = 0, miss = 0;
      for (const m of err.matchAll(/hits=(\d+)\s+miss=(\d+)/g)) { hits += +m[1]; miss += +m[2]; }
      const nothing = /nothing to do/.test(err);
      res({ done, hits, miss, ratePerMin, nothing, raw: err });
    });
  });
}

async function main() {
  const args = parseArgs(process.argv);
  const statusPath = expand(args.status);
  const logPath = expand(args.log);
  mkdirSync(dirname(statusPath), { recursive: true });
  mkdirSync(dirname(logPath), { recursive: true });

  const state = {
    startedAt: iso(), updatedAt: iso(), phase: 'running',
    indexes: args.indexes, currentIndex: null,
    delayMs: args.startDelayMs, cumulativeDone: 0, cumulativeHits: 0, cumulativeMiss: 0,
    lastChunkMissRate: null, lastRatePerMin: null, backoffs: 0, stalls: 0, chunks: 0,
    config: {
      chunk: args.chunk, floorDelayMs: args.floorDelayMs, maxDelayMs: args.maxDelayMs,
      missBackoff: args.missBackoff, cooldownMs: args.cooldownMs, maxStalls: args.maxStalls,
      services: args.services, cache: expand(args.cache),
    },
  };
  const flush = () => { state.updatedAt = iso(); writeFileSync(statusPath, JSON.stringify(state, null, 2)); };
  const log = (line) => { const s = `[${iso()}] ${line}`; appendFileSync(logPath, s + '\n'); process.stdout.write(s + '\n'); };

  log(`SUPERVISOR start · indexes=${args.indexes.join(',')} · chunk=${args.chunk} · ` +
      `delay ${args.floorDelayMs}-${args.maxDelayMs}ms (start ${args.startDelayMs}) · ` +
      `miss-backoff ${args.missBackoff} · cooldown ${Math.round(args.cooldownMs / 1000)}s · cache ${expand(args.cache)}`);
  flush();

  let delay = args.startDelayMs;
  for (const index of args.indexes) {
    state.currentIndex = index; state.stalls = 0; flush();
    log(`── index ${index} ──`);
    for (;;) {
      const c = await runChunk(args, delay, index);
      state.chunks++;
      if (c.nothing || c.done === 0) { log(`  ${index}: complete (all cached)`); break; }
      const total = c.hits + c.miss;
      const missRate = total ? c.miss / total : 0;
      state.cumulativeDone += c.done; state.cumulativeHits += c.hits; state.cumulativeMiss += c.miss;
      state.lastChunkMissRate = +missRate.toFixed(3); state.lastRatePerMin = c.ratePerMin; state.delayMs = delay;
      log(`  chunk#${state.chunks} ${index}: done=${c.done} hits=${c.hits} miss=${c.miss} ` +
          `missRate=${(missRate * 100).toFixed(0)}% rate=${c.ratePerMin}/min delay=${delay}ms ` +
          `(cum done=${state.cumulativeDone} hits=${state.cumulativeHits})`);

      if (missRate >= args.missBackoff && total >= Math.min(20, args.chunk / 2)) {
        // Bot-wall / rate-limit signal → back off HARD and cool down.
        state.backoffs++; state.stalls++;
        delay = Math.min(args.maxDelayMs, Math.round(delay * 1.5));
        log(`  ⚠️  HIGH MISS RATE (${(missRate * 100).toFixed(0)}%) — likely rate-limited. ` +
            `Backing off: delay→${delay}ms, cooling down ${Math.round(args.cooldownMs / 1000)}s ` +
            `(stall ${state.stalls}/${args.maxStalls})`);
        state.phase = 'cooling-down'; flush();
        if (state.stalls >= args.maxStalls) {
          state.phase = 'aborted-stalled';
          log(`  ⛔ ${args.maxStalls} consecutive stalls at max back-off — ABORTING. A human should ` +
              `check for a hard block (captcha/IP ban) and adjust the rate before resuming.`);
          flush();
          process.exit(2);
        }
        await sleep(args.cooldownMs);
        state.phase = 'running'; flush();
      } else {
        // Healthy → ease the delay back toward the floor and reset the stall counter.
        state.stalls = 0;
        delay = Math.max(args.floorDelayMs, Math.round(delay * 0.9));
        flush();
      }
    }
  }
  state.phase = 'done'; state.currentIndex = null; flush();
  log(`✓ SUPERVISOR done · resolved ${state.cumulativeDone} songs · hits ${state.cumulativeHits} · ` +
      `miss ${state.cumulativeMiss} · back-offs ${state.backoffs}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
