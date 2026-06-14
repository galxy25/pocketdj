// Tests for the iTunes URL builders + the deterministic fuzzy-match scorer.
import { describe, it, expect } from 'vitest';
import {
  searchUrl,
  lookupUrl,
  upscaleArtwork,
  scoreCandidate,
  classifyMatch,
  yearOf,
} from '../../.claude/skills/analog-indexer/lib/itunes.js';

const cand = (artistName, collectionName, extra = {}) => ({
  artistName,
  collectionName,
  ...extra,
});

describe('searchUrl', () => {
  it('encodes the term and applies defaults', () => {
    expect(searchUrl('ABBA Greatest Hits')).toBe(
      'https://itunes.apple.com/search?term=ABBA%20Greatest%20Hits&entity=album&limit=8&country=US',
    );
  });

  it('honors limit and country overrides', () => {
    expect(searchUrl('x', { limit: 3, country: 'GB' })).toBe(
      'https://itunes.apple.com/search?term=x&entity=album&limit=3&country=GB',
    );
  });

  it('escapes special characters', () => {
    expect(searchUrl('Hall & Oates')).toContain('term=Hall%20%26%20Oates');
  });
});

describe('lookupUrl', () => {
  it('builds a song-entity lookup url from a collection id', () => {
    expect(lookupUrl(12345)).toBe(
      'https://itunes.apple.com/lookup?id=12345&entity=song&country=US',
    );
  });

  it('honors the country override', () => {
    expect(lookupUrl(9, { country: 'CA' })).toContain('country=CA');
  });
});

describe('upscaleArtwork', () => {
  it('upscales a 100x100 jpg to the requested size', () => {
    expect(upscaleArtwork('https://is1.mzstatic.com/a/100x100bb.jpg')).toBe(
      'https://is1.mzstatic.com/a/600x600bb.jpg',
    );
  });

  it('respects a custom size', () => {
    expect(upscaleArtwork('https://x/60x60bb.png', 1200)).toBe(
      'https://x/1200x1200bb.png',
    );
  });

  it('passes through falsy / non-matching urls unchanged', () => {
    expect(upscaleArtwork('')).toBe('');
    expect(upscaleArtwork(null)).toBeNull();
    expect(upscaleArtwork('https://x/no-dimensions.jpg')).toBe(
      'https://x/no-dimensions.jpg',
    );
  });
});

describe('yearOf', () => {
  it('extracts the 4-digit year from an ISO release date', () => {
    expect(yearOf('1980-06-01T00:00:00Z')).toBe(1980);
  });

  it('returns undefined for missing / malformed dates', () => {
    expect(yearOf(undefined)).toBeUndefined();
    expect(yearOf('')).toBeUndefined();
    expect(yearOf('not-a-date')).toBeUndefined();
  });
});

describe('scoreCandidate', () => {
  it('scores an exact artist+album combination highly', () => {
    const s = scoreCandidate('ABBA Greatest Hits', cand('ABBA', 'Greatest Hits'));
    expect(s).toBeGreaterThanOrEqual(0.62);
  });

  it('scores an unrelated candidate near zero', () => {
    const s = scoreCandidate('ABBA Greatest Hits', cand('Metallica', 'Master of Puppets'));
    expect(s).toBeLessThan(0.45);
  });

  it('penalizes a Single/EP suffix when the blob is not a single', () => {
    const album = scoreCandidate('Madonna Holiday', cand('Madonna', 'Holiday'));
    const single = scoreCandidate('Madonna Holiday', cand('Madonna', 'Holiday - Single'));
    expect(single).toBeLessThan(album);
  });

  it('penalizes a Various Artists candidate when the blob looks single-artist', () => {
    const real = scoreCandidate('Aaliyah One In A Million', cand('Aaliyah', 'One In A Million'));
    const va = scoreCandidate(
      'Aaliyah One In A Million',
      cand('Various Artists', 'One In A Million'),
    );
    expect(va).toBeLessThan(real);
  });

  it('clamps the score to the [0, 1.3] range', () => {
    const s = scoreCandidate('ABBA Greatest Hits', cand('ABBA', 'Greatest Hits'));
    expect(s).toBeGreaterThanOrEqual(0);
    expect(s).toBeLessThanOrEqual(1.3);
    // a strong negative-penalty case never goes below 0
    const neg = scoreCandidate('xyz', cand('Various Artists', 'Nothing - Single'));
    expect(neg).toBeGreaterThanOrEqual(0);
  });

  it('tolerates missing fields on the candidate', () => {
    expect(() => scoreCandidate('ABBA', {})).not.toThrow();
    expect(scoreCandidate('ABBA', {})).toBe(0);
  });
});

describe('classifyMatch', () => {
  it('returns unmatched for empty / missing results', () => {
    expect(classifyMatch('ABBA', [])).toEqual({
      status: 'unmatched',
      best: null,
      score: 0,
      margin: 0,
    });
    expect(classifyMatch('ABBA', null).status).toBe('unmatched');
  });

  it('classifies a clearly-correct top result as a strong match', () => {
    const results = [
      cand('ABBA', 'Greatest Hits'),
      cand('Metallica', 'Master of Puppets'),
    ];
    const r = classifyMatch('ABBA Greatest Hits', results);
    expect(r.status).toBe('matched');
    expect(r.confidence).toBe('strong');
    expect(r.best.artistName).toBe('ABBA');
    expect(r.margin).toBeGreaterThanOrEqual(0.08);
  });

  it('ranks the best candidate to the top regardless of input order', () => {
    const results = [
      cand('Metallica', 'Master of Puppets'),
      cand('ABBA', 'Greatest Hits'),
    ];
    const r = classifyMatch('ABBA Greatest Hits', results);
    expect(r.best.artistName).toBe('ABBA');
  });

  it('rounds score and margin to 3 decimals', () => {
    const r = classifyMatch('ABBA Greatest Hits', [cand('ABBA', 'Greatest Hits')]);
    // single result -> second score is 0, margin == score
    expect(Number(r.score.toFixed(3))).toBe(r.score);
    expect(Number(r.margin.toFixed(3))).toBe(r.margin);
  });

  it('classifies a no-overlap result set as unmatched', () => {
    const r = classifyMatch('ABBA Greatest Hits', [cand('Slayer', 'Reign in Blood')]);
    expect(r.status).toBe('unmatched');
    expect(r.confidence).toBeUndefined();
  });
});
