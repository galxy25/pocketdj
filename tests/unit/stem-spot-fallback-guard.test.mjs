// THE FALLBACK STORM — an on-demand fallback with no ceiling, no cooldown, and no alarm.
//
// The autoscaler pays on-demand whenever spot cannot supply the fleet. That is right for a
// five-minute dry spell and wrong for a five-hour one: it is a LaunchAgent firing every 60 s, so a
// multi-hour capacity outage is ~300 consecutive full-price launches, each up to a whole fleet at
// $0.1008/hr against ~$0.0400 — 2.7× — until a human happens to
//
//     grep -c 'on-demand' ~/.pocketdj/stem-autoscaler.log
//
// which nobody does, because nothing pages. A month of that spends back the entire saving this
// change was made to capture, with interest.
//
// TWO BRAKES, because they stop different failures and either alone leaves the other open:
//   COOLDOWN bounds a BURST — ten reconciles inside ten minutes during a brief pool wobble would
//     otherwise each buy a full fleet.
//   WINDOW CEILING bounds a SIEGE — a six-hour regional outage would otherwise pay on every one of
//     360 ticks, and the operator would learn about it from the invoice.
//
// AND THE BRAKE IS ON PRICE, NOT ON WORK. Spot is still attempted every tick while the guard is
// engaged, so a pool that recovers at any minute drains the queue immediately; only the full-price
// substitute is rationed. A guard that stopped launching altogether would convert a cost problem
// into a pipeline outage — a strictly worse trade for a music library.
//
// THE HARD PART IS THAT THERE IS NO PROCESS TO HOLD THE COUNTER. Each reconcile is a fresh `node`
// that exits in about a second, so an in-memory tally resets every tick and would permit an
// unbounded run of "first" fallbacks. `shouldAllowFallback` is therefore pure over a counter the
// caller persists to ~/.pocketdj/stem-autoscaler/<lane>.json — the same idiom as the rest of the
// repo's long-running jobs. That the counter really does survive process exit is proved end-to-end
// in tests/unit/stem-spot-reconcile-wiring.test.mjs; this file pins the decision itself.
import { describe, it, expect } from 'vitest';
import { shouldAllowFallback } from '../../scripts/stem-autoscaler.mjs';

const S = 1000;
const MIN = 60 * S;
const HOUR = 60 * MIN;
// Passed explicitly in every call: a guard whose limits are only ever read from env defaults is a
// guard nobody can reason about from a test.
const CFG = { max: 6, windowMs: HOUR, cooldownMs: 10 * MIN };
const T0 = Date.parse('2026-09-06T12:00:00Z');

// One reconcile's worth of counter, exactly as `state.fallback` holds it.
const meter = (count, windowStartMs = T0, lastAtMs = T0) => ({ windowStartMs, count, lastAtMs });

describe('shouldAllowFallback — the FIRST fallback is always allowed', () => {
  it('permits a fallback from a fresh counter — a dry spell must still drain the queue', () => {
    // The guard is a brake, not a block. Refusing the first one would mean a single unlucky minute
    // of spot scarcity stalls the pipeline, which is worse than the bill it saves.
    const r = shouldAllowFallback({}, T0, CFG);
    expect(r.allow).toBe(true);
    expect(r.reason).toBe('');
  });

  it('permits it from every shape of missing or damaged counter, rather than failing closed', () => {
    // The counter comes off disk. A truncated write, a hand-edit, `{"fallback":null}`, or a shape
    // from an older version is not evidence of a storm — and a THROW here would kill the reconcile
    // before it ever reached the queue, every 60 s, until someone found and deleted the file.
    for (const f of [undefined, null, {}, { count: 0 }, { windowStartMs: 0 }, { count: 'lots' }, 'garbage', 7, []]) {
      expect(() => shouldAllowFallback(f, T0, CFG)).not.toThrow();
      expect(shouldAllowFallback(f, T0, CFG).allow).toBe(true);
    }
  });
});

