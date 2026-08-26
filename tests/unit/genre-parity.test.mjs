// GENRE TABLE PARITY — scripts/build-rec-features.mjs vs apple/PocketDJ/Support/Genre.swift.
//
// The two files carry the same table in two languages and both say "KEEP IN SYNC" in a comment.
// A comment is not a check. This test reads the Swift SOURCE and compares it, entry by entry and
// keyword by keyword, against the JS table — because the failure mode is silent: the Lambda scores
// against `row.g` written by the JS builder, the device scores against `Genre.category` on the
// Swift table, and a keyword present in only one of them makes the same song sit in two different
// genres depending on which engine answered.
//
// It also pins the DROP contract: `reduce()` omits row.g for 'other', so every label the table
// fails to recognise costs the song its entire genre signal. That is what made 10,516 catalog
// songs (9.6%) genre-less and hollowed out the "Twinkle Toes" crate profile.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { genreCategory, reduce } from '../../scripts/build-rec-features.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SWIFT = join(ROOT, 'apple', 'PocketDJ', 'Support', 'Genre.swift');
const JS = join(ROOT, 'scripts', 'build-rec-features.mjs');

/** Parse `("name", [..keywords..], [..broad..])` tuples out of Genre.swift's `categories`. */
function parseSwiftTable() {
  const src = readFileSync(SWIFT, 'utf8');
  const start = src.indexOf('static let categories:');
  expect(start).toBeGreaterThan(-1);
  const body = src.slice(src.indexOf('[', start), src.indexOf('\n    ]', start));
  // Strip // comments so a commented-out keyword can never be read as a live one.
  const clean = body.replace(/\/\/[^\n]*/g, '');
  const out = [];
  const re = /\(\s*"([^"]+)"\s*,\s*\[([\s\S]*?)\]\s*,\s*\[([\s\S]*?)\]\s*\)/g;
  for (let m; (m = re.exec(clean)); ) {
    const words = (s) => [...s.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((x) => x[1].replace(/\\(.)/g, '$1'));
    out.push([m[1], words(m[2]), words(m[3])]);
  }
  return out;
}

/** Parse `['name', [..], [..]?]` tuples out of build-rec-features.mjs's GENRE_CATEGORIES. */
function parseJsTable() {
  const src = readFileSync(JS, 'utf8');
  const start = src.indexOf('const GENRE_CATEGORIES = [');
  expect(start).toBeGreaterThan(-1);
  const body = src.slice(start, src.indexOf('\n];', start));
  const clean = body.replace(/\/\/[^\n]*/g, '');
  const out = [];
  const re = /\[\s*'([^']+)'\s*,\s*\[([\s\S]*?)\]\s*(?:,\s*\[([\s\S]*?)\]\s*)?\]/g;
  for (let m; (m = re.exec(clean)); ) {
    const words = (s) => (s ? [...s.matchAll(/(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")/g)]
      .map((x) => (x[1] ?? x[2]).replace(/\\(.)/g, '$1')) : []);
    out.push([m[1], words(m[2]), words(m[3])]);
  }
  return out;
}

describe('genre table parity (JS ⇄ Swift)', () => {
  const swift = parseSwiftTable();
  const js = parseJsTable();

  it('both tables actually parsed (a parser that finds nothing is a null verifier)', () => {
    expect(js.length).toBeGreaterThanOrEqual(15);
    expect(swift.length).toBe(js.length);
    expect(js.reduce((n, e) => n + e[1].length, 0)).toBeGreaterThan(150);
  });

  it('category names match, IN ORDER — the matcher is first-hit-wins, so order is semantics', () => {
    expect(swift.map((e) => e[0])).toEqual(js.map((e) => e[0]));
  });

  it('every category carries the same pass-1 keywords in the same order', () => {
    for (let i = 0; i < js.length; i++) {
      expect(swift[i][1], `pass-1 keywords for "${js[i][0]}"`).toEqual(js[i][1]);
    }
  });

  it('every category carries the same pass-2 broad tags in the same order', () => {
    for (let i = 0; i < js.length; i++) {
      expect(swift[i][2], `broad tags for "${js[i][0]}"`).toEqual(js[i][2]);
    }
  });

  it('both matchers run two passes — pass 2 must not have been folded back into pass 1', () => {
    expect(readFileSync(SWIFT, 'utf8')).toMatch(/for cat in categories where cat\.broad\.contains/);
    expect(readFileSync(JS, 'utf8')).toMatch(/broad\?\.some/);
  });
});

describe('genreCategory', () => {
  it('a seasonal tag outranks the parent genre glued to it', () => {
    for (const g of ['Holiday', 'Christmas', 'Christmas: R&B', 'Christmas: Pop', 'Xmas'])
      expect(genreCategory(g)).toBe('holiday');
  });

  it('a broad parent tag loses to any specific genre in the same string', () => {
    expect(genreCategory('Alternative')).toBe('rock');
    expect(genreCategory('Alternative Folk')).toBe('folk');       // NOT rock
    expect(genreCategory('Indie, Pop, Alternative')).toBe('pop'); // NOT rock
    expect(genreCategory('Alternative Rap')).toBe('hip-hop');
    expect(genreCategory('Vocal Jazz')).toBe('jazz');             // NOT pop
    expect(genreCategory('Vocal')).toBe('pop');
  });

  it('recovers the labels that were being silently dropped', () => {
    expect(genreCategory('Singer/Songwriter')).toBe('folk');
    expect(genreCategory('Soundtrack')).toBe('classical');
    expect(genreCategory('Original Score')).toBe('classical');
    expect(genreCategory('Música tropical')).toBe('world');
    expect(genreCategory('African')).toBe('world');
    expect(genreCategory('New Age')).toBe('electronic');
    expect(genreCategory('Christian')).toBe('soul');
  });

  it('a label that is not a genre stays "other" — recovering signal, not inventing it', () => {
    for (const g of ['Instrumental', 'Hörspiele', 'Unknown Genre', 'Other', null, '', '   '])
      expect(genreCategory(g)).toBe('other');
  });
});

describe('the drop contract this table feeds', () => {
  const index = {
    albums: [{ id: 'alb_h', genre: 'Holiday' }, { id: 'alb_i', genre: 'Instrumental' }],
    songs: [{ id: 'sng_1', albumId: 'alb_h', name: 'Sleigh' },
            { id: 'sng_2', albumId: 'alb_i', name: 'Untitled' }],
  };

  it('an unrecognised label costs the song its ENTIRE genre field, not just its label', () => {
    const [holiday, instrumental] = reduce(index);
    expect(holiday.g).toBe('holiday');
    expect('g' in instrumental).toBe(false);   // this is the silent cost the table has to avoid
  });
});
