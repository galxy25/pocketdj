import { describe, it, expect } from 'vitest';
import {
  categorize,
  subgenresOf,
  CATEGORY_NAMES,
  CATEGORIES,
  PRIORITY_ORDER,
  SUBGENRES_BY_CATEGORY,
  OTHER_CATEGORY,
  OTHER_SUBGENRE,
} from './constellationMap';

describe('categorize — empty / null -> Other/Unknown', () => {
  it('null and undefined map to Other/Unknown', () => {
    expect(categorize(null)).toEqual({ category: 'Other', subgenre: 'Unknown' });
    expect(categorize(undefined)).toEqual({ category: 'Other', subgenre: 'Unknown' });
  });

  it('empty and whitespace-only strings map to Other/Unknown', () => {
    expect(categorize('')).toEqual({ category: 'Other', subgenre: 'Unknown' });
    expect(categorize('    ')).toEqual({ category: 'Other', subgenre: 'Unknown' });
  });

  it('an unmappable genre falls through to Other/Unknown', () => {
    expect(categorize('zzz-not-a-genre')).toEqual({ category: 'Other', subgenre: 'Unknown' });
  });
});

describe('categorize — case / whitespace insensitive', () => {
  it('lowercases and trims before matching', () => {
    expect(categorize('  ROCK  ').category).toBe('rock');
    expect(categorize('Hip hop').category).toBe('hip-hop');
    expect(categorize('JAZZ').category).toBe('jazz');
  });
});

describe('categorize — Discogs compound strings (substring, NOT split on , or /)', () => {
  it('"Funk / Soul, Disco" -> disco (disco out-prioritizes funk/soul; funk keyword picks Boogie sub)', () => {
    expect(categorize('Funk / Soul, Disco')).toEqual({
      category: 'disco',
      subgenre: 'Boogie / Post-Disco',
    });
  });

  it('"Funk / Soul" (no disco token) -> funk/Classic Funk', () => {
    expect(categorize('Funk / Soul')).toEqual({ category: 'funk', subgenre: 'Classic Funk' });
  });

  it('"Electronic, House" -> electronic/House-Techno', () => {
    expect(categorize('Electronic, House')).toEqual({
      category: 'electronic',
      subgenre: 'House / Techno',
    });
  });

  it('"Classical, Opera" -> classical/Baroque-Romantic (opera routes the subgenre)', () => {
    expect(categorize('Classical, Opera')).toEqual({
      category: 'classical',
      subgenre: 'Baroque / Romantic',
    });
  });
});

describe('categorize — messy / glued run-ons still match (substring search)', () => {
  it('"R&Bsoul" -> soul (soul has higher priority than r&b)', () => {
    expect(categorize('R&Bsoul')).toEqual({ category: 'soul', subgenre: 'Classic Soul' });
  });

  it('"Hip hoptrap" -> hip-hop/Gangsta-Trap (trap keyword routes the subgenre)', () => {
    expect(categorize('Hip hoptrap')).toEqual({ category: 'hip-hop', subgenre: 'Gangsta / Trap' });
  });
});

describe('categorize — tier-1 PRIORITY tie-break (specific leaf beats broad parent)', () => {
  it('hip-hop wins over jazz when both present', () => {
    expect(categorize('jazz, hip hop').category).toBe('hip-hop');
  });

  it('"folk rock" -> rock (rock precedes folk in PRIORITY_ORDER, and "rock" matches first)', () => {
    expect(categorize('folk rock').category).toBe('rock');
  });

  it('"west coast" routes to hip-hop (not interpreted elsewhere)', () => {
    expect(categorize('west coast')).toEqual({ category: 'hip-hop', subgenre: 'Gangsta / Trap' });
  });
});

