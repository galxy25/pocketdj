// SPOT interruption notice — the IMDS `spot/instance-action` parser the worker polls.
//
// On spot, EC2 publishes a ~2-minute termination notice at
// http://169.254.169.254/latest/meta-data/spot/instance-action. Un-marked instances get a plain
// HTTP 404 (curl prints the 404 body, or nothing at all), and that is the case that runs 99.99% of
// the time — one long-running worker polls this thousands of times per lifetime and must be told
// "not interrupted" every single time, cheaply and without throwing.
//
// Throwing is the real hazard here, not mis-parsing. This parser is called from inside the SQS
// consumer loop; an exception on a 404 body, an empty string, or a truncated read would take down
// a worker that is holding an SQS claim, stranding that job inflight for the full 900 s visibility
// timeout — exactly the failure mode `serve()`'s "an error is activity, not idleness" rule exists
// to prevent. Every shape below must return an answer, never raise.
//
// The second half is `releasePlan` — what to do with the in-flight SQS message once the notice
// arrives. That one is about the DLQ, not the clock: SQS offers no way to un-consume a delivery
// attempt, so a job reclaimed maxReceiveCount times would be dead-lettered with nothing wrong
// with it.
import { describe, it, expect } from 'vitest';
import { parseSpotInterruption, releasePlan } from '../../scripts/stem-worker.mjs';

// The literal body IMDS returns for an instance that is NOT marked for interruption.
const IMDS_404 = `<?xml version="1.0" encoding="iso-8859-1"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
 <head><title>404 - Not Found</title></head>
 <body><h1>404 - Not Found</h1></body>
</html>`;

const notice = (action) => JSON.stringify({ action, time: '2026-09-06T12:34:56Z' });

describe('parseSpotInterruption — the not-interrupted case is the hot path', () => {
  it('reads a 404 body as NOT interrupted', () => {
    expect(parseSpotInterruption(IMDS_404).interrupted).toBe(false);
  });
  it('reads an empty body as NOT interrupted — curl on a 404 can print nothing at all', () => {
    expect(parseSpotInterruption('').interrupted).toBe(false);
    expect(parseSpotInterruption('   \n').interrupted).toBe(false);
  });
  it('reads a failed/absent IMDS read as NOT interrupted rather than throwing', () => {
    // A token fetch that failed hands the parser undefined. Guessing "interrupted" there would
    // retire a healthy worker on every IMDS hiccup; throwing would kill it mid-claim.
    expect(parseSpotInterruption(undefined).interrupted).toBe(false);
    expect(parseSpotInterruption(null).interrupted).toBe(false);
  });
  it('never throws on garbage — an exception here strands the in-flight SQS claim for 900s', () => {
    for (const body of ['', '   ', 'null', 'not json at all', '{', '{"action":', IMDS_404, undefined, null]) {
      expect(() => parseSpotInterruption(body)).not.toThrow();
      expect(parseSpotInterruption(body).interrupted).toBe(false);
    }
  });
  it('treats a well-formed notice with NO action as not interrupted', () => {
    expect(parseSpotInterruption('{}').interrupted).toBe(false);
    expect(parseSpotInterruption(JSON.stringify({ time: '2026-09-06T12:34:56Z' })).interrupted).toBe(false);
  });
});

describe('parseSpotInterruption — a real notice', () => {
  it('detects the terminate notice and reports the action', () => {
    const r = parseSpotInterruption(notice('terminate'));
    expect(r.interrupted).toBe(true);
    expect(r.action).toBe('terminate');
  });
  it('detects stop and hibernate too — any action means the box is going away', () => {
    // The worker's response is the same for all three: stop claiming new jobs, finish or abandon
    // the current one, exit. Only `terminate` would be wrong to special-case.
    expect(parseSpotInterruption(notice('stop')).interrupted).toBe(true);
    expect(parseSpotInterruption(notice('hibernate')).interrupted).toBe(true);
  });
  it('carries the deadline through — the worker has ~2 minutes to stop taking work', () => {
    const r = parseSpotInterruption(notice('terminate'));
    const deadline = r.atMs ?? r.time;
    expect(deadline).toBeTruthy();
    expect(new Date(r.atMs ?? r.time).toISOString()).toBe('2026-09-06T12:34:56.000Z');
  });
  it('tolerates surrounding whitespace from the shell capture', () => {
    expect(parseSpotInterruption(`\n${notice('terminate')}\n`).interrupted).toBe(true);
  });
  it('is pure — polling twice on the same body decides the same way', () => {
    expect(parseSpotInterruption(notice('terminate'))).toEqual(parseSpotInterruption(notice('terminate')));
    expect(parseSpotInterruption(IMDS_404)).toEqual(parseSpotInterruption(IMDS_404));
  });
});

