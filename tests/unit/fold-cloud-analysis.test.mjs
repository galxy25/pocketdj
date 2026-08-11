// fold-cloud-analysis — the default-scope fix + the stamping rule's attribution guarantees.
//
// REGRESSION: the default POCKETDJ_FOLD_INDEXES was digital-index.json ONLY, so every cloud
// analysis of a per-song rip whose catalog row lives in apple-music-index.json (~680 songs) or
// current-index.json (~88 analog songs with their own Apple Music capture) was silently
// discarded — paid for, never stamped. The default must cover all three indexes.
import { describe, it, expect } from 'vitest';
import { DEFAULT_FOLD_INDEXES, stampSongs } from '../../scripts/fold-cloud-analysis.mjs';

describe('DEFAULT_FOLD_INDEXES', () => {
  it('covers every index a per-song cloud analysis can belong to', () => {
    expect(DEFAULT_FOLD_INDEXES).toEqual([
      'public/digital-index.json',
      'public/apple-music-index.json',
      'public/current-index.json',
    ]);
  });
});

describe('stampSongs attribution', () => {
  const manifest = {
    // A per-song cloud rip of an Apple-Music-library song: its OWN entry, its OWN analysis.
    sng_am: { source: 'digital', key: 'rips/sng_am.mp3', bpm: 118.2, musicalKey: 'A minor', camelot: '8A' },
    // An ANALOG album-level entry: no per-song bpm ever, and the source guard must skip it even
    // if a bpm somehow appeared (a whole-album value must never stamp a single song).
    sng_vinyl: { source: 'analog', key: 'rips/alb_9.mp3', startMs: 12000, bpm: 999 },
    // Cloud hasn't analyzed this one yet — its catalog nulls must survive untouched.
    sng_wait: { source: 'digital', key: 'rips/sng_wait.mp3', bpm: null, musicalKey: null, camelot: null },
  };

  it('stamps only from manifest[song.id] — the song\'s own analyzed capture', () => {
    const idx = { songs: [
      { id: 'sng_am', bpm: null, key: null, camelot: null },
      { id: 'sng_vinyl', bpm: 152, key: 'D# major', camelot: '5B' },
      { id: 'sng_wait', bpm: null, key: null, camelot: null },
      { id: 'sng_nomanifest', bpm: null, key: null, camelot: null },
    ] };
    const r = stampSongs(idx, manifest);
    const byId = new Map(idx.songs.map((s) => [s.id, s]));
    expect(byId.get('sng_am')).toMatchObject({ bpm: 118.2, key: 'A minor', camelot: '8A' });
    // analog entry NEVER clobbers the curated segment values, bpm present or not:
    expect(byId.get('sng_vinyl')).toMatchObject({ bpm: 152, key: 'D# major', camelot: '5B' });
    expect(byId.get('sng_wait').bpm).toBeNull();
    expect(byId.get('sng_nomanifest').bpm).toBeNull();
    expect(r).toMatchObject({ stamped: 1, nonDigitalSkipped: 1, unanalyzed: 1, noEntry: 1 });
  });

  it('a missing manifest field never NULLs an existing catalog value', () => {
    const idx = { songs: [{ id: 'sng_partial', bpm: 100, key: 'C major', camelot: '8B' }] };
    stampSongs(idx, { sng_partial: { source: 'digital', bpm: 101.5, musicalKey: null, camelot: null } });
    expect(idx.songs[0]).toMatchObject({ bpm: 101.5, key: 'C major', camelot: '8B' });
  });

  it('is idempotent: a second stamp changes nothing', () => {
    const idx = { songs: [{ id: 'sng_am', bpm: null, key: null, camelot: null }] };
    stampSongs(idx, manifest);
    const r2 = stampSongs(idx, manifest);
    expect(r2.stamped).toBe(0);
  });
});
