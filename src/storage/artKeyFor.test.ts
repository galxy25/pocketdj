// Unit tests for artKeyFor — the PURE, network-free art-cache key derivation that
// lets the app assign a stable coverArtKey at import time (first paint never blocks
// on hydrating covers). Precedence: coverArtSources > coverArtUrl > placeholder(id).
// We assert the key MATCHES what the async cache paths derive, and that it is stable.
import { describe, it, expect } from 'vitest';
import { artKeyFor, artKeyForUrl, placeholderKey } from './artCache';
import type { ArtSource } from '../types/model';

describe('artKeyFor', () => {
  it('derives from coverArtSources when present, as type:url joined by "|"', () => {
    const sources: ArtSource[] = [
      { type: 'cdn', url: '/art/abc.webp' },
      { type: 'remote', url: 'https://example.com/x.jpg' },
    ];
    const expected = artKeyForUrl('cdn:/art/abc.webp|remote:https://example.com/x.jpg');
    expect(artKeyFor({ id: 'alb_1', coverArtSources: sources })).toBe(expected);
  });

  it('prefers coverArtSources over coverArtUrl when both exist', () => {
    const sources: ArtSource[] = [{ type: 'cdn', url: '/art/a.webp' }];
    const fromSources = artKeyFor({
      id: 'alb_1',
      coverArtSources: sources,
      coverArtUrl: 'https://other/cover.jpg',
    });
    expect(fromSources).toBe(artKeyForUrl('cdn:/art/a.webp'));
    expect(fromSources).not.toBe(artKeyForUrl('https://other/cover.jpg'));
  });

  it('falls back to coverArtUrl when there are no sources', () => {
    const url = 'https://example.com/cover.jpg';
    expect(artKeyFor({ id: 'alb_1', coverArtUrl: url })).toBe(artKeyForUrl(url));
  });

  it('treats an empty sources array as "no sources" and falls through', () => {
    const url = 'https://example.com/cover.jpg';
    expect(artKeyFor({ id: 'alb_1', coverArtSources: [], coverArtUrl: url })).toBe(
      artKeyForUrl(url),
    );
  });

  it('falls back to a deterministic placeholder keyed by id when there is no art', () => {
    expect(artKeyFor({ id: 'alb_99' })).toBe(placeholderKey('alb_99'));
    // placeholder keys are namespaced separately from URL keys
    expect(artKeyFor({ id: 'alb_99' }).startsWith('ph_')).toBe(true);
    expect(artKeyForUrl('https://x/y.jpg').startsWith('art_')).toBe(true);
  });

  it('is stable: same input → same key across calls', () => {
    const a: ArtSource[] = [
      { type: 'cdn', url: '/art/a.webp' },
      { type: 'remote', url: 'https://r/x.jpg' },
    ];
    expect(artKeyFor({ id: 'alb_1', coverArtSources: a })).toBe(
      artKeyFor({ id: 'alb_1', coverArtSources: [...a] }),
    );
    expect(artKeyFor({ id: 'alb_1', coverArtUrl: 'u' })).toBe(
      artKeyFor({ id: 'alb_1', coverArtUrl: 'u' }),
    );
    expect(artKeyFor({ id: 'same' })).toBe(artKeyFor({ id: 'same' }));
  });

  it('is order-sensitive in sources (re-mirroring → a new durable blob key)', () => {
    const forward: ArtSource[] = [
      { type: 'cdn', url: '/art/a.webp' },
      { type: 'remote', url: 'https://r/x.jpg' },
    ];
    const reversed: ArtSource[] = [forward[1], forward[0]];
    expect(artKeyFor({ id: 'alb_1', coverArtSources: forward })).not.toBe(
      artKeyFor({ id: 'alb_1', coverArtSources: reversed }),
    );
  });

  it('distinguishes the source TYPE, not just the URL', () => {
    expect(artKeyFor({ id: 'x', coverArtSources: [{ type: 'cdn', url: '/a' }] })).not.toBe(
      artKeyFor({ id: 'x', coverArtSources: [{ type: 'remote', url: '/a' }] }),
    );
  });

  it('placeholder keys differ per id but URL keys ignore the id', () => {
    expect(artKeyFor({ id: 'a' })).not.toBe(artKeyFor({ id: 'b' }));
    const url = 'https://x/y.jpg';
    expect(artKeyFor({ id: 'a', coverArtUrl: url })).toBe(
      artKeyFor({ id: 'b', coverArtUrl: url }),
    );
  });
});
