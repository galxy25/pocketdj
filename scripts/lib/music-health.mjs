// music-health — detect and repair a WEDGED Music.app playback engine.
//
// ── THE INCIDENT THIS EXISTS FOR (2026-08-12) ───────────────────────────────────────────────────
// The pocket rip backfill made ZERO progress for ~38 hours. Music.app's playback engine had
// wedged after ~25 days of uptime. Everything that gets CHECKED still looked healthy:
//   • the library answered AppleScript fine (95,036 tracks, 136 playlists),
//   • `play <track>` was ACCEPTED WITHOUT ERROR,
//   • `duration of t` returned a real number — but that is LIBRARY METADATA, not playback,
//   • Audio Hijack was innocent: no audio flowed, so it correctly wrote no file.
// The player simply never left state=stopped and `player position` stayed `missing value`,
// forever. Quitting and relaunching Music.app fixed it in seconds.
//
// So the failure signature is: A PLAY COMMAND THAT IS ACCEPTED BUT NEVER STARTS. It must be
// detected EXPLICITLY (poll until the player actually reaches state=playing), never inferred
// from a missing recording — "no file appeared" is also what a broken Audio Hijack, a muted
// output device, and a track absent from the library all look like. Inferring the cause from
// the absence of a file is exactly what cost 38 hours.
//
// ── WHY EVERY EFFECT IS INJECTED ────────────────────────────────────────────────────────────────
// The rip daemon is a live, serial, real-time capture rig: it OWNS Music.app and Audio Hijack.
// Testing this module by driving the real GUI would collide with a running capture. So every
// side effect — osascript, sleeping, the clock, the force-kill — is a parameter, and the unit
// tests replay the incident's exact probe transcript ("stopped|missing value" forever) against
// a fake runner with a fake clock. Production wires `runOsascript` from ./am-music.mjs.
//
// ── THE BOUNDS THAT KEEP A DEAD MAC FROM BECOMING A QUIT/RELAUNCH LOOP ──────────────────────────
// Healing quits the user's music player. That is disruptive and it must never happen on a
// hair trigger, so it is bounded four ways, all structural rather than by convention:
//   1. captureWithHeal has NO LOOP — one heal, one retry, then it returns. Always.
//   2. createHealGate's cooldown sets the RATE (see its header for which bound actually binds).
//   3. createHealGate's CIRCUIT BREAKER sets the END: a machine that healing does not fix stops
//      being restarted. A rate limiter alone never reaches that conclusion.
//   4. The caller supplies `canceled()`, and captureWithHeal evaluates it BOTH before the heal
//      and again after it — a heal takes up to 75 seconds and both asynchronous job terminators
//      (POST /rip-cancel, the per-job watchdog) can land inside that window.

// ---------------- the probe ----------------
// One round trip answers both questions: is the player RUNNING, and is it MOVING. The `try`
// wrapper means a Music.app that is gone/unscriptable reports "error|…" instead of making
// osascript exit non-zero with an opaque message.
export const PROBE_SCRIPT = `tell application "Music"
  try
    return (player state as text) & "|" & (player position as text)
  on error errMsg
    return "error|" & errMsg
  end try
end tell`;

// Library-liveness oracle: the query that KEPT WORKING throughout the incident. It proves the
// app is scriptable again after a relaunch; it proves nothing whatsoever about playback.
export const ALIVE_SCRIPT = 'tell application "Music" to return (name of library playlist 1) as text';
const RUNNING_SCRIPT = 'if application "Music" is running then\n  return "yes"\nelse\n  return "no"\nend if';
const QUIT_SCRIPT = 'tell application "Music" to quit';
const LAUNCH_SCRIPT = 'tell application "Music" to launch';

// Parse "playing|123.4" → { state, position }.
//
// THE LOAD-BEARING DETAIL: a stopped player answers `player position` with the AppleScript
// token "missing value", which is a STRING here. `parseFloat("missing value") || 0` yields 0 —
// a perfectly plausible "we're 0 seconds into the track" — which is precisely how the wedge
// stayed invisible. Absent position must therefore be null, NEVER 0, so that "no position"
// can never be mistaken for "at the beginning".
export function parsePlayerProbe(out) {
  const raw = String(out ?? '').trim();
  if (!raw) return { ok: false, state: 'unknown', position: null, error: 'empty probe' };
  const i = raw.indexOf('|');
  const state = (i < 0 ? raw : raw.slice(0, i)).trim().toLowerCase();
  const posRaw = (i < 0 ? '' : raw.slice(i + 1)).trim();
  if (state === 'error') return { ok: false, state: 'error', position: null, error: posRaw || 'script error' };
  if (!state) return { ok: false, state: 'unknown', position: null, error: 'no state' };
  const n = Number.parseFloat(posRaw);
  const position = posRaw && posRaw !== 'missing value' && Number.isFinite(n) ? n : null;
  return { ok: true, state, position, error: null };
}

