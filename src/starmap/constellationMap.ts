// Rule-based genre -> (category, subgenre) mapper for the two-tier star map.
//
// Genre data is MESSY and ~55% EMPTY: Discogs-style compound CSV strings
// ("Funk / Soul, Disco"), sloppy lowercase ("Hip hop"), glued/malformed
// run-ons ("R&Bsoul", "Hip hoptrap"), plus the occasional Wikipedia-CSS leak.
// So this is a PURE, ORDERED, SUBSTRING/keyword matcher (NOT a fixed lookup):
// it picks ONE primary category (tier 1) + ONE sub-genre (tier 2), and it
// generalizes to genre strings the metadata fallback recovers later.
//
// No deps, no React/DOM, fully deterministic. Owned by the ARCHITECT; the
// layout + renderer build agents import from here but never edit it.

/** Catch-all tier-1 category for empty / unmappable genres. */
export const OTHER_CATEGORY = 'Other';
/** Sub-genre used for everything inside the Other bucket. */
export const OTHER_SUBGENRE = 'Unknown';

export interface SubgenreSpec {
  /** Display name (tier-2 constellation label). */
  name: string;
  /**
   * Lowercase substrings; first matching subgenre (in array order) wins.
   * The LAST subgenre in a category is the catch-all default (empty keywords).
   */
  matchKeywords: string[];
}

export interface CategorySpec {
  /** Tier-1 category name (also the constellation key/label). */
  name: string;
  /** 1-3 subgenres, in priority order; last = catch-all default. */
  subgenres: SubgenreSpec[];
  /** Lowercase substrings that route a genre string into this category. */
  matchKeywords: string[];
}

/**
 * Category definitions WITH per-subgenre keyword routing.
 *
 * IMPORTANT — priority: the array order here is the tier-1 tie-break order
 * (see PRIORITY_ORDER, which mirrors it). Discogs emits broad PARENT tags
 * ("Funk / Soul", "Pop") on a huge fraction of strings, so those low-signal
 * categories (funk/soul/r&b/rock/pop) are placed LATE; specific leaf genres
 * (hip-hop, classical, blues, country, world, jazz, disco) are EARLY so the
 * real descriptor wins over the parent tag.
 */
