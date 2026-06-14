// Pure string-normalization helpers shared by the parser and the iTunes matcher.
// Applied symmetrically to BOTH the filename blob and candidate metadata before
// comparison, so apostrophes / "&" / "The" / diacritics never cause false misses.
// No I/O, no deps — safe to import from Node CLIs and unit tests.

/** Lowercase, strip diacritics, unify &/and, drop punctuation, drop leading "the", collapse ws. */
export function normalize(s) {
  if (!s) return '';
  return String(s)
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '') // strip combining diacritics
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/['’`]/g, '') // apostrophes vanish (filenames drop them)
    .replace(/[^a-z0-9]+/g, ' ') // any other punctuation -> space
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^the\s+/, '');
}

/** Normalized word tokens (deduped order-preserving not required by callers). */
export function tokens(s) {
  const n = normalize(s);
  return n ? n.split(' ') : [];
}

/** Set of normalized tokens. */
export function tokenSet(s) {
  return new Set(tokens(s));
}

/** Sørensen–Dice coefficient over two token sets (0..1). */
export function diceTokens(a, b) {
  const A = a instanceof Set ? a : tokenSet(a);
  const B = b instanceof Set ? b : tokenSet(b);
  if (A.size === 0 && B.size === 0) return 1;
  if (A.size === 0 || B.size === 0) return 0;
  let inter = 0;
  for (const t of A) if (B.has(t)) inter++;
  return (2 * inter) / (A.size + B.size);
}

/** Fraction of A's tokens that appear in B (coverage of A by B). */
export function coverage(a, b) {
  const A = a instanceof Set ? a : tokenSet(a);
  const B = b instanceof Set ? b : tokenSet(b);
  if (A.size === 0) return 0;
  let inter = 0;
  for (const t of A) if (B.has(t)) inter++;
  return inter / A.size;
}
