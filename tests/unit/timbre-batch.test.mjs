// timbre-batch work-list discipline — segment identity only, one task per song, skips with
// reasons. The cutKey lesson is the spine of these tests: every track on a vinyl side shares
// ONE raw file, so the work list must give each song its OWN window (pointer.startMs) or no
// task at all — trackNumber/audioTracks ordinals are never consulted (f2b427c5).
import { describe, it, expect } from 'vitest';
import { buildWorkList, segmentForSong, CUT_WINDOW_SEC, RANGE_BYTES } from '../../scripts/timbre-batch.mjs';

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
