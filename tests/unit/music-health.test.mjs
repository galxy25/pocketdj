// Unit tests for scripts/lib/music-health.mjs — detecting and repairing a WEDGED Music.app.
//
// These tests replay the 2026-08-12 incident against fakes. The daemon is live and owns
// Music.app + Audio Hijack, so nothing here may touch the real GUI: every effect (osascript,
// sleep, clock, force-kill) is injected.
//
// What each block pins, and why:
//   · parsePlayerProbe — "missing value" must become null, NEVER 0. `parseFloat(x) || 0` on a
//     stopped player yields a perfectly plausible "0 seconds in", which is HOW the wedge stayed
//     invisible for 38 hours. This is the smallest, sharpest fact in the file.
//   · waitUntilPlaying — the accepted-play-that-never-starts signature must be detected
//     EXPLICITLY, and bounded (it runs in front of every capture).
//   · healMusic — graceful quit first, force only on escalation, and "back up" means ANSWERING,
//     not merely running.
//   · captureWithHeal — one heal, one retry, gated. A quit/relaunch loop against a dead Mac
//     would be worse than the outage it fixes.
import { describe, it, expect } from 'vitest';
import {
  parsePlayerProbe, waitUntilPlaying, musicAlive, healMusic, createHealGate, captureWithHeal,
  PROBE_SCRIPT, WEDGED_REASON,
} from '../../scripts/lib/music-health.mjs';

// A clock that only moves when something sleeps — no wall-clock, no flake, no waiting.
function fakeClock(start = 1_700_000_000_000) {
  let t = start;
  return { now: () => t, sleep: async (ms) => { t += ms; }, advance: (ms) => { t += ms; } };
}
// An osascript stand-in driven by a per-script responder.
function fakeOsa(respond) {
  const calls = [];
  const osa = async (script, timeoutMs) => {
    calls.push({ script, timeoutMs });
    const r = respond(script, calls.length);
    return r === undefined ? { ok: true, out: '', err: '' } : r;
  };
  osa.calls = calls;
  return osa;
}
const okOut = (out) => ({ ok: true, out, err: '' });

describe('parsePlayerProbe', () => {
  it('"missing value" position parses to NULL, never 0 — the ambiguity that hid the wedge', () => {
    const p = parsePlayerProbe('stopped|missing value');
    expect(p.state).toBe('stopped');
    expect(p.position).toBeNull();
    // the trap this replaces: the old inline parse turned the same text into a credible 0
    expect(parseFloat('missing value') || 0).toBe(0);
  });

  it('reads a live probe', () => {
    expect(parsePlayerProbe('playing|123.5')).toMatchObject({ ok: true, state: 'playing', position: 123.5 });
    expect(parsePlayerProbe('paused|7')).toMatchObject({ state: 'paused', position: 7 });
  });

  it('an unscriptable / empty / errored Music is ok:false, not a fake position', () => {
    expect(parsePlayerProbe('')).toMatchObject({ ok: false, state: 'unknown', position: null });
    expect(parsePlayerProbe('error|Music got an error')).toMatchObject({ ok: false, state: 'error', position: null });
  });
});