describe('shouldAllowFallback — the COOLDOWN bounds a burst', () => {
  it('REFUSES a second fallback inside the cooldown — 60 s ticks must not each buy a fleet', () => {
    // This is the storm, in one assertion. Without a cooldown, a capacity outage produces one
    // full-price launch per LaunchAgent tick: 60 per hour, each up to a full fleet.
    const r = shouldAllowFallback(meter(1), T0 + MIN, CFG);
    expect(r.allow).toBe(false);
    expect(r.reason).toMatch(/cooldown/i);
  });

  it('holds the brake for the whole cooldown, then releases it', () => {
    for (const dt of [0, MIN, 5 * MIN, CFG.cooldownMs - S]) {
      expect(shouldAllowFallback(meter(1), T0 + dt, CFG).allow).toBe(false);
    }
    expect(shouldAllowFallback(meter(1), T0 + CFG.cooldownMs, CFG).allow).toBe(true);
  });

  it('measures the cooldown from the LATEST paid launch, not the first', () => {
    const f = meter(2, T0, T0 + 20 * MIN);
    expect(shouldAllowFallback(f, T0 + 25 * MIN, CFG).allow).toBe(false);   // 5 min after the last one
    expect(shouldAllowFallback(f, T0 + 31 * MIN, CFG).allow).toBe(true);
  });

  it('says how long is left, so the log line answers the operator\'s actual question', () => {
    expect(shouldAllowFallback(meter(1), T0 + 2 * MIN, CFG).reason).toMatch(/\d+s.*need \d+s/);
  });

  it('a cooldown of 0 disables only the cooldown, not the ceiling', () => {
    const noCool = { ...CFG, cooldownMs: 0 };
    expect(shouldAllowFallback(meter(1), T0 + S, noCool).allow).toBe(true);
    expect(shouldAllowFallback(meter(CFG.max), T0 + S, noCool).allow).toBe(false);
  });
});

describe('shouldAllowFallback — the CEILING bounds a siege', () => {
  it('REFUSES once max paid launches have happened inside the window', () => {
    // Cooldown alone is not enough: a 10-minute cooldown across a 5-hour outage still buys 30
    // full-price fleets. The ceiling is what makes a long outage cost a bounded amount.
    const r = shouldAllowFallback(meter(CFG.max, T0, T0), T0 + 30 * MIN, CFG);
    expect(r.allow).toBe(false);
    expect(r.reason).toMatch(/ceiling/i);
    expect(r.reason).not.toMatch(/cooldown/i);      // the cooldown lapsed at +10 min; this is the ceiling
  });

  it('the CEILING outranks the cooldown — the more expensive brake is reported first', () => {
    // Both engaged at once: an operator told "cooldown" would wait ten minutes and try again, when
    // the real answer is "you are out of budget for the hour, raise it or fix spot capacity".
    expect(shouldAllowFallback(meter(CFG.max), T0 + S, CFG).reason).toMatch(/ceiling/i);
  });

  it('rolls the window — an outage that ended an hour ago must not still be blocking', () => {
    // A fixed daily budget would leave the fleet on spot-or-nothing long after the pool recovered.
    const spent = meter(CFG.max, T0, T0);
    expect(shouldAllowFallback(spent, T0 + 30 * MIN, CFG).allow).toBe(false);
    expect(shouldAllowFallback(spent, T0 + HOUR, CFG).allow).toBe(true);
    expect(shouldAllowFallback(spent, T0 + 3 * HOUR, CFG).allow).toBe(true);
  });

  it('a rolled window also clears the cooldown — the whole counter is stale, not half of it', () => {
    // The subtle one. If the window rolled but the cooldown were still measured against the old
    // lastAtMs, a lane could be blocked for a further ten minutes at the top of every hour for no
    // reason an operator could see.
    expect(shouldAllowFallback(meter(1, T0, T0 + HOUR - S), T0 + HOUR, CFG).allow).toBe(true);
  });

  it('restarts the count when the window rolls, rather than carrying it forward', () => {
    const next = shouldAllowFallback(meter(CFG.max, T0, T0), T0 + HOUR, CFG).next;
    expect(next.count).toBe(1);
    expect(next.windowStartMs).toBe(T0 + HOUR);
  });

  it('honours the CONFIGURED limits rather than hard-coded ones', () => {
    expect(shouldAllowFallback(meter(3), T0 + HOUR / 2, { max: 3, windowMs: HOUR, cooldownMs: 0 }).allow).toBe(false);
    expect(shouldAllowFallback(meter(3), T0 + HOUR / 2, { max: 9, windowMs: HOUR, cooldownMs: 0 }).allow).toBe(true);
  });

  it('a ceiling of 0 disables the paid fallback entirely — the documented hard brake', () => {
    // POCKETDJ_STEM_FALLBACK_MAX=0 has to mean "never pay full price", not "no limit". Reading 0 as
    // permissive is how a config meant as a brake becomes an accelerator.
    const r = shouldAllowFallback({}, T0, { ...CFG, max: 0 });
    expect(r.allow).toBe(false);
    expect(r.reason).toMatch(/ceiling/i);
  });
});

