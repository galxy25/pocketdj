// SPOT reclaim, worker side — what happens to the job the worker is HOLDING when EC2 takes the box.
//
// A reclaimed instance gets ~2 minutes' notice. The message it holds is invisible for the rest of
// its 1800 s visibility timeout unless the worker hands it back, so the release path is the whole
// value of the spot switch: without it a reclaim stalls one song for up to half an hour.
//
// The subtle half is the DELIVERY COUNT. The jobs queue dead-letters at maxReceiveCount=3, and the
// receive this worker already spent is unrecoverable — SQS has no "un-receive", no way to decrement
// ApproximateReceiveCount. So a plain ChangeMessageVisibility(0) hands the job back but leaves it
// one reclaim poorer, and a song reclaimed three times would land in the DLQ with nothing wrong
// with it. Re-sending the body as a NEW message is the only reset SQS offers, and these tests pin
// when the worker may reach for it — and when it must not.
import { describe, it, expect } from 'vitest';
import { releasePlan, stemsFromListing, parseSpotInterruption } from '../../scripts/stem-worker.mjs';

const job = (extra = {}) => JSON.stringify({ songId: 'sng_3be2079ad5e3', srcKey: 'rips/sng_3be2079ad5e3.mp3', tasks: ['stems'], ...extra });

describe('releasePlan — hand the job back without burning its last life', () => {
  it('RE-SENDS an interrupted job so it starts over with a full 3 delivery attempts', () => {
    const p = releasePlan({ body: job(), resultPosted: false });
    expect(p.action).toBe('requeue');
    expect(p.requeues).toBe(1);
  });

  it('carries the whole job body across the re-send — a dropped srcKey would re-stem the wrong audio', () => {
    // The re-sent message replaces the original outright; anything the body loses here is lost for
    // good. `dedup:false` is the sharp one: rip-server sends it to FORCE a re-separation after a
    // model/version bump, and silently dropping it would re-stamp the NEW model onto the OLD audio.
    const p = releasePlan({ body: job({ dedup: false }), resultPosted: false });
    expect(JSON.parse(p.body)).toMatchObject({
      songId: 'sng_3be2079ad5e3', srcKey: 'rips/sng_3be2079ad5e3.mp3', tasks: ['stems'], dedup: false,
    });
  });

  it('counts the hops in the body so a re-sent job knows it has been reclaimed before', () => {
    const first = releasePlan({ body: job() }).body;
    const second = releasePlan({ body: first }).body;
    expect(JSON.parse(second).spotRequeues).toBe(2);
  });

  it('STOPS re-sending at the cap — an endless requeue would hide a job from the DLQ forever', () => {
    // The reset is a favour to unlucky songs, not an escape hatch from dead-lettering. Past the cap
    // the job still comes back at once (visibility-0), but its receive count resumes climbing.
    const p = releasePlan({ body: job({ spotRequeues: 3 }) }, { maxRequeues: 3 });
    expect(p.action).toBe('release');
    expect(p.reason).toContain('cap');
  });
  it('honours the configured cap rather than a hard-coded 3', () => {
    expect(releasePlan({ body: job({ spotRequeues: 1 }) }, { maxRequeues: 1 }).action).toBe('release');
    expect(releasePlan({ body: job({ spotRequeues: 1 }) }, { maxRequeues: 9 }).action).toBe('requeue');
  });

  it('DELETES instead of requeueing once the result has been posted', () => {
    // The window between "result sent to the results queue" and "job deleted" is small but real.
    // Requeueing there would buy a duplicate Demucs run for a song that is already finished.
    expect(releasePlan({ body: job(), resultPosted: true }).action).toBe('delete');
  });

  it('falls back to visibility-0 on a body it cannot re-send, rather than stranding the message', () => {
    // Nothing to re-send is not a reason to hold a claim for 1800 s. Hand it back the cheap way.
    for (const body of ['', 'not json', '{', 'null', '"a string"', undefined]) {
      expect(releasePlan({ body }).action).toBe('release');
    }
  });
  it('never throws — this runs while the instance is being torn down', () => {
    for (const arg of [undefined, {}, { body: null }, { body: 7 }]) {
      expect(() => releasePlan(arg)).not.toThrow();
    }
  });

  it('is pure — the same claim decides the same way, and the plan never mutates the input', () => {
    const claim = { body: job(), resultPosted: false };
    expect(releasePlan(claim)).toEqual(releasePlan(claim));
    expect(JSON.parse(claim.body).spotRequeues).toBeUndefined();
  });
});

describe('stemsFromListing — a HALF-UPLOADED stem set must never read as done', () => {
  // doStems uploads vocals → drums → bass → other, one `s3 cp` each, so a reclaim between two of
  // them leaves a partial set on S3. If this dedup gate accepted that, the redelivered job would
  // skip Demucs and post a result claiming 4 stems that do not exist — a silently broken song.
  const ls = (names, bytes = 8_000_000) => names.map((n) => `2026-09-06 12:00:00 ${bytes} ${n}.mp3`).join('\n');
  const ALL = ['vocals', 'drums', 'bass', 'other'];

  it('accepts a complete set', () => {
    const r = stemsFromListing(ls(ALL), 'sng_3be2079ad5e3');
    expect(Object.keys(r.stems).sort()).toEqual(['bass', 'drums', 'other', 'vocals']);
    expect(r.stems.vocals).toBe('rips/stems/sng_3be2079ad5e3/vocals.mp3');
    expect(r.bytes).toBe(32_000_000);
  });

  it('REJECTS every partial set an interrupt could leave behind', () => {
    expect(stemsFromListing(ls(['vocals']), 'sng_x')).toBeNull();
    expect(stemsFromListing(ls(['vocals', 'drums']), 'sng_x')).toBeNull();
    expect(stemsFromListing(ls(['vocals', 'drums', 'bass']), 'sng_x')).toBeNull();   // killed before the last cp
  });

  it('rejects a zero-byte object — a stem that exists but holds nothing is not a stem', () => {
    expect(stemsFromListing(ls(ALL.slice(0, 3)) + '\n2026-09-06 12:00:00 0 other.mp3', 'sng_x')).toBeNull();
  });

  it('rejects an empty or absent listing without throwing', () => {
    expect(stemsFromListing('', 'sng_x')).toBeNull();
    expect(stemsFromListing(null, 'sng_x')).toBeNull();
  });

  it('matches on the CONFIGURED extension — flac stems do not satisfy an mp3 worker', () => {
    expect(stemsFromListing(ls(ALL), 'sng_x', 'flac')).toBeNull();
    expect(stemsFromListing(ALL.map((n) => `2026-09-06 12:00:00 900 ${n}.flac`).join('\n'), 'sng_x', 'flac')).not.toBeNull();
  });
});

describe('importing the worker does not run it', () => {
  it('exports the pure decisions without firing the CLI', () => {
    // Without the entrypoint guard, importing this module would run main(), hit the missing-arg
    // branch, and process.exit(2) out of the test runner — the trap stem-autoscaler.mjs already
    // documents. Reaching this assertion at all is the proof.
    expect(typeof parseSpotInterruption).toBe('function');
    expect(typeof releasePlan).toBe('function');
    expect(typeof stemsFromListing).toBe('function');
  });
});