describe('waitUntilPlaying — the accepted-play-that-never-starts signature', () => {
  it('DETECTS the 2026-08-12 wedge: player pinned at stopped|missing value forever', async () => {
    const clock = fakeClock();
    // the exact transcript from the incident: play was accepted, this never changed
    const osa = fakeOsa(() => okOut('stopped|missing value'));
    const r = await waitUntilPlaying({ osa, sleep: clock.sleep, now: clock.now, timeoutMs: 20_000, pollMs: 500 });
    expect(r.started).toBe(false);          // ← the detection
    expect(r.sawPlaying).toBe(false);
    expect(r.lastState).toBe('stopped');
    expect(r.lastPosition).toBeNull();
    expect(osa.calls[0].script).toBe(PROBE_SCRIPT);
    // BOUNDED: it gives up on schedule instead of hanging in front of every capture
    expect(r.elapsedMs).toBeLessThanOrEqual(20_500);
    expect(r.samples).toBeGreaterThan(1);
    expect(r.samples).toBeLessThanOrEqual(42);
  });

  it('accepts a genuinely playing player as soon as the position ADVANCES', async () => {
    const clock = fakeClock();
    let n = 0;
    const osa = fakeOsa(() => okOut(`playing|${(n++) * 0.5}`));
    const r = await waitUntilPlaying({ osa, sleep: clock.sleep, now: clock.now, timeoutMs: 20_000, pollMs: 500 });
    expect(r.started).toBe(true);
    expect(r.positionAdvanced).toBe(true);
    expect(r.samples).toBe(2); // no reason to keep probing once it is moving
  });

  it('REJECTS "playing" with a frozen position — a player that reports playing but is not', async () => {
    const clock = fakeClock();
    const osa = fakeOsa(() => okOut('playing|12.0')); // same position forever
    const r = await waitUntilPlaying({ osa, sleep: clock.sleep, now: clock.now, timeoutMs: 5_000, pollMs: 500 });
    expect(r.started).toBe(false);
    expect(r.sawPlaying).toBe(true);       // it claimed to be playing…
    expect(r.positionAdvanced).toBe(false); // …but never moved
  });

  it('accepts two consecutive `playing` samples when no position is reported at all', async () => {
    const clock = fakeClock();
    const osa = fakeOsa(() => okOut('playing|missing value'));
    const r = await waitUntilPlaying({ osa, sleep: clock.sleep, now: clock.now, timeoutMs: 5_000, pollMs: 500 });
    expect(r.started).toBe(true);
    expect(r.samples).toBe(2);
  });

  it('a lapse back to stopped restarts the evidence (no credit for a stale playing sample)', async () => {
    const clock = fakeClock();
    const seq = ['playing|1', 'stopped|missing value', 'playing|5', 'playing|5'];
    let i = 0;
    const osa = fakeOsa(() => okOut(seq[Math.min(i++, seq.length - 1)]));
    const r = await waitUntilPlaying({ osa, sleep: clock.sleep, now: clock.now, timeoutMs: 3_000, pollMs: 500 });
    expect(r.started).toBe(false); // 'playing|5' twice never advances, and the first sample was voided
  });
});

describe('musicAlive', () => {
  it('true only when a LIBRARY query actually answers', async () => {
    expect(await musicAlive({ osa: fakeOsa(() => okOut('Library')) })).toBe(true);
    expect(await musicAlive({ osa: fakeOsa(() => ({ ok: false, out: '', err: 'not running' })) })).toBe(false);
    expect(await musicAlive({ osa: fakeOsa(() => okOut('   ')) })).toBe(false); // empty answer is not alive
  });
});

