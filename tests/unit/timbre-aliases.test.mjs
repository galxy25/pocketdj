// Timbre id-alias matching — the TIGHT rule. An alias attaches another id's analysis to a song,
// so a wrong alias is a fabricated row: artist AND base-title AND version-marker agreement are
// all required (via am-match's normArtist/comparableTitle — the same normalization the rip
// server trusts before capturing), plus a length sanity guard. Near-misses must NOT alias.
import { describe, it, expect } from 'vitest';
import { computeAliases, aliasKey, lengthsAgree } from '../../scripts/build-timbre-aliases.mjs';

const T = (id, artist, name, length = 200000) => ({ id, artist, name, length });

describe('aliasKey (tight matching semantics)', () => {
  it('cosmetic markers collapse: remaster / feat-tail / explicit agree', () => {
    expect(aliasKey('Blondie', 'Heart of Glass (Remastered)')).toBe(aliasKey('Blondie', 'Heart of Glass'));
    expect(aliasKey('Omarion', 'Post To Be (feat. Chris Brown)')).toBe(aliasKey('Omarion', 'Post To Be'));
  });
  it('version markers are load-bearing: mix / edit / instrumental / live differ', () => {
    expect(aliasKey('Ace of Base', 'Living In Danger (For The Big Clubs Only Mix)'))
      .not.toBe(aliasKey('Ace of Base', 'Living In Danger'));
    expect(aliasKey('Duran Duran', 'Rio (Instrumental)')).not.toBe(aliasKey('Duran Duran', 'Rio'));
    expect(aliasKey('Nirvana', 'All Apologies (Live)')).not.toBe(aliasKey('Nirvana', 'All Apologies'));
    expect(aliasKey('New Order', 'Blue Monday (7" Edit)')).not.toBe(aliasKey('New Order', 'Blue Monday'));
  });
  it('artist must agree', () => {
    expect(aliasKey('Blondie', 'Call Me')).not.toBe(aliasKey('Debbie Harry', 'Call Me'));
  });
  it('empty sides never key', () => {
    expect(aliasKey('', 'Song')).toBeNull();
    expect(aliasKey('Artist', '')).toBeNull();
  });
});

describe('lengthsAgree', () => {
  it('within max(20 s, 10%) agrees; beyond refuses; unknown passes', () => {
    expect(lengthsAgree(200000, 218000)).toBe(true);    // 18 s slop on a 3:38 song — segmentation
    expect(lengthsAgree(200000, 226000)).toBe(false);   // 26 s apart — an unlabeled different cut
    expect(lengthsAgree(400000, 435000)).toBe(true);    // 35 s but under 10% of 7:15
    expect(lengthsAgree(400000, 448000)).toBe(false);   // 48 s over 10% — refuse
    expect(lengthsAgree(null, 220000)).toBe(true);
  });
});

describe('computeAliases', () => {
  const targets = [
    T('sng_vinyl', 'Blondie', 'Heart of Glass', 226000),
    T('sng_vinyl2', 'Blondie', 'Heart of Glass (Remastered)', 227000),
    T('sng_mix', 'Blondie', 'Heart of Glass (Disco Mix)', 350000),
  ];

  it('aliases the same recording (cosmetic-only difference), deterministically to closest length', () => {
    const { aliases } = computeAliases(targets, [T('sng_am', 'Blondie', 'Heart Of Glass', 226500)]);
    expect(aliases.sng_am.to).toBe('sng_vinyl');            // 500 ms closer than sng_vinyl2
    expect(aliases.sng_am.alternatives).toEqual(['sng_vinyl2']);
  });

  it('near-miss: version marker on one side only NEVER aliases', () => {
    const { aliases } = computeAliases(
      [T('sng_mix2', 'Blondie', 'Heart of Glass (Disco Mix)', 350000)],
      [T('sng_am', 'Blondie', 'Heart of Glass', 226000)],
    );
    expect(aliases.sng_am).toBeUndefined();
  });

  it('near-miss: same title, wildly different length refuses (unlabeled different cut)', () => {
    const { aliases } = computeAliases(
      [T('sng_long', 'Blondie', 'Heart of Glass', 500000)],
      [T('sng_am', 'Blondie', 'Heart of Glass', 226000)],
    );
    expect(aliases.sng_am).toBeUndefined();
  });

  it('lane-1 aliases are validated, not trusted: a loose lane-1 pair is rejected loudly', () => {
    const sources = [T('sng_am', 'Blondie', 'Heart of Glass', 226000)];
    const { aliases, rejected } = computeAliases(targets, sources, { sng_am: 'sng_mix' });
    expect(aliases.sng_am.to).toBe('sng_vinyl');            // computed tight match wins instead
    expect(rejected).toContainEqual({ from: 'sng_am', to: 'sng_mix', reason: 'lane1-tight-match-failed' });
  });

  it('lane-1 aliases that pass the tight rule are kept as-is', () => {
    const sources = [T('sng_am', 'Blondie', 'Heart of Glass', 227500)];
    const { aliases, rejected } = computeAliases(targets, sources, { sng_am: 'sng_vinyl2' });
    expect(aliases.sng_am.to).toBe('sng_vinyl2');           // valid, even if not the closest-length pick
    expect(rejected).toHaveLength(0);
  });
});