describe('categorize — subgenre selection within a category', () => {
  it('bare category token -> the catch-all (last) subgenre', () => {
    expect(categorize('disco').subgenre).toBe('Classic Disco');
    expect(categorize('rock').subgenre).toBe('Classic / Pop Rock');
    expect(categorize('hip hop').subgenre).toBe('Rap / Pop Rap');
    expect(categorize('jazz').subgenre).toBe('Classic Jazz');
    expect(categorize('country').subgenre).toBe('Americana / Folk Country');
  });

  it('a leaf keyword selects the matching subgenre', () => {
    expect(categorize('boogie')).toEqual({ category: 'disco', subgenre: 'Boogie / Post-Disco' });
    expect(categorize('gangsta')).toEqual({ category: 'hip-hop', subgenre: 'Gangsta / Trap' });
    expect(categorize('boom bap')).toEqual({ category: 'hip-hop', subgenre: 'Boom Bap / Conscious' });
    expect(categorize('salsa')).toEqual({ category: 'world', subgenre: 'Latin' });
    expect(categorize('reggae')).toEqual({ category: 'world', subgenre: 'Reggae / Caribbean' });
    expect(categorize('opera')).toEqual({ category: 'classical', subgenre: 'Baroque / Romantic' });
  });
});

describe('categorize — strips Wikipedia CSS blob leaks', () => {
  it('a CSS-only string maps to Other (the blob is stripped, nothing left)', () => {
    expect(categorize('.mw-parser-output{color:red}')).toEqual({
      category: 'Other',
      subgenre: 'Unknown',
    });
  });

  it('a CSS blob followed by a real genre still matches the genre', () => {
    expect(categorize('.mw-parser-output{color:red} jazz').category).toBe('jazz');
  });
});

describe('categorize — deterministic', () => {
  it('repeated calls return identical results', () => {
    for (const g of ['Funk / Soul, Disco', 'rock', '', 'jazz, hip hop', null]) {
      expect(categorize(g)).toEqual(categorize(g));
    }
  });

  it('every CATEGORIES entry resolves to its own category for a bare token', () => {
    for (const cat of CATEGORIES) {
      // the category name is itself a match keyword in every spec
      const res = categorize(cat.name);
      expect(res.category).toBe(cat.name);
      // the resolved subgenre is one of that category's declared subgenres
      expect(cat.subgenres.map((s) => s.name)).toContain(res.subgenre);
    }
  });
});

describe('exports / metadata', () => {
  it('CATEGORY_NAMES = PRIORITY_ORDER with Other appended last', () => {
    expect(CATEGORY_NAMES).toEqual([...PRIORITY_ORDER, OTHER_CATEGORY]);
    expect(CATEGORY_NAMES[CATEGORY_NAMES.length - 1]).toBe('Other');
  });

  it('PRIORITY_ORDER mirrors CATEGORIES order exactly', () => {
    expect(PRIORITY_ORDER).toEqual(CATEGORIES.map((c) => c.name));
  });

  it('subgenresOf returns the ordered subgenre names', () => {
    expect(subgenresOf('disco')).toEqual(['Boogie / Post-Disco', 'Hi-NRG / Eurodance', 'Classic Disco']);
  });

  it('subgenresOf(Other) returns just the Unknown bucket', () => {
    expect(subgenresOf(OTHER_CATEGORY)).toEqual([OTHER_SUBGENRE]);
  });

  it('subgenresOf(unknown category) returns []', () => {
    expect(subgenresOf('not-a-category')).toEqual([]);
  });

  it('SUBGENRES_BY_CATEGORY covers every category plus Other', () => {
    for (const c of CATEGORIES) {
      expect(SUBGENRES_BY_CATEGORY[c.name]).toEqual(c.subgenres.map((s) => s.name));
    }
    expect(SUBGENRES_BY_CATEGORY[OTHER_CATEGORY]).toEqual([OTHER_SUBGENRE]);
  });

  it('each category ends with a catch-all (empty-keyword) subgenre', () => {
    for (const c of CATEGORIES) {
      const last = c.subgenres[c.subgenres.length - 1];
      expect(last.matchKeywords).toEqual([]);
    }
  });
});