// Poll until the player is DEMONSTRABLY playing, or the bounded timeout expires.
//
// "Demonstrably" is stricter than state === 'playing' alone: when a position is available it
// must ADVANCE across two samples, because a player pinned at a fixed position is not playing
// audio no matter what it calls itself. When the position is unavailable (some sources report
// none) two consecutive `playing` samples are accepted instead — the incident's wedge never
// produced even one.
//
// Returns { started, sawPlaying, positionAdvanced, lastState, lastPosition, samples, elapsedMs }.
// `started === false` IS the wedge signature. Every field is reported so the caller can log
// WHY, which is the diagnosis the 38-hour outage never had.
export async function waitUntilPlaying({
  osa, sleep, now = Date.now, timeoutMs = 20_000, pollMs = 500, probeTimeoutMs = 15_000,
} = {}) {
  const t0 = now();
  let samples = 0, sawPlaying = 0, positionAdvanced = false;
  let lastState = 'unknown', lastPosition = null, lastError = null, prevPos = null;
  for (;;) {
    const r = await osa(PROBE_SCRIPT, probeTimeoutMs);
    const p = parsePlayerProbe(r && r.ok ? r.out : (r && r.out) || '');
    samples += 1;
    lastState = p.state; lastPosition = p.position;
    if (!p.ok) lastError = p.error || (r && r.err) || null;
    if (p.state === 'playing') {
      sawPlaying += 1;
      if (p.position == null) {
        // no position available → two consecutive `playing` samples is the best evidence there is
        if (sawPlaying >= 2) return done(true);
      } else {
        if (prevPos != null && p.position > prevPos + 0.01) { positionAdvanced = true; return done(true); }
        prevPos = p.position;
      }
    } else {
      sawPlaying = 0; prevPos = null; // a lapse back to stopped/paused restarts the evidence
    }
    if (now() - t0 >= timeoutMs) return done(false);
    await sleep(pollMs);
    if (now() - t0 >= timeoutMs) return done(false);
  }
  function done(started) {
    return { started, sawPlaying: sawPlaying > 0, positionAdvanced, lastState, lastPosition, lastError, samples, elapsedMs: now() - t0 };
  }
}

// Does Music answer a LIBRARY query? (The oracle for "the app is back up and scriptable".)
export async function musicAlive({ osa, timeoutMs = 20_000 } = {}) {
  try {
    const r = await osa(ALIVE_SCRIPT, timeoutMs);
    return !!(r && r.ok && String(r.out || '').trim());
  } catch { return false; }
}

// Quit Music.app and bring it back. THE ONLY REMEDY THAT WORKED on 2026-08-12.
//
// Graceful first (`quit` — Music flushes its own state), escalating to a force kill ONLY if the
// app is still running after quitTimeoutMs, because force-killing a media app that is merely
// slow to quit risks its library database. After relaunch we do not trust `is running`: we wait
// for the app to actually ANSWER a library query, since a process that exists but cannot be
// scripted is no better than the wedge we started from.
export async function healMusic({
  osa, sleep, now = Date.now, log = () => {}, forceKill = null,
  quitTimeoutMs = 15_000, relaunchTimeoutMs = 60_000, pollMs = 1_000, scriptTimeoutMs = 20_000,
} = {}) {
  const t0 = now();
  const steps = [];
  let escalated = false;
  const isRunning = async () => {
    const r = await osa(RUNNING_SCRIPT, scriptTimeoutMs);
    return !!(r && r.ok && /yes/i.test(String(r.out || '')));
  };

  log('HEAL music.app: issuing graceful quit');
  await osa(QUIT_SCRIPT, scriptTimeoutMs);
  steps.push('quit');

  const qDeadline = t0 + quitTimeoutMs;
  while (await isRunning()) {
    if (now() >= qDeadline) {
      if (!forceKill) { steps.push('still-running-no-force'); break; }
      log('HEAL music.app: graceful quit did not land — escalating to force kill');
      escalated = true; steps.push('force-kill');
      await forceKill();
      await sleep(pollMs);
      break;
    }
    await sleep(pollMs);
  }

  log('HEAL music.app: relaunching');
  await osa(LAUNCH_SCRIPT, scriptTimeoutMs);
  steps.push('launch');
  const rDeadline = now() + relaunchTimeoutMs;
  for (;;) {
    if (await musicAlive({ osa, timeoutMs: scriptTimeoutMs })) {
      const ms = now() - t0;
      log(`HEAL-OK music.app relaunched and answering in ${ms}ms (${steps.join('>')})`);
      return { healed: true, escalated, elapsedMs: ms, steps };
    }
    if (now() >= rDeadline) break;
    await sleep(pollMs);
  }
  const ms = now() - t0;
  log(`HEAL-FAILED music.app did not answer a library query within ${relaunchTimeoutMs}ms (${steps.join('>')})`);
  return { healed: false, escalated, elapsedMs: ms, steps };
}