// ── releasePlan — handing the claim back without burning the job's way to the DLQ ────────────────
const job = (extra = {}) => JSON.stringify({ songId: 'sng_3be2079ad5e3', srcKey: 'rips/sng_3be2079ad5e3.mp3', ...extra });

describe('releasePlan — a reclaimed job must come back UNPENALISED', () => {
  it('RE-SENDS the job rather than just dropping visibility, because a delivery cannot be un-spent', () => {
    // ChangeMessageVisibility(0) returns the message instantly but the receive it consumed is gone;
    // SQS has no API to decrement ApproximateReceiveCount. With maxReceiveCount=3, three unlucky
    // reclaims dead-letter a song that never actually failed. A NEW message is the only reset there is.
    const p = releasePlan({ body: job(), resultPosted: false });
    expect(p.action).toBe('requeue');
    expect(JSON.parse(p.body).spotRequeues).toBe(1);
  });
  it('carries the WHOLE job through the re-send — a dropped field is a silently wrong job', () => {
    // dedup:false is the sharp one: rip-server sends it to FORCE a re-stem after a model/version
    // bump. Losing it turns the retry into an existingStems() skip that re-stamps the STALE stems
    // as current. tasks and srcKey have the same character.
    const p = releasePlan({ body: job({ tasks: ['stems', 'lyrics'], dedup: false }), resultPosted: false });
    expect(JSON.parse(p.body)).toEqual({
      songId: 'sng_3be2079ad5e3', srcKey: 'rips/sng_3be2079ad5e3.mp3',
      tasks: ['stems', 'lyrics'], dedup: false, spotRequeues: 1,
    });
  });
  it('counts hops across successive reclaims instead of resetting to 1 each time', () => {
    expect(JSON.parse(releasePlan({ body: job({ spotRequeues: 1 }) }).body).spotRequeues).toBe(2);
    expect(JSON.parse(releasePlan({ body: job({ spotRequeues: 2 }) }).body).spotRequeues).toBe(3);
  });
  it('STOPS re-sending at the cap so a pathological job can still reach the DLQ', () => {
    // Re-sending forever would hide a genuinely poisonous message from the DLQ entirely: it would
    // be reclaimed, re-sent, reclaimed, re-sent, and never accumulate the receives that retire it.
    // Past the cap the plan falls back to visibility-0 — still instant, but the count resumes.
    const p = releasePlan({ body: job({ spotRequeues: 3 }) });
    expect(p.action).toBe('release');
    expect(p.reason).toMatch(/cap/);
  });
  it('honours a caller-supplied cap', () => {
    expect(releasePlan({ body: job({ spotRequeues: 1 }) }, { maxRequeues: 1 }).action).toBe('release');
    expect(releasePlan({ body: job({ spotRequeues: 1 }) }, { maxRequeues: 5 }).action).toBe('requeue');
  });

  it('DELETES a job whose result was already posted — it is finished, not interrupted', () => {
    // Requeueing here buys a duplicate Demucs run for a song that is already stemmed.
    const p = releasePlan({ body: job(), resultPosted: true });
    expect(p.action).toBe('delete');
  });
  it('falls back to visibility-0 when there is no body to re-send', () => {
    // Nothing to reconstruct, but the claim must still be handed back — holding it is the stall.
    for (const bad of [undefined, null, '', 'not json', '{', 'null', '"a string"']) {
      expect(releasePlan({ body: bad }).action).toBe('release');
    }
    expect(releasePlan().action).toBe('release');
    expect(releasePlan({}).action).toBe('release');
  });
  it('does not re-send a body that has no songId to re-send', () => {
    // `{...parsed, spotRequeues}` over an array or an empty object mints a NEW queue message with
    // no songId. poll() deletes such a message on receipt, so this self-cleans and costs only a
    // wasted round-trip — but the plan should say `release` rather than manufacture a junk job.
    expect(releasePlan({ body: '[]' }).action).toBe('release');
    expect(releasePlan({ body: '{}' }).action).toBe('release');
  });
  it('treats a non-numeric hop counter as at-cap rather than re-sending forever', () => {
    expect(releasePlan({ body: job({ spotRequeues: 'lots' }) }).action).toBe('release');
  });
  it('always returns one of delete | requeue | release — the caller has no other branch', () => {
    const inputs = [{ body: job(), resultPosted: true }, { body: job() },
      { body: job({ spotRequeues: 9 }) }, { body: 'garbage' }, {}];
    for (const i of inputs) expect(['delete', 'requeue', 'release']).toContain(releasePlan(i).action);
  });
  it('never throws, and never mutates the message it was handed', () => {
    const m = { body: job({ tasks: ['stems'] }), resultPosted: false };
    const before = JSON.stringify(m);
    expect(() => releasePlan(m)).not.toThrow();
    expect(JSON.stringify(m)).toBe(before);
  });
});