describe('shouldAllowFallback — the counter it hands back', () => {
  it('returns the NEXT counter to persist, and never mutates the one it was given', () => {
    // The caller writes `next` when it decides to pay, so a refused pass cannot charge a budget it
    // never spent. That only works if this function is pure.
    const f = meter(2);
    const before = JSON.stringify(f);
    const r = shouldAllowFallback(f, T0 + 20 * MIN, CFG);
    expect(JSON.stringify(f)).toBe(before);
    expect(r.next).not.toBe(f);
    expect(r.next.count).toBe(3);
    expect(r.next.lastAtMs).toBe(T0 + 20 * MIN);
  });

  it('accumulates: successive persisted counters walk to the ceiling and stop', () => {
    // The whole guard, exercised as the caller uses it — decide, persist, decide again.
    let f;
    let paid = 0;
    for (let i = 0; i < 40; i += 1) {
      const r = shouldAllowFallback(f, T0 + i * 15 * MIN, { ...CFG, windowMs: 10 * HOUR });
      if (r.allow) { paid += 1; f = r.next; }
    }
    expect(paid).toBe(CFG.max);
  });

  it('is DETERMINISTIC — the same counter and clock decide the same way twice', () => {
    expect(shouldAllowFallback(meter(2), T0 + 30 * MIN, CFG))
      .toEqual(shouldAllowFallback(meter(2), T0 + 30 * MIN, CFG));
  });

  it('always returns a usable next, even when it refuses', () => {
    // An undefined `next` on the refusal path would be a crash waiting for the first blocked tick.
    for (const f of [{}, meter(1), meter(CFG.max), null, undefined, 'junk']) {
      const r = shouldAllowFallback(f, T0 + MIN, CFG);
      expect(typeof r.allow).toBe('boolean');
      expect(r.next).toMatchObject({ count: expect.any(Number), windowStartMs: expect.any(Number) });
    }
  });
});

describe('an outage costs a BOUNDED amount', () => {
  it('SIXTY consecutive one-minute ticks buy at most `max` full-price launches', () => {
    // The storm, simulated the way it actually happens: an hour-long capacity outage against a
    // LaunchAgent that fires every 60 s. Each iteration is exactly what one reconcile does — read
    // the counter, ask, act, write the counter back — and the assertion is the bill.
    let f;
    let paid = 0;
    for (let i = 0; i < 60; i += 1) {
      const r = shouldAllowFallback(f, T0 + i * MIN, CFG);
      if (r.allow) { paid += 1; f = r.next; }
    }
    expect(paid).toBeLessThanOrEqual(CFG.max);
    expect(paid).toBeGreaterThan(0);        // …and it is a brake, not a block
  });

  it('the cooldown alone caps an hour at six even with an unlimited ceiling', () => {
    // Belt and braces, measured: at a 10-minute cooldown, 60 ticks can pay at most 6 times whatever
    // the window ceiling says. The two brakes agree rather than one hiding the other's absence.
    let f;
    let paid = 0;
    for (let i = 0; i < 60; i += 1) {
      const r = shouldAllowFallback(f, T0 + i * MIN, { ...CFG, max: 10_000 });
      if (r.allow) { paid += 1; f = r.next; }
    }
    expect(paid).toBeLessThanOrEqual(6);
  });

  it('the ceiling alone caps an hour even with no cooldown at all', () => {
    let f;
    let paid = 0;
    for (let i = 0; i < 60; i += 1) {
      const r = shouldAllowFallback(f, T0 + i * MIN, { ...CFG, cooldownMs: 0 });
      if (r.allow) { paid += 1; f = r.next; }
    }
    expect(paid).toBe(CFG.max);
  });

  it('a SIX-HOUR outage does not cost six hours of full price', () => {
    // 360 ticks. The window rolls, so the guard is not a permanent block either — it is six paid
    // launches an hour, with an alarm firing hourly throughout.
    let f;
    let paid = 0;
    for (let i = 0; i < 360; i += 1) {
      const r = shouldAllowFallback(f, T0 + i * MIN, CFG);
      if (r.allow) { paid += 1; f = r.next; }
    }
    expect(paid).toBeLessThanOrEqual(6 * CFG.max);
    expect(paid).toBeGreaterThan(CFG.max);
  });
});
