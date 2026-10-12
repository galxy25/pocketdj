// LISTENING POCKETS — DETECTION. Pure functions over STORED event rows (see store.mjs `cleanEvent`
// for the row shape): no I/O, no clock, no randomness — the same rows always give the same pockets.
//
//   normalizeEvents  drop excluded sources, classify play-vs-skip, sort per stream
//   sessionize       split each stream wherever consecutive starts are MORE than 30 min apart
//   detectPockets    the run/skip state machine below, per session
//
// THE RULE (v1, every number in params.mjs):
//   · A pocket OPENS at a run of `minRun` consecutive plays with no skip between them.
//   · It then EXTENDS through the session while the user stays in it. A lone skip does not end it
//     — the skipped song is just not a member — but `endOnConsecutiveSkips` skips in a row (the
//     user hunting for something else) or the end of the session do.
//   · Members are ONLY the plays: a 7-play session with 2 isolated skips is a 5-member pocket.
//
// A "stream" is one install's listening (`installId` on the stored row = the ORIGINATING install,
// falling back to the uploader). Two devices playing at the same time are two people, or one person
// with a speaker in another room — either way not one sequence, so they never interleave.

import { createHash } from 'node:crypto';
import { POCKET_PARAMS } from './params.mjs';

const sha256 = (s) => createHash('sha256').update(s).digest('hex');

/// Is this outcome a PLAY (stays in the groove) or a SKIP (breaks it)? Only `skipped` is a skip by
/// default: `unknown` is a play we never saw the end of (pause → quit, a surface with no position
/// samples) and `partial` is a stop/pause under half without advancing away — neither is the user
/// rejecting the song. The two flags exist so a tuning pass can test the stricter reading.
export function isPlayOutcome(outcome, params = POCKET_PARAMS) {
  if (outcome === 'skipped') return false;
  if (outcome === 'unknown' || outcome == null) return !!params.unknownIsPlay;
  if (outcome === 'partial') return !!params.partialIsPlay;
  return true;
}

/// Total order inside one stream: start minute, then the uploader's within-minute `ord`, then the
/// id — so a re-ordered or re-sent batch can never move a pocket boundary.
export function compareEvents(a, b) {
  if (a.stream !== b.stream) return a.stream < b.stream ? -1 : 1;
  if (a.atMs !== b.atMs) return a.atMs - b.atMs;
  const ao = a.ord ?? 0; const bo = b.ord ?? 0;
  if (ao !== bo) return ao - bo;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/**
 * Stored rows → detection rows: `{ ...row, stream, isPlay }`, excluded sources dropped, sorted by
 * (stream, atMs, ord, id). Never mutates its input. `uploaderInstallId` is the fallback stream for
 * a row that somehow carries no `installId` (the store always stamps one; this is belt and braces
 * for hand-built inputs).
 */
export function normalizeEvents(rows, { params = POCKET_PARAMS, uploaderInstallId = 'unknown' } = {}) {
  const excluded = new Set(params.excludeSources || []);
  const out = [];
  for (const r of Array.isArray(rows) ? rows : []) {
    if (!r || typeof r !== 'object') continue;
    if (typeof r.id !== 'string' || typeof r.songId !== 'string' || !Number.isFinite(r.atMs)) continue;
    if (r.source && excluded.has(r.source)) continue;
    const stream = r.installId || r.originInstallId || uploaderInstallId;
    out.push({ ...r, stream, isPlay: isPlayOutcome(r.outcome, params) });
  }
  out.sort(compareEvents);
  return out;
}

/**
 * Normalized rows → sessions `{ stream, index, events }`. A new session starts whenever the start
 * of a play is MORE than `sessionGapMs` after the start of the previous one in the same stream —
 * exactly 30 minutes apart is still the same session.
 */
export function sessionize(normalized, params = POCKET_PARAMS) {
  const sessions = [];
  let cur = null;
  for (const e of normalized) {
    const prev = cur?.events[cur.events.length - 1];
    if (!cur || cur.stream !== e.stream || e.atMs - prev.atMs > params.sessionGapMs) {
      cur = { stream: e.stream, index: sessions.length, events: [] };
      sessions.push(cur);
    }
    cur.events.push(e);
  }
  return sessions;
}

/// `pk_` + 12 hex of sha256(first member's event id). Stable across recomputes for as long as the
/// pocket's first member is unchanged — appending later plays, or re-sending the batch in a
/// different order, keeps the id the app may already be showing.
export const pocketIdFor = (firstEventId) => `pk_${sha256(String(firstEventId)).slice(0, 12)}`;

/**
 * Sessions → pockets `{ id, stream, members, skipped, skippedCount, sessionPlays, sessionIndex }`.
 *
 * `members` are the plays only. `skipped` are the INTERIOR skips the pocket stepped over (a skip
 * followed, before the end, by another member) — `skippedCount` is their number. Skips trailing a
 * close (the run that ended it, or a session that ended mid-hunt) are not part of the pocket.
 * `sessionPlays` is everything the session held, skips included.
 */
export function detectPockets(sessions, params = POCKET_PARAMS) {
  const pockets = [];
  for (const s of sessions) {
    let run = [];                 // scanning: consecutive plays so far
    let open = null;              // the pocket being extended
    let pending = [];             // skips seen since the last member (interior only once a play follows)
    const close = () => {
      if (open) pockets.push(open);
      open = null; pending = []; run = [];
    };
    for (const e of s.events) {
      if (!open) {
        if (e.isPlay) {
          run.push(e);
          if (run.length >= params.minRun) {
            open = {
              id: pocketIdFor(run[0].id), stream: s.stream, sessionIndex: s.index,
              members: run.slice(), skipped: [], skippedCount: 0, sessionPlays: s.events.length,
            };
            run = []; pending = [];
          }
        } else {
          run = [];
        }
        continue;
      }
      if (e.isPlay) {
        if (pending.length) { open.skipped.push(...pending); open.skippedCount += pending.length; }
        pending = [];
        open.members.push(e);
      } else {
        pending.push(e);
        if (pending.length >= params.endOnConsecutiveSkips) close();
      }
    }
    close();
  }
  return pockets;
}

/// The whole detection pass in one call — what `computeResults` and the local runner use.
export function detect(rows, { params = POCKET_PARAMS, uploaderInstallId } = {}) {
  const normalized = normalizeEvents(rows, { params, uploaderInstallId });
  const sessions = sessionize(normalized, params);
  const pockets = detectPockets(sessions, params);
  return { normalized, sessions, pockets };
}