describe('healMusic — quit, relaunch, and prove it answers', () => {
  // Scripted Music.app: running until quit lands, then answers the library query again.
  function scriptedMusic({ quitsAfter = 1, aliveAfter = 1, forceOnly = false } = {}) {
    const state = { running: true, quitCalls: 0, launchCalls: 0, aliveCalls: 0, forced: 0 };
    const osa = fakeOsa((script) => {
      if (script.includes('to quit')) {
        state.quitCalls += 1;
        if (!forceOnly && state.quitCalls >= quitsAfter) state.running = false;
        return okOut('');
      }
      if (script.includes('is running')) return okOut(state.running ? 'yes' : 'no');
      if (script.includes('to launch')) { state.launchCalls += 1; state.relaunchedAt = state.aliveCalls; return okOut(''); }
      if (script.includes('library playlist 1')) {
        state.aliveCalls += 1;
        return state.launchCalls && state.aliveCalls >= aliveAfter ? okOut('Library') : { ok: false, out: '', err: 'no' };
      }
      return okOut('');
    });
    return { state, osa, forceKill: async () => { state.forced += 1; state.running = false; } };
  }

  it('graceful quit + relaunch, and does NOT force-kill when quit lands', async () => {
    const clock = fakeClock();
    const m = scriptedMusic({ quitsAfter: 1, aliveAfter: 1 });
    const logs = [];
    const r = await healMusic({ osa: m.osa, sleep: clock.sleep, now: clock.now, log: (x) => logs.push(x), forceKill: m.forceKill });
    expect(r.healed).toBe(true);
    expect(r.escalated).toBe(false);
    expect(m.state.forced).toBe(0);           // ← a media app is never force-killed if it will quit
    expect(m.state.quitCalls).toBe(1);
    expect(m.state.launchCalls).toBe(1);
    expect(logs.join('\n')).toMatch(/HEAL-OK/);
  });

  it('escalates to a force kill only after the graceful quit misses its deadline', async () => {
    const clock = fakeClock();
    const m = scriptedMusic({ forceOnly: true, aliveAfter: 1 }); // ignores `quit`
    const r = await healMusic({ osa: m.osa, sleep: clock.sleep, now: clock.now, forceKill: m.forceKill, quitTimeoutMs: 5_000, pollMs: 1_000 });
    expect(r.escalated).toBe(true);
    expect(m.state.forced).toBe(1);
    expect(r.healed).toBe(true);
  });

  it('healed=false when Music never ANSWERS again (a process that exists but cannot be scripted)', async () => {
    const clock = fakeClock();
    const osa = fakeOsa((script) => (script.includes('is running') ? okOut('no') : { ok: false, out: '', err: 'unresponsive' }));
    const logs = [];
    const r = await healMusic({
      osa, sleep: clock.sleep, now: clock.now, log: (x) => logs.push(x),
      forceKill: async () => {}, relaunchTimeoutMs: 5_000, pollMs: 1_000,
    });
    expect(r.healed).toBe(false);
    expect(logs.join('\n')).toMatch(/HEAL-FAILED/);
  });
});

describe('createHealGate — the bound that keeps a dead Mac from becoming a quit/relaunch loop', () => {
  it('cooldown blocks a second heal, and releases exactly when it expires', () => {
    const clock = fakeClock();
    const gate = createHealGate({ now: clock.now, cooldownMs: 20 * 60_000, maxPerHour: 3 });
    expect(gate.allow().ok).toBe(true);
    gate.record();
    expect(gate.allow()).toMatchObject({ ok: false, reason: 'cooldown' });
    clock.advance(19 * 60_000);
    expect(gate.allow().ok).toBe(false);
    clock.advance(1 * 60_000 + 1);
    expect(gate.allow().ok).toBe(true);
  });

  it('per-hour ceiling holds even when every cooldown has expired', () => {
    const clock = fakeClock();
    const gate = createHealGate({ now: clock.now, cooldownMs: 10 * 60_000, maxPerHour: 3 });
    for (let i = 0; i < 3; i++) { expect(gate.allow().ok).toBe(true); gate.record(); clock.advance(15 * 60_000); }
    expect(gate.allow()).toMatchObject({ ok: false, reason: 'rate-limit' });
    clock.advance(60 * 60_000); // the rolling hour empties
    expect(gate.allow().ok).toBe(true);
  });
});

