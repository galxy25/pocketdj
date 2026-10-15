// playerOnTrack: the rip skill's "is Music.app on the track we asked for?" check.
// Punctuation never decides identity; words (credits, version markers) still do.
import { describe, it, expect } from 'vitest';
import { playerOnTrack } from '../../scripts/lib/am-match.mjs';

describe('playerOnTrack', () => {
  it('ignores hyphens, dashes, apostrophes, dots and & vs and', () => {
    expect(playerOnTrack('Hip Hop', 'Hip-Hop')).toBe(true); // Static-X & Dead Prez, 2026-10-14
    expect(playerOnTrack('Party Don’t Stop', "Party Don't Stop")).toBe(true);
    expect(playerOnTrack('Rock & Roll', 'Rock and Roll')).toBe(true);
    expect(playerOnTrack('Mr. Brightside', 'Mr Brightside')).toBe(true);
    expect(playerOnTrack('Café del Mar — Edit', 'Cafe del Mar - Edit')).toBe(true);
  });

  it('still refuses a different credit or version', () => {
    // Terrace Martin & Curly, 2026-10-14: a genuinely different recording
    expect(playerOnTrack('Bromali (feat. Robert Sput Searight, Larry Goldings & Nir Felder)',
      'Bromali (feat. Marlon Williams)')).toBe(false);
    expect(playerOnTrack('Hip Hop', 'Hey Ya!')).toBe(false);
  });

  it('keeps the old prefix tolerance for truncated / suffixed display names', () => {
    expect(playerOnTrack('A Very Long Song Title That Goes On (Extended Mix)', 'A Very Long Song Title That Goes On')).toBe(true);
    expect(playerOnTrack('Song', 'Song (2011 Remaster)')).toBe(true);
  });

  it('does not refuse when either title is missing', () => {
    expect(playerOnTrack('', 'Anything')).toBe(true);
    expect(playerOnTrack('Something', '')).toBe(true);
  });
});
