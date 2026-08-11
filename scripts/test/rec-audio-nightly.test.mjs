// Unit tests for the two pure decisions inside scripts/rec-audio-nightly.mjs.
//
//   node --test scripts/test/rec-audio-nightly.test.mjs
//
// Both were BUGS in the first cut of this feature, found by running it rather than by reading it,
// which is why they are pinned here rather than trusted:
//   · the deadline, because "stop at 06:00" is the whole contract of a nightly job that shares a
//     Docker daemon with two other nightlies — and a naive HH:MM parse makes a 02:00 job with a
//     06:00 deadline stop instantly when the run is started by hand in the evening;
//   · the source key, because an ANALOG manifest entry carries an ALBUM-level `key` and a per-song
//     `cutKey`, and reading the wrong one analyses the whole side and hands every track on it the
//     SAME vector. Measured, not hypothesised: the first calibration pass did exactly that and two
//     eight-song artist groups came back with a pairwise timbre distance of 0.0000.
import { test } from 'node:test';
import assert from 'node:assert/strict';

const { deadlineMs, sourceKeyFor } = await import('../rec-audio-nightly.mjs');

test('deadline: a time later today is today', () => {
  const now = new Date('2026-08-11T02:00:00');
  const at = deadlineMs('06:00', now);
  assert.equal(new Date(at).getHours(), 6);
  assert.ok(at - now.getTime() === 4 * 60 * 60 * 1000, 'four hours of window at the 02:00 start');
});

test('deadline: a time already past today is TOMORROW, not a zero-length window', () => {
  // The launchd job starts at 02:00, but a human debugging it runs the same command at 23:00.
  // Treating 06:00 as "already gone" would make every manual run a silent no-op.
  const now = new Date('2026-08-10T23:30:00');
  const at = deadlineMs('06:00', now);
  assert.ok(at > now.getTime());
  assert.equal(new Date(at).getDate(), 11);
});

test('deadline: junk is rejected rather than defaulted', () => {
  // A defaulted deadline is the dangerous shape: it would run to some OTHER hour than the one the
  // operator asked for, overlapping the 04:00 and 05:00 nightlies without saying anything.
  for (const bad of ['', 'six', '25:00', '06:70', '0600', null, undefined]) {
    assert.equal(deadlineMs(bad), null, `${JSON.stringify(bad)} must not parse`);
  }
});

test('source key: analog reads the per-song CUT, digital reads its mp3', () => {
  assert.equal(sourceKeyFor({ source: 'digital', key: 'rips/sng_a.mp3' }), 'rips/sng_a.mp3');
  assert.equal(
    sourceKeyFor({ source: 'analog', key: 'rips/alb_x.mp3', cutKey: 'rips/sng_a.cut.mp3' }),
    'rips/sng_a.cut.mp3',
    'an analog song must never be analysed from its ALBUM file');
});

test('source key: no local audio is null, not a guess', () => {
  // Returning the album key as a fallback for a cut-less analog entry would be the same bug in a
  // politer hat — the job must say "no audio" so the song is queued for a rip instead.
  assert.equal(sourceKeyFor({ source: 'analog', key: 'rips/alb_x.mp3' }), null);
  assert.equal(sourceKeyFor({ source: 'digital' }), null);
  assert.equal(sourceKeyFor(null), null);
  assert.equal(sourceKeyFor(undefined), null);
});