describe('captureWithHeal — exactly one heal and one retry per capture', () => {
  const wedged = { phase: 'error', reason: WEDGED_REASON, error: 'play accepted but never started' };
  const uploaded = { phase: 'uploaded', key: 'rips/sng_x.mp3' };
  const noMatch = { phase: 'error', reason: 'no-match', error: 'no audio captured' };
  const gateOf = (clock, over = {}) => createHealGate({ now: clock.now, cooldownMs: 20 * 60_000, maxPerHour: 3, ...over });

  it('(b) a wedged capture triggers EXACTLY one heal and EXACTLY one retry', async () => {
    const clock = fakeClock();
    const attempts = [];
    let heals = 0;
    const r = await captureWithHeal({
      runCapture: async (n) => { attempts.push(n); return n === 1 ? wedged : uploaded; },
      heal: async () => { heals += 1; return { healed: true }; },
      gate: gateOf(clock), songId: 'sng_x',
    });
    expect(heals).toBe(1);
    expect(attempts).toEqual([1, 2]);   // one retry, not a loop
    expect(r.healed).toBe(true);
    expect(r.attempts).toBe(2);
    expect(r.st).toBe(uploaded);        // the post-heal verdict is what the caller sees
  });

  it('logs a distinct HEAL token an external monitor can grep', async () => {
    const clock = fakeClock();
    const logs = [];
    await captureWithHeal({
      runCapture: async (n) => (n === 1 ? wedged : uploaded),
      heal: async () => ({ healed: true }), gate: gateOf(clock), songId: 'sng_x', log: (m) => logs.push(m),
    });
    expect(logs.filter((l) => l.startsWith('HEAL')).length).toBeGreaterThan(0);
    expect(logs.join('\n')).toContain('sng_x');
  });

  it('(c) the cooldown bounds it: five consecutive wedged captures heal ONCE, never loop', async () => {
    const clock = fakeClock();
    const gate = gateOf(clock);
    let heals = 0, captures = 0;
    const logs = [];
    for (let i = 0; i < 5; i++) {
      await captureWithHeal({
        runCapture: async () => { captures += 1; return wedged; },   // the Mac stays broken
        heal: async () => { heals += 1; return { healed: true }; },
        gate, songId: `sng_${i}`, log: (m) => logs.push(m),
      });
    }
    expect(heals).toBe(1);            // ← bounded across captures, not just within one
    expect(captures).toBe(6);         // 2 for the healed capture + 1 each for the other four
    expect(logs.join('\n')).toMatch(/HEAL-SKIPPED/);
    clock.advance(21 * 60_000);       // cooldown expires → it may try again
    await captureWithHeal({
      runCapture: async () => { captures += 1; return wedged; },
      heal: async () => { heals += 1; return { healed: true }; }, gate, songId: 'sng_later',
    });
    expect(heals).toBe(2);
  });

  it('(d) a capture that SUCCEEDS never heals — Music is not restarted under a working rig', async () => {
    const clock = fakeClock();
    let heals = 0, captures = 0;
    const r = await captureWithHeal({
      runCapture: async () => { captures += 1; return uploaded; },
      heal: async () => { heals += 1; return { healed: true }; },
      gate: gateOf(clock), songId: 'sng_ok',
    });
    expect(heals).toBe(0);
    expect(captures).toBe(1);
    expect(r.healed).toBe(false);
  });

  it('a NON-wedge failure never heals — restarting Music cannot fix a track that is not in the library', async () => {
    const clock = fakeClock();
    let heals = 0;
    const r = await captureWithHeal({
      runCapture: async () => noMatch,
      heal: async () => { heals += 1; return { healed: true }; },
      gate: gateOf(clock), songId: 'sng_missing',
    });
    expect(heals).toBe(0);
    expect(r.healSkipped).toBe('not-wedged');
    expect(r.st).toBe(noMatch); // and the original reason survives for the existing retry ladder
  });

  it('a CANCELED job never heals', async () => {
    const clock = fakeClock();
    let heals = 0;
    const r = await captureWithHeal({
      runCapture: async () => wedged, heal: async () => { heals += 1; return { healed: true }; },
      gate: gateOf(clock), canceled: () => true, songId: 'sng_cancel',
    });
    expect(heals).toBe(0);
    expect(r.healSkipped).toBe('canceled');
  });

  it('a heal that FAILS does not get a retry — the caller falls back to its normal ladder', async () => {
    const clock = fakeClock();
    const attempts = [];
    const r = await captureWithHeal({
      runCapture: async (n) => { attempts.push(n); return wedged; },
      heal: async () => ({ healed: false }), gate: gateOf(clock), songId: 'sng_dead',
    });
    expect(attempts).toEqual([1]);
    expect(r.healed).toBe(false);
    expect(r.healSkipped).toBe('heal-failed');
  });

  it('needsHeal:false (the RIP_MUSIC_HEAL=0 kill switch) disables healing entirely', async () => {
    const clock = fakeClock();
    let heals = 0;
    await captureWithHeal({
      runCapture: async () => wedged, heal: async () => { heals += 1; return { healed: true }; },
      gate: gateOf(clock), needsHeal: () => false, songId: 'sng_off',
    });
    expect(heals).toBe(0);
  });
});
