// Vitest port (+ extension) of the indexer's golden parser assertions.
// Original hand-rolled script lives at
// .claude/skills/analog-indexer/lib/parser.test.mjs (run via npm run
// indexer:parser-test); this recreates those fixtures with vitest's expect and
// adds edge cases. Imports the ESM .js lib directly.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
  parseLine,
  isVinylLine,
  splitCamel,
  guessSplit,
  parseFile,
} from '../../.claude/skills/analog-indexer/lib/parser.js';

const here = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(
  here,
  '..',
  '..',
  '.claude',
  'skills',
  'analog-indexer',
  'fixtures',
  'sample-lines.txt',
);

describe('splitCamel', () => {
  it('separates an acronym from a following word', () => {
    expect(splitCamel('ABBAGreatestHits')).toBe('ABBA Greatest Hits');
  });

  it('splits a long CamelCase phrase into words', () => {
    expect(splitCamel('TheBrothersJohnsonLightUpTheNight')).toBe(
      'The Brothers Johnson Light Up The Night',
    );
  });

  it('splits adjacent proper names', () => {
    expect(splitCamel('EvelynChampagneKingSmoothTalk')).toBe(
      'Evelyn Champagne King Smooth Talk',
    );
  });

  it('handles an apostrophe followed by a single-letter pronoun', () => {
    expect(splitCamel("BobbyWomackIDon'tKnowWhatTheWorldIsComingTo")).toBe(
      "Bobby Womack I Don't Know What The World Is Coming To",
    );
  });

  it('only breaks the trailing lowercase before the final acronym letter', () => {
    // documents the ([A-Z]+)([A-Z][a-z]) rule: ABBRA + Rose
    expect(splitCamel('ABBRARose')).toBe('ABBRA Rose');
  });

  it('inserts a boundary between a letter and a trailing number', () => {
    expect(splitCamel('VanHalen1984')).toBe('Van Halen 1984');
    expect(splitCamel('Yes90125')).toBe('Yes 90125');
  });

  it('surrounds an ampersand with spaces', () => {
    expect(splitCamel('Hope&Charity')).toBe('Hope & Charity');
    expect(splitCamel('FaithHope&Charity')).toBe('Faith Hope & Charity');
  });

  it('collapses redundant whitespace', () => {
    expect(splitCamel('A   B  C')).toBe('A B C');
  });

  it('handles a single token', () => {
    expect(splitCamel('Aaliyah')).toBe('Aaliyah');
  });
});

describe('isVinylLine', () => {
  it('returns true when the line contains the literal "Raw"', () => {
    expect(isVinylLine('ABBAGreatestHitsRaw.mp3')).toBe(true);
  });

  it('returns false for lines without "Raw"', () => {
    expect(isVinylLine('IceIceBaby.aiff')).toBe(false);
    expect(isVinylLine('SangoNorth.aiff')).toBe(false);
    expect(isVinylLine('RasAKassGhettoFabulous.mp3')).toBe(false);
  });

  it('returns false for header/comment lines (start with #)', () => {
    expect(isVinylLine('# Vinyl')).toBe(false);
    expect(isVinylLine('#RawAnything')).toBe(false);
  });

  it('returns false for empty / whitespace-only lines', () => {
    expect(isVinylLine('')).toBe(false);
    expect(isVinylLine('   ')).toBe(false);
  });

  it('trims surrounding whitespace before testing', () => {
    expect(isVinylLine('   ABBAGreatestHitsRaw.mp3   ')).toBe(true);
  });
});