export const CATEGORIES: CategorySpec[] = [
  {
    name: 'hip-hop',
    subgenres: [
      {
        name: 'Boom Bap / Conscious',
        matchKeywords: [
          'boom bap',
          'conscious',
          'jazzy hip',
          'jazz rap',
          'underground hip',
          'alternative hip',
          'golden age',
          'old-school hip',
          'instrumental hip',
        ],
      },
      {
        name: 'Gangsta / Trap',
        matchKeywords: ['gangsta', 'g-funk', 'trap', 'crunk', 'thug rap', 'southern hip', 'west coast'],
      },
      { name: 'Rap / Pop Rap', matchKeywords: [] },
    ],
    matchKeywords: [
      'hip hop',
      'hip-hop',
      'hiphop',
      'rap',
      'boom bap',
      'gangsta',
      'g-funk',
      'crunk',
      'trap',
      'conscious',
      'jazzy hip',
      'jazz rap',
      'plunderphonics',
      'dj battle',
      'cut-up/dj',
      'ragga hiphop',
      'thug rap',
      'dance rap',
      'political rap',
      'old-school hip',
      'new-school hip',
      'golden age',
      'underground hip',
      'alternative hip',
      'instrumental hip',
      'east coast',
      'west coast',
      'southern hip',
    ],
  },
  {
    name: 'classical',
    subgenres: [
      {
        name: 'Baroque / Romantic',
        matchKeywords: ['baroque', 'romantic', 'wagnerian', 'opera', 'chamber'],
      },
      {
        name: 'Orchestral / Film',
        matchKeywords: ['orchestral', 'symphonic', 'film music'],
      },
      { name: 'Classical', matchKeywords: [] },
    ],
    matchKeywords: [
      'classical',
      'baroque',
      'romantic',
      'symphonic',
      'orchestral',
      'chamber',
      'opera',
      'film music',
      'wagnerian',
    ],
  },
  {
    name: 'blues',
    subgenres: [
      {
        name: 'Electric / Chicago Blues',
        matchKeywords: ['electric', 'chicago', 'texas', 'delta', 'rhythm & blues'],
      },
      {
        name: 'Soul / Piano Blues',
        matchKeywords: ['soul', 'piano', 'jump'],
      },
      { name: 'Classic Blues', matchKeywords: [] },
    ],
    matchKeywords: ['blues'],
  },
  {
    name: 'country',
    subgenres: [
      {
        name: 'Outlaw / Traditional Country',
        matchKeywords: ['outlaw', 'honky', 'bakersfield', 'western', 'nashville'],
      },
      {
        name: 'Country Pop / Rock',
        matchKeywords: ['pop', 'rock', 'countrypolitan'],
      },
      { name: 'Americana / Folk Country', matchKeywords: [] },
    ],
    matchKeywords: [
      'country',
      'americana',
      'bluegrass',
      'outlaw',
      'nashville',
      'bakersfield',
      'countrypolitan',
      'western',
      'ranchera',
      'mariachi',
      'norteño',
      'norteno',
      'honky',
    ],
  },
  {
    name: 'world',
    subgenres: [
      {
        name: 'Latin',
        matchKeywords: [
          'latin',
          'salsa',
          'merengue',
          'cumbia',
          'charanga',
          'bolero',
          'samba',
          'guajira',
          'marimba',
          'andean',
          'bossa',
          'ranchera',
          'mariachi',
          'norteño',
          'norteno',
        ],
      },
      {
        name: 'Reggae / Caribbean',
        matchKeywords: ['reggae', 'dancehall', 'ragga', 'ska'],
      },
      { name: 'Global / Traditional', matchKeywords: [] },
    ],
    matchKeywords: [
      'latin',
      'salsa',
      'merengue',
      'cumbia',
      'charanga',
      'bolero',
      'samba',
      'guajira',
      'marimba',
      'andean',
      'bossa',
      'reggae',
      'dancehall',
      'ragga',
      'ska',
      'afro',
      'polka',
      'hawaiian',
      'indian classical',
      'hindustani',
      'world',
    ],
  },
  {
    name: 'jazz',
    subgenres: [
      {
        name: 'Smooth / Cool Jazz',
        matchKeywords: ['smooth jazz', 'cool jazz', 'vocal jazz', 'bossa nova'],
      },
      {
        name: 'Jazz Fusion',
        matchKeywords: ['fusion', 'jazz-funk', 'jazz funk', 'acid jazz', 'crossover jazz'],
      },
      { name: 'Classic Jazz', matchKeywords: [] },
    ],
    matchKeywords: [
      'jazz',
      'bossa nova',
      'big band',
      'bebop',
      'cool jazz',
      'smooth jazz',
      'post-bop',
      'vocal jazz',
      'fusion',
      'crossover jazz',
      'acid jazz',
      'soul-jazz',
    ],
  },
  {
    name: 'disco',
    subgenres: [
      {
        name: 'Boogie / Post-Disco',
        matchKeywords: ['boogie', 'post-disco', 'nu-disco', 'funk'],
      },
      {
        name: 'Hi-NRG / Eurodance',
        matchKeywords: ['hi nrg', 'hi-nrg', 'hinrg', 'freestyle', 'eurodance'],
      },
      { name: 'Classic Disco', matchKeywords: [] },
    ],
    matchKeywords: [
      'disco',
      'boogie',
      'hi nrg',
      'hi-nrg',
      'hinrg',
      'post-disco',
      'nu-disco',
      'eurodance',
      'freestyle',
      'go-go',
    ],
  },
  {
    name: 'funk',
    subgenres: [
      {
        name: 'Jazz-Funk / Acid Jazz',
        matchKeywords: ['jazz-funk', 'jazz funk', 'acid jazz', 'quiet storm'],
      },
      {
        name: 'P-Funk / Minneapolis',
        matchKeywords: ['minneapolis', 'p-funk', 'synth-funk', 'avant-funk'],
      },
      { name: 'Classic Funk', matchKeywords: [] },
    ],
    matchKeywords: [
      'funk',
      'minneapolis',
      'p-funk',
      'avant-funk',
      'jazz-funk',
      'jazz funk',
      'acid jazz',
      'synth-funk',
      'quiet storm',
      'go-go',
    ],
  },
  {
    name: 'soul',
    subgenres: [
      {
        name: 'Neo Soul / Contemporary',
        matchKeywords: ['neo soul', 'neo-soul', 'contemporary', 'quiet storm'],
      },
      {
        name: 'Philly / Psychedelic Soul',
        matchKeywords: ['philly', 'philadelphia', 'psychedelic', 'motown'],
      },
      { name: 'Classic Soul', matchKeywords: [] },
    ],
    matchKeywords: [
      'soul',
      'motown',
      'philly soul',
      'philadelphia soul',
      'gospel',
      'doo wop',
      'doo-wop',
      'quiet storm',
    ],
  },
  {
    name: 'r&b',
    subgenres: [
      {
        name: 'Contemporary R&B',
        matchKeywords: ['contemporary r&b', 'hip-hop soul', 'hip hop soul', 'urban'],
      },
      {
        name: 'New Jack Swing',
        matchKeywords: ['new jack', 'minneapolis sound'],
      },
      { name: 'Classic R&B', matchKeywords: [] },
    ],
    matchKeywords: [
      'r&b',
      'rnb',
      'rhythm & blues',
      'rhythm and blues',
      'new jack',
      'contemporary r&b',
      'hip-hop soul',
      'hip hop soul',
      'urban',
      'minneapolis sound',
    ],
  },
  {
    name: 'electronic',
    subgenres: [
      {
        name: 'House / Techno',
        matchKeywords: [
          'house',
          'techno',
          'trance',
          'edm',
          'tribal house',
          'deep house',
          'progressive house',
          'witch house',
        ],
      },
      {
        name: 'Synth-pop / New Wave',
        matchKeywords: [
          'synth-pop',
          'synthpop',
          'synth pop',
          'electropop',
          'new wave',
          'darkwave',
        ],
      },
      { name: 'Downtempo / Electro', matchKeywords: [] },
    ],
    matchKeywords: [
      'electronic',
      'electronica',
      'house',
      'techno',
      'trance',
      'edm',
      'synth-pop',
      'synthpop',
      'synth pop',
      'electropop',
      'electro',
      'downtempo',
      'trip hop',
      'leftfield',
      'new wave',
      'breaks',
      'tribal house',
      'deep house',
      'progressive house',
      'witch house',
      'darkwave',
      'indietronica',
      'bass music',
      'dub',
      'hi nrg',
    ],
  },
  {
    name: 'rock',
    subgenres: [
      {
        name: 'Hard Rock / Metal',
        matchKeywords: ['metal', 'hard rock', 'thrash', 'grunge', 'punk'],
      },
      {
        name: 'Indie / Alternative Rock',
        matchKeywords: ['indie', 'alternative', 'shoegaze', 'garage', 'psychedelic'],
      },
      { name: 'Classic / Pop Rock', matchKeywords: [] },
    ],
    matchKeywords: [
      'rock',
      'metal',
      'punk',
      'grunge',
      'psychedelic',
      'garage',
      'shoegaze',
      'indie rock',
      'glam',
      'arena',
      'heartland',
      'thrash',
    ],
  },
  {
    name: 'folk',
    subgenres: [
      {
        name: 'Indie / Folk Rock',
        matchKeywords: ['indie folk', 'folk rock', 'singer-songwriter'],
      },
      {
        name: 'Folk Pop',
        matchKeywords: ['folk-pop', 'folk pop', 'sunshine pop'],
      },
      { name: 'Traditional Folk', matchKeywords: [] },
    ],
    matchKeywords: [
      'folk',
      'singer-songwriter',
      'indie folk',
      'folk rock',
      'folk-pop',
      'folk jazz',
      'sunshine pop',
      'spoken word',
      'poetry',
    ],
  },
  {
    name: 'pop',
    subgenres: [
      {
        name: 'Dance-Pop',
        matchKeywords: ['dance-pop', 'dance pop', 'dance-rock', 'europop', 'dance'],
      },
      {
        name: 'Synth / Electropop',
        matchKeywords: ['synth', 'electropop', 'new pop'],
      },
      { name: 'Classic Pop', matchKeywords: [] },
    ],
    matchKeywords: [
      'pop',
      'dance-pop',
      'dance pop',
      'dance-rock',
      'art pop',
      'baroque pop',
      'chamber pop',
      'sophisti-pop',
      'europop',
      'new pop',
      'traditional pop',
      'novelty',
      'comedy',
      'adult contemporary',
      'dance',
    ],
  },
];

