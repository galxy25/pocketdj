// F3 "Sharing" streaming-links pipeline — pure-logic guards for the two fragile bits:
//   1. the Apple Music canonical URL derivation (fold-apple-music-links.mjs), and
//   2. the browser resolver's candidate SCORING (resolve-streaming-links.mjs) — specifically the
//      version-marker discipline that must REJECT a remix/sped-up/cover the library track lacks
//      (a wrong "Share on Spotify" link is worse than none).
// These import the scripts' exported helpers directly (no browser needed).
import { describe, it, expect } from 'vitest';
import { songUrl, albumUrl } from '../../scripts/fold-apple-music-links.mjs';
import { scoreCandidate, pickBest, normalize, coreTitle, indexPath, parseArgs } from '../../scripts/resolve-streaming-links.mjs';

describe('apple music url derivation', () => {
  it('builds the canonical song + album short-forms', () => {
    expect(songUrl('1771724281')).toBe('https://music.apple.com/song/1771724281');
    expect(albumUrl('1771723600')).toBe('https://music.apple.com/album/1771723600');
  });
});

describe('normalize / coreTitle', () => {
  it('folds case, accents, ampersands, and strips leading "the"', () => {
    expect(normalize('The Beatles & Friends')).toBe('beatles and friends');
    expect(normalize('QUIÑ')).toBe('quin');
  });
  it('coreTitle drops parentheticals/brackets', () => {
    expect(coreTitle('Post To Be (feat. Chris Brown & Jhene Aiko)')).toBe('post to be');
    expect(coreTitle('Versace (feat. Drake) [Remix]')).toBe('versace');
  });
});

describe('scoreCandidate', () => {
  const song = { artist: 'Childish Gambino', name: 'Redbone' };

  it('rewards an exact title + artist match', () => {
    expect(scoreCandidate(song, { title: 'Redbone', artist: 'Childish Gambino' })).toBeGreaterThanOrEqual(100);
  });

  it('accepts a feat.-spillover artist (containment) via core-title match', () => {
    const s = { artist: 'Childish Gambino', name: 'Late Night In Kauai (feat. Jaden)' };
    expect(scoreCandidate(s, { title: 'Late Night In Kauai', artist: 'Childish Gambino, Jaden Smith' })).toBeGreaterThan(0);
  });

  it('penalizes a remix/sped-up the library track does not ask for, below threshold', () => {
    // The version-marker penalty (−40) drags a same-title, same-artist remix under the default
    // min-score (60) so pickBest drops it — a genuine "Redbone" scores far higher (135).
    const parenRemix = scoreCandidate(song, { title: 'Redbone (Slowed + Reverb)', artist: 'Childish Gambino' });
    const dashRemix = scoreCandidate(song, { title: 'Redbone - Slowed + Reverb', artist: 'Childish Gambino' });
    const exact = scoreCandidate(song, { title: 'Redbone', artist: 'Childish Gambino' });
    expect(parenRemix).toBeLessThan(60);
    expect(dashRemix).toBeLessThan(60);
    expect(exact).toBeGreaterThan(parenRemix + 40);
    // The pipeline gate: with only the remix available, resolve records a MISS, not a wrong link.
    expect(pickBest(song, [{ url: 'sp://r', title: 'Redbone (Slowed + Reverb)', artist: 'Childish Gambino' }], 60)).toBeNull();
  });

  it('REJECTS a wrong artist even on a title hit', () => {
    expect(scoreCandidate(song, { title: 'Redbone', artist: 'Some Cover Band' })).toBe(-1);
  });

  it('falls back to rowText for the artist gate when the artist field is empty', () => {
    expect(scoreCandidate(song, { title: 'Redbone', artist: '', rowText: 'Redbone Childish Gambino 5:26' })).toBeGreaterThan(0);
    expect(scoreCandidate(song, { title: 'Redbone', artist: '', rowText: 'Redbone Nobody Else' })).toBe(-1);
  });
});

describe('pickBest', () => {
  const song = { artist: 'Migos', name: 'Versace (feat. Drake) [Remix]' };
  it('picks the highest-scoring plausible candidate above the threshold', () => {
    const best = pickBest(song, [
      { url: 'sp://a', title: 'Versace', artist: 'Migos' },
      { url: 'sp://b', title: 'Bad and Boujee', artist: 'Migos' },
    ], 60);
    expect(best.url).toBe('sp://a');
    expect(best.score).toBeGreaterThanOrEqual(60);
  });
  it('returns null when nothing clears the threshold', () => {
    expect(pickBest(song, [{ url: 'sp://x', title: 'Totally Different Song', artist: 'Someone' }], 60)).toBeNull();
  });
});

describe('indexPath + parseArgs', () => {
  it('resolves --index shorthands to public/ paths', () => {
    expect(indexPath('apple-music')).toMatch(/public\/apple-music-index\.json$/);
    expect(indexPath('current')).toMatch(/public\/current-index\.json$/);
    expect(indexPath('digital')).toMatch(/public\/digital-index\.json$/);
    expect(indexPath('/abs/custom.json')).toBe('/abs/custom.json');
  });
  it('parses flags with sane defaults', () => {
    const a = parseArgs(['node', 'x', '--index', 'current', '--limit', '15', '--services', 'spotify', '--retry-misses']);
    expect(a.index).toBe('current');
    expect(a.limit).toBe(15);
    expect(a.services).toEqual(['spotify']);
    expect(a.retryMisses).toBe(true);
    expect(a.minScore).toBe(60);
  });
});