describe('parseLine', () => {
  it('returns null for a non-vinyl line', () => {
    expect(parseLine('IceIceBaby.aiff')).toBeNull();
  });

  it('strips the Raw marker + extension and produces a spaced blob', () => {
    const c = parseLine('ABBAGreatestHitsRaw.mp3');
    expect(c.spacedBlob).toBe('ABBA Greatest Hits');
    expect(c.fileType).toBe('mp3');
    expect(c.dupIndex).toBeNull();
    expect(c.isVinyl).toBe(true);
    expect(c.originalFilename).toBe('ABBAGreatestHitsRaw.mp3');
  });

  it('parses a "Raw 2" dedup suffix (space before digit)', () => {
    const c = parseLine('TheBrothersJohnsonLightUpTheNightRaw 2.mp3');
    expect(c.dupIndex).toBe(2);
    expect(c.spacedBlob).toBe('The Brothers Johnson Light Up The Night');
  });

  it('parses a "Raw2" dedup suffix (no space)', () => {
    const c = parseLine('EvelynChampagneKingSmoothTalkRaw2.mp3');
    expect(c.dupIndex).toBe(2);
    expect(c.spacedBlob).toBe('Evelyn Champagne King Smooth Talk');
  });

  it('keeps the ampersand and parses the dup index together', () => {
    const c = parseLine('FaithHope&CharityRaw 2.mp3');
    expect(c.spacedBlob).toBe('Faith Hope & Charity');
    expect(c.dupIndex).toBe(2);
  });

  it('strips the "Raws" typo variant of the marker', () => {
    const c = parseLine('VariousArtistsDanceOfTheBlessedSpiritsRaws.mp3');
    expect(c.spacedBlob).toBe('Various Artists Dance Of The Blessed Spirits');
    expect(c.dupIndex).toBeNull();
  });

  it('recognizes the aiff extension', () => {
    const c = parseLine('AaliyahOneInAMillionRaw.aiff');
    expect(c.fileType).toBe('aiff');
    expect(c.spacedBlob).toBe('Aaliyah One In A Million');
  });

  it('records "unknown" fileType when there is no recognized extension', () => {
    const c = parseLine('ConFunkShun7Raw');
    expect(c.fileType).toBe('unknown');
    expect(c.spacedBlob).toBe('Con Funk Shun 7');
  });

  it('passes through the fileLocation argument', () => {
    const c = parseLine('ABBAGreatestHitsRaw.mp3', '/crate/A');
    expect(c.fileLocation).toBe('/crate/A');
  });

  it('never leaks "Raw" into the lookup blob', () => {
    for (const line of [
      'ABBAGreatestHitsRaw.mp3',
      'ConFunkShun7Raw.mp3',
      'VariousArtistsDanceOfTheBlessedSpiritsRaws.mp3',
    ]) {
      const c = parseLine(line);
      expect(/raw/i.test(c.spacedBlob)).toBe(false);
    }
  });

  it('normalizes the extension casing in fileType', () => {
    const c = parseLine('ABBAGreatestHitsRaw.MP3');
    expect(c.fileType).toBe('mp3');
  });
});

describe('guessSplit', () => {
  it('returns empty fields for an empty token list', () => {
    expect(guessSplit([])).toEqual({ artistGuess: '', albumGuess: '', altSplits: [] });
  });

  it('treats a single token as the artist', () => {
    expect(guessSplit(['Aaliyah'])).toEqual({
      artistGuess: 'Aaliyah',
      albumGuess: '',
      altSplits: [],
    });
  });

  it('binds a leading "The" to the artist side (up to 3 tokens)', () => {
    const { artistGuess } = guessSplit(
      'The Brothers Johnson Light Up The Night'.split(' '),
    );
    expect(artistGuess).toBe('The Brothers Johnson');
  });

  it('splits at an album anchor phrase like "greatest hits"', () => {
    const { artistGuess, albumGuess } = guessSplit('ABBA Greatest Hits'.split(' '));
    expect(artistGuess).toBe('ABBA');
    expect(albumGuess).toBe('Greatest Hits');
  });

  it('falls back to a single artist token when no anchor matches', () => {
    const { artistGuess, albumGuess } = guessSplit('Aaliyah One In A Million'.split(' '));
    expect(artistGuess).toBe('Aaliyah');
    expect(albumGuess).toBe('One In A Million');
  });

  it('produces at most 3 ranked alternate splits', () => {
    const { altSplits } = guessSplit('Evelyn Champagne King Smooth Talk'.split(' '));
    expect(altSplits.length).toBeLessThanOrEqual(3);
    for (const s of altSplits) {
      expect(s).toHaveProperty('artist');
      expect(s).toHaveProperty('album');
    }
  });
});

describe('parseFile', () => {
  it('separates vinyl candidates from skipped lines on the fixture', () => {
    const text = readFileSync(FIXTURE, 'utf8');
    const { candidates, skipped } = parseFile(text);
    expect(candidates.length).toBe(10);
    expect(skipped.length).toBe(3);
  });

  it('accepts an array of lines as well as a string', () => {
    const lines = ['# header', 'ABBAGreatestHitsRaw.mp3', 'NoMarkerHere.mp3'];
    const { candidates, skipped } = parseFile(lines);
    expect(candidates.map((c) => c.spacedBlob)).toEqual(['ABBA Greatest Hits']);
    expect(skipped).toEqual(['NoMarkerHere.mp3']);
  });

  it('does not include comment lines among skipped', () => {
    const { skipped } = parseFile(['# a comment', '# another']);
    expect(skipped).toEqual([]);
  });
});
