// timbre-batch work-list discipline — segment identity only, one task per song, skips with
// reasons. The cutKey lesson is the spine of these tests: every track on a vinyl side shares
// ONE raw file, so the work list must give each song its OWN window (pointer.startMs) or no
// task at all — trackNumber/audioTracks ordinals are never consulted (f2b427c5).
import { describe, it, expect } from 'vitest';
import { buildWorkList, segmentForSong, CUT_WINDOW_SEC, RANGE_BYTES,
         routeWorkerResponse, classifyResult, PERMANENT_ERRORS } from '../../scripts/timbre-batch.mjs';

const BASE = '/vinyl';
const existsAll = () => true;

function analogIndex() {
  return {
    albums: [{
      id: 'alb_1',
      pointer: { originalFilename: 'BlondieParallelLinesRaw.mp3' },
      // Adversarial: audioTracks ordinals DISAGREE with song trackNumbers — if any code path
      // keyed on trackNumber these would leak into the tasks. They must be inert.
      audioTracks: [
        { trackNumber: 1, startMs: 999999, endMs: 1999999 },
        { trackNumber: 2, startMs: 2999999, endMs: 3999999 },
      ],
    }],
    songs: [
      { id: 'sng_a', albumId: 'alb_1', trackNumber: 2, length: 135442,
        pointer: { startMs: 11726, endMs: 147168 } },
      { id: 'sng_b', albumId: 'alb_1', trackNumber: 1, length: null,
        pointer: { startMs: 154784, endMs: 363299 } },
      // No segment of its own (duplicate/bonus tracklist entry) — must be SKIPPED with reason,
      // never given the album file or a sibling's window.
      { id: 'sng_dup', albumId: 'alb_1', trackNumber: 1, length: null,
        pointer: { timestamps: null } },
    ],
  };
}

describe('segmentForSong', () => {
  const idx = analogIndex();
  it('uses the song\'s OWN pointer.startMs + length', () => {
    expect(segmentForSong(idx.songs[0], idx.albums[0]))
      .toEqual({ file: 'BlondieParallelLinesRaw.mp3', startMs: 11726, durMs: 135442 });
  });
  it('derives duration from the song\'s own endMs when length is null', () => {
    expect(segmentForSong(idx.songs[1], idx.albums[0]).durMs).toBe(363299 - 154784);
  });
  it('returns null (no fabrication) without the song\'s own startMs', () => {
    expect(segmentForSong(idx.songs[2], idx.albums[0])).toBeNull();
  });
});

describe('buildWorkList', () => {
  it('two songs sharing one raw file get DISTINCT windows; the segment-less one is skipped', () => {
    const { tasks, skipped } = buildWorkList({
      manifest: {}, analogIndex: analogIndex(), analogBase: BASE, exists: existsAll,
    });
    const byId = new Map(tasks.map((t) => [t.id, t]));
    const a = byId.get('sng_a'); const b = byId.get('sng_b');
    expect(a.kind).toBe('vinyl-cut');
    expect(a.file).toBe(b.file);                       // same shared raw file…
    expect(a.startMs).not.toBe(b.startMs);             // …different windows — never one vector
    expect(a.startMs).toBe(11726);
    expect(b.startMs).toBe(154784);
    expect(byId.has('sng_dup')).toBe(false);
    expect(skipped.sng_dup).toBe('no-segment');
  });

  it('adversarial: album audioTracks ordinals never leak into tasks', () => {
    const { tasks } = buildWorkList({
      manifest: {}, analogIndex: analogIndex(), analogBase: BASE, exists: existsAll,
    });
    for (const t of tasks) {
      expect(t.startMs).not.toBe(999999);
      expect(t.startMs).not.toBe(2999999);
    }
  });

  it('per-song rip (manifest source digital) outranks the vinyl cut for the same id', () => {
    const { tasks } = buildWorkList({
      manifest: { sng_a: { source: 'digital', key: 'rips/sng_a.mp3' } },
      analogIndex: analogIndex(), analogBase: BASE, exists: existsAll,
    });
    const a = tasks.find((t) => t.id === 'sng_a');
    expect(a.kind).toBe('s3-song');
    expect(a.key).toBe('rips/sng_a.mp3');
    // and the vinyl siblings are still present exactly once
    expect(tasks.filter((t) => t.id === 'sng_a')).toHaveLength(1);
    expect(tasks.find((t) => t.id === 'sng_b').kind).toBe('vinyl-cut');
  });

  it('raw file missing locally → S3 per-song cut fallback, else skipped-with-reason', () => {
    const { tasks, skipped } = buildWorkList({
      manifest: {
        sng_a: { source: 'analog', key: 'rips/alb_1.mp3', cutKey: 'rips/sng_a.cut.mp3', startMs: 11726 },
        sng_b: { source: 'analog', key: 'rips/alb_1.mp3', startMs: 154784 }, // no cutKey
      },
      analogIndex: analogIndex(), analogBase: BASE, exists: () => false,     // raw NOT on disk
    });
    const a = tasks.find((t) => t.id === 'sng_a');
    expect(a.kind).toBe('s3-cut');
    expect(a.key).toBe('rips/sng_a.cut.mp3');          // the song's own cut object, never the album key
    expect(tasks.find((t) => t.id === 'sng_b')).toBeUndefined();
    expect(skipped.sng_b).toBe('raw-missing');
  });

  it('window constants: truncation can only touch files where the engine offset is already clamped', () => {
    // Engine: off = min(5% of length, 5 s), window 90 s → needs the first 95 s. Any file the
    // 130 s cut / 5 MB range truncates is ≥ 100 s long, where off is pinned at 5 s — so the
    // analysed window is identical to a full read. These constants must keep that headroom.
    expect(CUT_WINDOW_SEC).toBeGreaterThanOrEqual(100);
    expect(RANGE_BYTES).toBeGreaterThanOrEqual((100 * 320000) / 8); // ≥100 s even at 320 kbps
  });
});