// Rate limiter + CIRCUIT BREAKER for a DISRUPTIVE remedy — healing quits the user's music
// player, so "how often, and for how long" needs a number rather than a vibe. Three knobs bound
// it and they are NOT equally load-bearing; saying which is which is the point of this comment:
//
//   cooldownMs      THE RATE BOUND. No two heals closer together than this. At the shipped
//                   20 minutes it is the ONLY thing setting the steady-state rate.
//   maxPerHour      A BACKSTOP, not a second rate bound. Spacing heals >= 20 min apart already
//                   means at most 3 land in any rolling hour, so at the shipped defaults this
//                   ceiling changes the refusal MESSAGE and never the rate (a day-long
//                   simulation gives the same heal count for maxPerHour 3 and 1000 — pinned by
//                   a test). It earns its keep only if cooldownMs is ever lowered.
//   maxIneffective  THE TERMINAL BOUND, and the one a rate limiter structurally cannot provide:
//                   it never concludes "healing does not fix THIS machine, stop trying".
//                   Without it, a Music.app sitting on a modal (expired Apple Music sign-in, an
//                   update prompt) — which both refuses to play AND refuses to quit, so it fails
//                   every capture with play-not-started and escalates to `pkill -x Music` — gets
//                   force-quit 72 times a day, forever, discarding whatever the user had open.
//
// The breaker is deliberately PESSIMISTIC: a heal counts against it the moment it is record()ed,
// not when someone gets around to reporting an outcome, so a heal whose result nobody reports
// can never buy another heal. It is cleared by noteCaptureOk() — i.e. by a capture that actually
// worked — so the breaker opens after N useless restarts and RE-ARMS BY ITSELF the moment the
// rig proves it is capturing again. No timer, no manual reset.
//
// allow() is a pure query: the caller must record() when it heals and noteCaptureOk() when a
// capture succeeds. `load`/`save` let a long-lived daemon carry the counters across its OWN
// restarts — launchd KeepAlive would otherwise hand a crash-looping server a fresh cooldown and
// a fresh breaker on every respawn, which is exactly the loop these bounds exist to prevent.
export function createHealGate({
  now = Date.now, cooldownMs = 20 * 60_000, maxPerHour = 3, maxIneffective = 3,
  load = null, save = null,
} = {}) {
  let times = [];
  let ineffective = 0;
  if (load) {
    try {
      const s = load() || {};
      if (Array.isArray(s.times)) times = s.times.filter((x) => Number.isFinite(x));
      if (Number.isFinite(s.ineffective)) ineffective = Math.max(0, s.ineffective);
    } catch { /* absent or unreadable → start clean, never throw into the capture path */ }
  }
  const prune = (t) => { times = times.filter((x) => t - x < 3_600_000); };
  const persist = () => { if (save) { try { save({ times: [...times], ineffective }); } catch { /* best effort */ } } };
  const open = () => maxIneffective > 0 && ineffective >= maxIneffective;
  return {
    allow() {
      const t = now();
      prune(t);
      // TERMINAL bound first: a machine healing does not fix must stop being restarted no
      // matter what the rate limiter would otherwise permit.
      if (open()) return { ok: false, reason: 'circuit-open', ineffective };
      if (times.length >= maxPerHour) return { ok: false, reason: 'rate-limit', healsInLastHour: times.length };
      const last = times[times.length - 1];
      if (last != null && t - last < cooldownMs) return { ok: false, reason: 'cooldown', waitMs: cooldownMs - (t - last) };
      return { ok: true };
    },
    record() { const t = now(); prune(t); times.push(t); ineffective += 1; persist(); },
    /// A capture SUCCEEDED — with or without a heal. The rig demonstrably works, so re-arm.
    noteCaptureOk() { if (ineffective !== 0) { ineffective = 0; persist(); } },
    healsInLastHour() { const t = now(); prune(t); return times.length; },
    ineffectiveHeals() { return ineffective; },
    circuitOpen() { return open(); },
  };
}

