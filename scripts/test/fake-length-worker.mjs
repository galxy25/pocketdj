#!/usr/bin/env node
// Test fixture: a stand-in for rip-one.mjs that reports a capture OUTCOME for the length-guard
// e2e (tests/unit/rip-length-guard-e2e.test.mjs) without Music.app, Audio Hijack, ffmpeg or S3.
// Selected via RIP_WORKER=scripts/test/fake-length-worker.mjs.
//
//   FAKE_LENGTH_PLAN = {"<songId>": {"outcome": "short"|"long"|"ok", "measuredMs": N, "holdMs": N}}
//   FAKE_LENGTH_ARGS_DIR = dir — the worker's argv is written to <dir>/<songId>.json (last run)
//
// "short"/"long" mirror what the real worker does when its length guard rejects a capture:
// status phase 'error' with reason short-capture / long-capture, and NOTHING uploaded.
// "ok" reports an uploaded capture with its measured length (the real worker's status contract).
import { writeFileSync, existsSync, readFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const a = {};
for (let i = 2; i < process.argv.length; i++) { const k = process.argv[i]; if (k.startsWith('--')) a[k.slice(2)] = process.argv[++i]; }
const SONG = a['song-id'];
const STATUS = a.status;
const plan = (() => { try { return JSON.parse(process.env.FAKE_LENGTH_PLAN || '{}')[SONG] || {}; } catch { return {}; } })();
if (process.env.FAKE_LENGTH_ARGS_DIR) {
  mkdirSync(process.env.FAKE_LENGTH_ARGS_DIR, { recursive: true });
  writeFileSync(join(process.env.FAKE_LENGTH_ARGS_DIR, `${SONG}.json`), JSON.stringify(a));
}
function status(phase, extra = {}) {
  if (!STATUS) return;
  const prev = existsSync(STATUS) ? JSON.parse(readFileSync(STATUS, 'utf8')) : {};
  writeFileSync(STATUS, JSON.stringify({ ...prev, songId: SONG, phase, ...extra, updatedAt: Date.now() }));
}
const expected = parseInt(a['length-ms'] || '0', 10) || null;
status('ripping', { realtime: true, ripStartedAt: Date.now(), totalMs: expected });
if (plan.holdMs) await new Promise((r) => setTimeout(r, plan.holdMs));
const measuredMs = plan.measuredMs ?? expected;
if (plan.outcome === 'short' || plan.outcome === 'long') {
  const reason = `${plan.outcome}-capture`;
  const error = `${reason}: measured ${measuredMs} ms vs expected ${expected} ms (catalog)`;
  console.error(`LENGTH-GUARD ${SONG} ${reason}: measured ${measuredMs} vs expected ${expected}`);
  status('error', { error, reason });
  console.log('RESULT ' + JSON.stringify({ ok: false, error, reason }));
  process.exit(1);
}
// "refuse": a capture refusal the real worker reports with its own reason (wrong-track /
// play-failed), e.g. {"outcome":"refuse","reason":"wrong-track"}.
if (plan.outcome === 'refuse') {
  const error = `${plan.reason}: refused by the rip skill`;
  status('error', { error, reason: plan.reason });
  console.log('RESULT ' + JSON.stringify({ ok: false, error, reason: plan.reason }));
  process.exit(1);
}
const key = `rips/${SONG}.mp3`;
status('uploaded', { message: 'done', key, bytes: 1234, measuredMs, expectedMs: expected, expectedSource: 'catalog', lengthVerdict: 'ok' });
console.log('RESULT ' + JSON.stringify({ ok: true, key, bytes: 1234, durationMs: measuredMs }));
