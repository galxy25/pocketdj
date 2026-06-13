// Deterministic filename parser for the analog vinyl source.
//
// Naming convention (confirmed by the user): every vinyl recording is named
//   ArtistNameAlbumNameRaw.<ext>            (CamelCase, ext = mp3/aiff/m4a)
// and a duplicate pressing/recording may add a dedup digit: "...Raw2" / "...Raw 2".
//
// The parser is deliberately SHALLOW: it strips the "Raw" marker + extension,
// re-introduces word boundaries in the CamelCase blob, and emits a best-guess
// artist/album split PLUS the whole spaced blob. The real disambiguation happens
// downstream against iTunes / web search — so we never over-commit to one split.
//
// No I/O, no deps. Imported by the CLI (cli.mjs) and the unit test.

const EXT_RE = /\.(mp3|aiff|m4a|flac|wav|aac)$/i;
// "Raw" marker at the end of the stem, optional trailing 's' (typo "Raws"),
// optional space, optional dedup digit. Case-insensitive on the suffix only.
const RAW_SUFFIX_RE = /Raw[s]?\s?(\d+)?$/i;

// Phrases that strongly indicate the start of the ALBUM portion (compilations,
// live records, volumes) — used only to bias the heuristic split.
const ALBUM_ANCHORS = [
  'greatest hits', 'best of', 'the best of', 'anthology', 'collection',
  'live', 'volume', 'vol', 'singles', 'his greatest', 'all the',
];

/** True if the line is a vinyl recording (contains the literal "Raw"). */
export function isVinylLine(line) {
  const t = line.trim();
  if (!t || t.startsWith('#')) return false;
  return t.includes('Raw');
}

/** Insert spaces into a mashed CamelCase blob. ABBAGreatestHits -> "ABBA Greatest Hits". */
export function splitCamel(blob) {
  return blob
    // ACRONYM -> Word boundary: "ABBA" + "Greatest"
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    // lower/digit -> Upper boundary: "Smooth" + "Talk", "Womack" + "I"
    .replace(/([a-z\d])([A-Z])/g, '$1 $2')
    // letter -> trailing number boundary: "Halen1984" -> "Halen 1984", "Yes90125" -> "Yes 90125"
    .replace(/([a-z])(\d)/g, '$1 $2')
    // space around ampersand: "Hope&Charity" -> "Hope & Charity"
    .replace(/\s*&\s*/g, ' & ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Parse a single line into an enrichment candidate.
 * Returns null for non-vinyl lines.
 */
export function parseLine(line, fileLocation = '') {
  const raw = line.trim();
  if (!isVinylLine(raw)) return null;

  const originalFilename = raw;
  const extMatch = raw.match(EXT_RE);
  const fileType = extMatch ? extMatch[1].toLowerCase() : 'unknown';

  // stem = filename without extension
  let stem = extMatch ? raw.slice(0, extMatch.index) : raw;

  // strip the Raw marker (+ optional dedup digit) from the end of the stem
  let dupIndex = null;
  const rawMatch = stem.match(RAW_SUFFIX_RE);
  if (rawMatch) {
    dupIndex = rawMatch[1] ? parseInt(rawMatch[1], 10) : null;
    stem = stem.slice(0, rawMatch.index);
  }
  stem = stem.trim();

  const spacedBlob = splitCamel(stem);
  const toks = spacedBlob.split(' ').filter(Boolean);

  const { artistGuess, albumGuess, altSplits } = guessSplit(toks);

  return {
    originalFilename,
    fileLocation,
    fileType,
    dupIndex, // null = single recording; 2,3… = duplicate pressing
    stem,
    spacedBlob, // PRIMARY lookup term (no "Raw")
    artistGuess,
    albumGuess,
    altSplits, // ranked fallback splits if whole-blob search fails
    isVinyl: true,
  };
}

/**
 * Heuristic artist/album split. We DON'T trust this much — the whole `spacedBlob`
 * is the primary lookup term. This just gives ranked fallbacks.
 */
export function guessSplit(toks) {
  if (toks.length === 0) return { artistGuess: '', albumGuess: '', altSplits: [] };
  if (toks.length === 1) return { artistGuess: toks[0], albumGuess: '', altSplits: [] };

  const lower = toks.map((t) => t.toLowerCase());

  // 1) Anchor-based split: find where an album-anchor phrase begins.
  let anchorAt = -1;
  for (let i = 1; i < toks.length && anchorAt === -1; i++) {
    for (const anchor of ALBUM_ANCHORS) {
      const aw = anchor.split(' ');
      if (aw.every((w, k) => lower[i + k] === w)) {
        anchorAt = i;
        break;
      }
    }
  }

  // 2) "The …" binds to the artist side (The Brothers Johnson, The O'Jays).
  let defaultArtistLen = 1;
  if (lower[0] === 'the') defaultArtistLen = Math.min(3, toks.length - 1);

  const splitAt = anchorAt > 0 ? anchorAt : defaultArtistLen;

  const mk = (k) => ({
    artist: toks.slice(0, k).join(' '),
    album: toks.slice(k).join(' '),
  });

  const primary = mk(splitAt);
  // Ranked alternates: a couple of nearby split points (1..3 artist tokens).
  const altSet = new Map();
  for (const k of [splitAt, 1, 2, 3, defaultArtistLen]) {
    if (k > 0 && k < toks.length) {
      const s = mk(k);
      altSet.set(`${k}`, s);
    }
  }
  const altSplits = [...altSet.values()].slice(0, 3);

  return { artistGuess: primary.artist, albumGuess: primary.album, altSplits };
}

/** Parse a whole file body (array of lines or a string). Returns {candidates, skipped}. */
export function parseFile(text, fileLocation = '') {
  const lines = Array.isArray(text) ? text : String(text).split(/\r?\n/);
  const candidates = [];
  const skipped = [];
  for (const line of lines) {
    const t = line.trim();
    if (!t) continue;
    if (isVinylLine(t)) {
      const c = parseLine(t, fileLocation);
      if (c) candidates.push(c);
    } else if (!t.startsWith('#')) {
      skipped.push(t);
    }
  }
  return { candidates, skipped };
}