// The reason code the capture worker reports when `play` was accepted but the player never
// started. It is the ONLY condition that earns a heal — every other capture failure (track not
// in the library, no route, S3 blip) is left to the server's existing backoff retry ladder.
export const WEDGED_REASON = 'play-not-started';

export const defaultIsOk = (st) => !!(st && st.phase === 'uploaded' && st.key);
export const defaultNeedsHeal = (st) => !!(st && st.reason === WEDGED_REASON);

// Run a capture; if and only if it failed with the wedge signature, heal Music ONCE and retry
// ONCE. There is deliberately NO LOOP here — one heal and one retry per capture is a structural
// property of this function, not a counter someone can get wrong. Everything past the retry is
// the caller's existing backoff ladder, which is the right owner for "still broken".
//
// `canceled()` is evaluated TWICE, and the second read is the one that matters. See the comment
// at the re-check below: the first read happens before a step that takes up to 75 seconds.
export async function captureWithHeal({
  runCapture, heal, gate, log = () => {}, canceled = () => false,
  isOk = defaultIsOk, needsHeal = defaultNeedsHeal, songId = '',
}) {
  const st = await runCapture(1);
  // A capture that works is the ONLY evidence that healing this machine is worth doing, so it
  // re-arms the circuit breaker — including (indeed especially) when no heal was involved.
  if (isOk(st)) { gate.noteCaptureOk?.(); return { st, healed: false, retried: false, attempts: 1, healSkipped: null }; }
  if (canceled()) return { st, healed: false, retried: false, attempts: 1, healSkipped: 'canceled' };
  if (!needsHeal(st)) return { st, healed: false, retried: false, attempts: 1, healSkipped: 'not-wedged' };

  const g = gate.allow();
  if (!g.ok) {
    log(`HEAL-SKIPPED ${songId} Music looks wedged (${WEDGED_REASON}) but heal is gated: ${g.reason}` +
      (g.waitMs ? ` (${Math.round(g.waitMs / 1000)}s left)` : '') +
      (g.healsInLastHour ? ` (${g.healsInLastHour} heals in the last hour)` : '') +
      (g.reason === 'circuit-open'
        ? ` — ${g.ineffective} restarts in a row fixed nothing, so this Mac needs a human;`
          + ' leaving it to the retry ladder until some capture succeeds'
        : ''));
    return { st, healed: false, retried: false, attempts: 1, healSkipped: g.reason };
  }
  gate.record();
  log(`HEAL ${songId} play was accepted but Music never reached state=playing — restarting Music.app`);
  const h = await heal();
  if (!h || !h.healed) return { st, healed: false, retried: false, attempts: 1, healSkipped: 'heal-failed' };

  // ── RE-CHECK CANCELLATION. The load-bearing second read. ──────────────────────────────────────
  // canceled() was false BEFORE the heal, and a heal is SLOW: quitTimeoutMs (15s) plus
  // relaunchTimeoutMs (60s) in production. Both of the things that terminate a job
  // asynchronously can land inside that window — POST /rip-cancel, and the per-job watchdog.
  // The watchdog case is the damaging one: it already rejected the job, the pump released the
  // worker and started the NEXT song, and the retry the ladder scheduled is pending. Running
  // runCapture(2) here would put a SECOND real-time capture on top of a running one — two
  // captures sharing one Music.app and one Audio Hijack make two garbage recordings, and the
  // second child overwrites the single activeChild slot so the first becomes unkillable by both
  // the watchdog and Stop. Reading canceled() once is what allowed that; reading it again is the
  // whole fix.
  if (canceled()) {
    log(`HEAL-ABANDONED ${songId} the job was canceled or timed out while Music.app was restarting — not retrying`);
    return { st, healed: true, retried: false, attempts: 1, healSkipped: 'canceled-during-heal' };
  }

  log(`HEAL retrying capture of ${songId} once after restarting Music.app`);
  const st2 = await runCapture(2);
  if (isOk(st2)) gate.noteCaptureOk?.();
  return { st: st2, healed: true, retried: true, attempts: 2, healSkipped: null };
}