/**
 * Tier-1 tie-break order for multi-category strings (first hit wins). Mirrors
 * CATEGORIES order; specific leaf genres first, broad parent tags last.
 */
export const PRIORITY_ORDER: string[] = [
  'hip-hop',
  'classical',
  'blues',
  'country',
  'world',
  'jazz',
  'disco',
  'funk',
  'soul',
  'r&b',
  'electronic',
  'rock',
  'folk',
  'pop',
];

/** Categories indexed in PRIORITY_ORDER (the order Step 2 iterates). */
const PRIORITY_CATEGORIES: CategorySpec[] = PRIORITY_ORDER.map((name) => {
  const spec = CATEGORIES.find((c) => c.name === name);
  if (!spec) throw new Error('constellationMap: priorityOrder names unknown category ' + name);
  return spec;
});

/** Quick lookup by category name. */
const CATEGORY_BY_NAME = new Map<string, CategorySpec>(CATEGORIES.map((c) => [c.name, c]));

/**
 * Tier-1 category names in display/priority order, with the Other bucket
 * APPENDED last (so no album disappears while ~55% are still ungenred).
 */
export const CATEGORY_NAMES: string[] = [...PRIORITY_ORDER, OTHER_CATEGORY];

/** All subgenre display names for a category, in priority order (default last). */
export function subgenresOf(category: string): string[] {
  if (category === OTHER_CATEGORY) return [OTHER_SUBGENRE];
  const spec = CATEGORY_BY_NAME.get(category);
  return spec ? spec.subgenres.map((s) => s.name) : [];
}

