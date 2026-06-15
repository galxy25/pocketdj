// Tiered regex classifier for song explicitness. Resolves the clear-cut majority
// of songs with zero LLM cost; routes only the AMBIGUOUS middle to the local model.
//
//   classifyByRegex(lyrics) -> { verdict: 'explicit'|'clean'|'uncertain', categories, signals }
//
// Design: STRONG patterns are high-PRECISION (a hit ⇒ explicit, no LLM). Context-
// sensitive words (dick/cock/ass — also names/animals), censored masks (f**k),
// and leetspeak go to the AMBIGUOUS tier (⇒ LLM adjudicates). Everything else is
// confidently clean. All patterns use word boundaries to dodge the Scunthorpe
// problem (e.g. "assassin", "Scunthorpe", "cocktail", "pussycat", "shiitake").

// --- STRONG: a match means EXPLICIT (high precision, no LLM) ------------------
// Each entry: [regex, category]. `\b<root>[a-z]*` allows suffixes (fuck→fucking)
// while the leading \b prevents mid-word substring hits.
const STRONG = [
  // profanity
  [/\bfuck[a-z]*/i, 'profanity'],
  [/\bmotherfuck[a-z]*/i, 'profanity'],
  [/\bshit[a-z]*/i, 'profanity'],
  [/\b(?:bull|dip|horse|jack|bat)shit[a-z]*/i, 'profanity'],
  [/\bbitch[a-z]*/i, 'profanity'],
  [/\bcunt[a-z]*/i, 'profanity'],
  [/\basshole[a-z]*/i, 'profanity'],
  [/\bdickhead[a-z]*/i, 'profanity'],
  // sexual
  [/\bpuss(?:y|ies)\b/i, 'sexual'],
  [/\bcocksuck[a-z]*/i, 'sexual'],
  [/\bcum(?:ming|shot|shots|s)?\b/i, 'sexual'],
  [/\bjizz[a-z]*/i, 'sexual'],
  [/\bblow ?job[a-z]*/i, 'sexual'],
  [/\bhand ?job[a-z]*/i, 'sexual'],
  [/\bdeep ?throat[a-z]*/i, 'sexual'],
  [/\bgang ?bang[a-z]*/i, 'sexual'],
  [/\bcream ?pie[a-z]*/i, 'sexual'],
  [/\bdildo[a-z]*/i, 'sexual'],
  [/\bwhore[a-z]*/i, 'sexual'],
  [/\bslut[a-z]*/i, 'sexual'],
  [/\bclit[a-z]*/i, 'sexual'],
  // slurs (racial / homophobic / ableist — whole-word where the root has clean homonyms)
  [/\bnigg(?:a|er)[a-z]*\b/i, 'slurs'],
  [/\bfaggot[a-z]*/i, 'slurs'],
  [/\bspics?\b/i, 'slurs'],
  [/\bchinks?\b/i, 'slurs'],
  [/\bkikes?\b/i, 'slurs'],
  [/\bwetback[a-z]*/i, 'slurs'],
  [/\btrann(?:y|ies)\b/i, 'slurs'],
  [/\bretard[a-z]*/i, 'slurs'],
]

// --- AMBIGUOUS: a match (with no STRONG hit) means UNCERTAIN ⇒ LLM ------------
// Context-sensitive profanity (names/animals/idioms), drug refs (rubric needs
// "glorified" context), and obfuscations the model should adjudicate.
const AMBIGUOUS = [
  // context-sensitive words
  /\bdicks?\b/i, /\bcocks?\b/i, /\bass(?:es)?\b/i, /\bdumbass[a-z]*/i, /\bjackass[a-z]*/i,
  /\bpiss[a-z]*/i, /\bbastard[a-z]*/i, /\bpricks?\b/i, /\bfag\b/i, /\bdykes?\b/i,
  /\bcoons?\b/i, /\bhorny\b/i, /\bhoes?\b/i, /\bthots?\b/i, /\bgoddamn[a-z]*/i,
  /\btits?\b/i, /\bboobs?\b/i, /\bporn[a-z]*/i, /\borgasm[a-z]*/i, /\berection[a-z]*/i,
  // hard-drug references (context-dependent glorification)
  /\bcocaine\b/i, /\bheroin\b/i, /\bcrack\b/i, /\bmeth\b/i, /\bmolly\b/i, /\bblunt[a-z]*/i,
  // censored / masked spellings
  /\bf[\*\@\#\.\-_]+k[a-z]*/i, /\bs[\*\@\#\.\-_]+t\b/i, /\bb[\*\@\#\.\-_]+ch[a-z]*/i,
  /\bc[\*\@\#\.\-_]+t\b/i, /\bn[\*\@\#\.\-_]+(?:a|er|ga)[a-z]*/i, /\ba[\*\@\#]{2,}\b/i,
  /\bmf'?[a-z]*\b/i, /\bwtf\b/i, /\bstfu\b/i, /\bgtfo\b/i,
  /\b[fns][\-\s]?word\b/i, /\bf[\-\s]?bomb\b/i,
  // leetspeak
  /\bsh1t[a-z0-9]*/i, /\bf[u4]ck[a-z0-9]*/i, /\bb1tch[a-z0-9]*/i, /\ba\$\$[a-z0-9]*/i, /\bsh!t\b/i,
]

/**
 * Classify lyrics with the regex tiers.
 * @param {string} lyrics
 * @returns {{verdict:'explicit'|'clean'|'uncertain', categories:string[], signals:string[]}}
 */
export function classifyByRegex(lyrics) {
  const text = String(lyrics || '');
  if (!text.trim()) return { verdict: 'clean', categories: [], signals: [] };

  const cats = new Set();
  const hits = [];
  for (const [re, cat] of STRONG) {
    const m = text.match(re);
    if (m) { cats.add(cat); hits.push(m[0].toLowerCase()); }
  }
  if (cats.size) return { verdict: 'explicit', categories: [...cats], signals: [...new Set(hits)].slice(0, 8) };

  const signals = [];
  for (const re of AMBIGUOUS) {
    const m = text.match(re);
    if (m) signals.push(m[0].toLowerCase());
  }
  if (signals.length) return { verdict: 'uncertain', categories: [], signals: [...new Set(signals)].slice(0, 8) };

  return { verdict: 'clean', categories: [], signals: [] };
}

export const _tiers = { STRONG, AMBIGUOUS };