describe('worker response attribution', () => {
  // THE FAILURE THIS PREVENTS IS SILENT AND UNRECOVERABLE. The worker echoes the task id back;
  // the driver used to ignore it and resolve whatever was in flight with whatever arrived. One
  // stray or late line desynchronises the stream and EVERY subsequent vector is written under the
  // PREVIOUS song's id — a measurement attributed to audio it did not come from, which is
  // indistinguishable from a real row downstream. Four rows of a 223-song proving run came back
  // in 2 ms (a 3.5 s workload) this way. The cloud lane runs this same driver on EC2 at scale.
  it('resolves only the task actually in flight', () => {
    expect(routeWorkerResponse({ id: 'sng_a' }, { id: 'sng_a', ok: true })).toBe('resolve');
  });

  it('DROPS a response naming a different song — the one line that poisoned the corpus', () => {
    expect(routeWorkerResponse({ id: 'sng_a' }, { id: 'sng_b', ok: true })).toBe('mismatched');
  });

  it('drops a response arriving with nothing in flight', () => {
    expect(routeWorkerResponse(null, { id: 'sng_a', ok: true })).toBe('unmatched');
  });

  it('an id-less line still resolves — the worker contract predates the echo, and dropping every\n'
     + '     unlabelled line would strand a shard forever rather than lose one song', () => {
    expect(routeWorkerResponse({ id: 'sng_a' }, { ok: true })).toBe('resolve');
  });

  it('a dropped line must not be silently swallowed into the WRONG task either', () => {
    // Sequencing check: after a mismatch the pending task is still pending, so the next correct
    // line resolves it. (If the driver cleared `pending` on a mismatch, the real answer would
    // then arrive as 'unmatched' and the song would be lost, not retried.)
    const pending = { id: 'sng_a' };
    expect(routeWorkerResponse(pending, { id: 'sng_b' })).toBe('mismatched');
    expect(routeWorkerResponse(pending, { id: 'sng_a' })).toBe('resolve');
  });
});

describe('failure classification', () => {
  // Recording an unexplained failure as permanent puts the song in the done-set FOREVER: a
  // transient worker hiccup becomes a hole in the corpus no re-run can fill, and the only visible
  // symptom is a coverage number that will not move. Four rows of a 223-song proving run failed
  // this way, and all four analysed cleanly when re-run by hand.
  it('permanence is a CLOSED list of engine verdicts, not "anything that failed"', () => {
    expect([...PERMANENT_ERRORS].sort())
      .toEqual(['degenerate-axes', 'non-finite-axis', 'silent', 'too-short']);
  });

  it('the engine rejecting the AUDIO on its own contract is permanent', () => {
    for (const e of ['too-short', 'silent', 'degenerate-axes', 'non-finite-axis'])
      expect(classifyResult({ ok: false, error: e })).toBe('permanent');
    expect(classifyResult({ ok: false, error: '  silent  ' })).toBe('permanent');
  });

  it('anything else is the ENVIRONMENT and stays retryable', () => {
    for (const e of ['no vector', 'NoBackendError', 'worker timeout', '', undefined, null])
      expect(classifyResult({ ok: false, error: e })).toBe('transient');
    expect(classifyResult({})).toBe('transient');
    expect(classifyResult(undefined)).toBe('transient');
  });

  it('"ok" needs a VECTOR, not just an ok flag — an ok row with no `f` is not a measurement', () => {
    expect(classifyResult({ ok: true, f: { bright: 0.5 } })).toBe('ok');
    expect(classifyResult({ ok: true })).toBe('transient');
  });
});
