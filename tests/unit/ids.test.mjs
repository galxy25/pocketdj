// Tests for the content-derived, idempotent album/song id helpers.
import { describe, it, expect } from 'vitest';
import { albumId, songId } from '../../.claude/skills/analog-indexer/lib/ids.js';

describe('albumId', () => {
  it('produces an alb_-prefixed 12-hex-char id', () => {
    const id = albumId('The Brothers Johnson', 'Light Up The Night');
    expect(id).toMatch(/^alb_[0-9a-f]{12}$/);
  });

  it('is stable / idempotent for the same inputs', () => {
    const a = albumId('ABBA', 'Greatest Hits', null);
    const b = albumId('ABBA', 'Greatest Hits', null);
    expect(a).toBe(b);
  });

  it('is invariant under normalization (The-prefix, &, apostrophes, case)', () => {
    expect(albumId('The Hall & Oates', "Don't")).toBe(
      albumId('hall and oates', 'dont'),
    );
  });

  it('treats dupIndex null and 1 as the same album (default pressing)', () => {
    expect(albumId('X', 'Y', null)).toBe(albumId('X', 'Y', 1));
  });

  it('gives duplicate pressings distinct ids', () => {
    const first = albumId('The Brothers Johnson', 'Light Up The Night', null);
    const second = albumId('The Brothers Johnson', 'Light Up The Night', 2);
    expect(first).not.toBe(second);
  });

  it('distinguishes different albums', () => {
    expect(albumId('ABBA', 'Arrival')).not.toBe(albumId('ABBA', 'Voulez-Vous'));
  });
});

describe('songId', () => {
  it('produces an sng_-prefixed 12-hex-char id', () => {
    const aid = albumId('ABBA', 'Greatest Hits');
    expect(songId(aid, 1, 1)).toMatch(/^sng_[0-9a-f]{12}$/);
  });

  it('is stable for the same album + position', () => {
    const aid = albumId('ABBA', 'Greatest Hits');
    expect(songId(aid, 3, 1)).toBe(songId(aid, 3, 1));
  });

  it('defaults the disc number to 1', () => {
    const aid = albumId('ABBA', 'Greatest Hits');
    expect(songId(aid, 5)).toBe(songId(aid, 5, 1));
  });

  it('distinguishes track positions and discs', () => {
    const aid = albumId('ABBA', 'Greatest Hits');
    expect(songId(aid, 1, 1)).not.toBe(songId(aid, 2, 1));
    expect(songId(aid, 1, 1)).not.toBe(songId(aid, 1, 2));
  });

  it('scopes ids to the album (same position, different album -> different id)', () => {
    const a1 = albumId('ABBA', 'Arrival');
    const a2 = albumId('ABBA', 'Voulez-Vous');
    expect(songId(a1, 1, 1)).not.toBe(songId(a2, 1, 1));
  });
});
