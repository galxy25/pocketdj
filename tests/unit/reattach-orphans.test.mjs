// Golden tests for the orphan-sweep fold (re-attach songs whose albumId resolves to a real
// album but which are missing from that album's trackList). reattach-orphans.mjs exports
// reattachOrphans (no I/O when imported), modeled on the real Jay-Z "Vol. 3..." case where
// two web-confirmed BONUS tracks ("Jigga My Nigga" #16, "Girl's Best Friend" #17) were left
// dangling off a 15-track trackList.
import { describe, it, expect } from 'vitest';
import { reattachOrphans } from '../../.claude/skills/analog-indexer/lib/reattach-orphans.mjs';

describe('reattachOrphans', () => {
  it('re-attaches bonus tracks at the position implied by trackNumber (Jay-Z case)', () => {
    const idx = {
      albums: [
        { id: 'alb', artist: 'Jay-Z', name: 'Vol. 3', trackList: ['t1', 't2'] },
      ],
      songs: [
        { id: 't1', albumId: 'alb', name: 'Intro', trackNumber: 1 },
        { id: 't2', albumId: 'alb', name: 'Outro', trackNumber: 15 },
        // two orphans: same albumId, NOT in trackList, higher trackNumbers
        { id: 'b16', albumId: 'alb', name: 'Jigga My N', trackNumber: 16 },
        { id: 'b17', albumId: 'alb', name: "Girl's Best Friend", trackNumber: 17 },
      ],
    };
    const r = reattachOrphans(idx);
    expect(r.reattached).toBe(2);
    expect(r.trueOrphans).toBe(0);
    // inserted in trackNumber order after the existing members
    expect(idx.albums[0].trackList).toEqual(['t1', 't2', 'b16', 'b17']);
  });

  it('inserts an orphan in the MIDDLE when its trackNumber falls between existing tracks', () => {
    const idx = {
      albums: [{ id: 'alb', trackList: ['t1', 't3'] }],
      songs: [
        { id: 't1', albumId: 'alb', name: 'A', trackNumber: 1 },
        { id: 't3', albumId: 'alb', name: 'C', trackNumber: 3 },
        { id: 't2', albumId: 'alb', name: 'B', trackNumber: 2 }, // orphan, belongs between
      ],
    };
    reattachOrphans(idx);
    expect(idx.albums[0].trackList).toEqual(['t1', 't2', 't3']);
  });

  it('appends an orphan with no/invalid trackNumber at the end', () => {
    const idx = {
      albums: [{ id: 'alb', trackList: ['t1'] }],
      songs: [
        { id: 't1', albumId: 'alb', name: 'A', trackNumber: 1 },
        { id: 'tx', albumId: 'alb', name: 'X' }, // no trackNumber
      ],
    };
    reattachOrphans(idx);
    expect(idx.albums[0].trackList).toEqual(['t1', 'tx']);
  });

  it('leaves a TRUE orphan (albumId resolves to no album) untouched, but reports it', () => {
    const idx = {
      albums: [{ id: 'alb', trackList: ['t1'] }],
      songs: [
        { id: 't1', albumId: 'alb', name: 'A', trackNumber: 1 },
        { id: 'ghost', albumId: 'alb_missing', name: 'Ghost', trackNumber: 1 },
      ],
    };
    const r = reattachOrphans(idx);
    expect(r.reattached).toBe(0);
    expect(r.trueOrphans).toBe(1);
    expect(idx.albums[0].trackList).toEqual(['t1']);
  });

  it('does not duplicate a song already in its album trackList', () => {
    const idx = {
      albums: [{ id: 'alb', trackList: ['t1', 't2'] }],
      songs: [
        { id: 't1', albumId: 'alb', name: 'A', trackNumber: 1 },
        { id: 't2', albumId: 'alb', name: 'B', trackNumber: 2 },
      ],
    };
    const r = reattachOrphans(idx);
    expect(r.reattached).toBe(0);
    expect(idx.albums[0].trackList).toEqual(['t1', 't2']);
  });

  it('is idempotent', () => {
    const idx = {
      albums: [{ id: 'alb', trackList: ['t1'] }],
      songs: [
        { id: 't1', albumId: 'alb', name: 'A', trackNumber: 1 },
        { id: 't2', albumId: 'alb', name: 'B', trackNumber: 2 },
      ],
    };
    reattachOrphans(idx);
    const after = JSON.parse(JSON.stringify(idx));
    const r2 = reattachOrphans(idx);
    expect(r2.reattached).toBe(0);
    expect(idx).toEqual(after);
  });
});