/** category -> ordered subgenre display names (incl. the Other bucket). */
export const SUBGENRES_BY_CATEGORY: Record<string, string[]> = (() => {
  const out: Record<string, string[]> = {};
  for (const c of CATEGORIES) out[c.name] = c.subgenres.map((s) => s.name);
  out[OTHER_CATEGORY] = [OTHER_SUBGENRE];
  return out;
})();

/** Strip Wikipedia CSS-blob leaks, e.g. ".mw-parser-output ... }". */
const CSS_BLOB = /\.mw-parser-output[^}]*\}/g;

export interface CategorizeResult {
  category: string;
  subgenre: string;
}

/**
 * Map a raw genre string onto { category, subgenre }.
 *
 * Algorithm (see the locked design):
 *  0. null/undefined/empty (after CSS-strip) -> { Other, Unknown }.
 *  1. normalize: lowercase + trim + strip CSS blobs. Do NOT split on commas / "/".
 *  2. pick category: iterate PRIORITY_ORDER; first category whose ANY keyword is
 *     a substring of the normalized string wins.
 *  3. pick subgenre: within the winning category, first subgenre whose ANY
 *     keyword is a substring wins; else the category's default (last) subgenre.
 *  4. fallthrough (no category matched) -> { Other, Unknown }.
 */
export function categorize(genre: string | undefined | null): CategorizeResult {
  // Step 0 + 1: normalize.
  if (genre == null) return { category: OTHER_CATEGORY, subgenre: OTHER_SUBGENRE };
  let s = genre.toLowerCase().trim();
  if (s.length === 0) return { category: OTHER_CATEGORY, subgenre: OTHER_SUBGENRE };
  s = s.replace(CSS_BLOB, ' ').trim();
  if (s.length === 0) return { category: OTHER_CATEGORY, subgenre: OTHER_SUBGENRE };

  // Step 2: pick category (ordered, first hit wins).
  let winning: CategorySpec | undefined;
  for (const cat of PRIORITY_CATEGORIES) {
    if (cat.matchKeywords.some((kw) => s.includes(kw))) {
      winning = cat;
      break;
    }
  }

  // Step 4: fallthrough.
  if (!winning) return { category: OTHER_CATEGORY, subgenre: OTHER_SUBGENRE };

  // Step 3: pick subgenre within the winning category.
  const subs = winning.subgenres;
  for (let i = 0; i < subs.length; i++) {
    const sub = subs[i];
    // The last subgenre is the catch-all default (empty keyword set).
    if (sub.matchKeywords.length === 0) return { category: winning.name, subgenre: sub.name };
    if (sub.matchKeywords.some((kw) => s.includes(kw))) {
      return { category: winning.name, subgenre: sub.name };
    }
  }
  // Defensive: every category ends with an empty-keyword default, so we never
  // reach here, but fall back to the last subgenre if it ever happens.
  const last = subs[subs.length - 1];
  return { category: winning.name, subgenre: last ? last.name : OTHER_SUBGENRE };
}
