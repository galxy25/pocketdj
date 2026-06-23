// am-match — Apple Music library matcher shared by the rip skill and the rip server.
//
// Extracted verbatim from .claude/skills/rip/rip.mjs (which runs main() on import and so
// cannot be imported as-is). Loads an exported iTunes/Music library plist (or TSV
// fallback), normalizes artist/title, and resolves an arbitrary artist/title to a library
// entry (Persistent ID + match class). The rip server uses findInLibrary() at accept time
// to decide whether an ANALOG song can be cloud-captured from Apple Music (exact match)
// before falling back to the analog vinyl path.
//
// MATCHING PHILOSOPHY — PREFER TIGHT MATCHING (deliberate product choice):
// 'exact' requires the RECORDING to be the same, not just the song. A version/recording
// parenthetical — mix, remix, edit, radio/LP/album/single version, 7"/12", instrumental,
// live, acoustic, dub, extended, club, a cappella, reprise, demo, sped up/slowed, rework,
// vip, bootleg — MUST AGREE (see comparableTitle). Cosmetic markers (remaster, deluxe,
// anniversary, bonus, mono/stereo, explicit/clean, feat./credits) are ignored.
// WHY: PocketDJ is the user's OWN collection — the specific club mix / 7" edit / single
// they own is an intentional, personal choice; that exact cut is the music to bring into
// the pocket to build lists from. Collapsing it onto the catalog's standard recording
// loses what makes it theirs AND corrupts its length/bpm/key. On any version-marker
// disagreement we DON'T treat it as a match — we fall back to the personal (analog)
// source. Lower match coverage is the accepted price of fidelity.
import { readFileSync } from 'node:fs';

// ---------------- normalization / matching ----------------
export const stripD = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '');
export function normTitle(s) {
  let t = stripD(String(s || '').toLowerCase());
  t = t.replace(/[\(\[].*?[\)\]]/g, ' ').replace(/\b(feat|featuring|ft)\b.*$/g, ' ').replace(/&/g, ' and ');
  return t.replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
}

// ---- comparable title (recording-altering vs cosmetic version markers) ----
//
// normTitle strips ALL parentheticals, so a recording variant (a remix/live/edit/
// instrumental/etc.) collapses onto the standard recording and exact-matches it. That
// is wrong for both the re-index (overwrites the length with the wrong recording) and a
// cloud rip (captures the wrong recording). comparableTitle keeps any paren/bracket
// group whose content denotes a DIFFERENT RECORDING and drops only COSMETIC groups
// (remaster/deluxe/explicit/credits/…) so that:
//   - "Living In Danger (For The Big Clubs Only Mix)"  !=  "Living In Danger"
//   - "Steelo (LP Version)"                            !=  "Steelo"
//   - "Fernando"                                       ==  "Fernando (Remastered)"
//   - "Post To Be (feat. Chris Brown & Jhene Aiko)"    ==  "Post To Be (feat. …)"
//   - "X (Club Mix)"                                   ==  "X (Club Mix)"

// Words that, if they appear in a paren/bracket group, mark it as a DIFFERENT recording.
// A group containing ANY of these (or any non-cosmetic content) is KEPT as comparable.
const RECORDING_ALTERING = [
  'mix', 'remix', 'edit', 'radio', 'instrumental', 'live', 'acoustic', 'unplugged',
  'version', 'inch', 'dub', 'extended', 'club', 'acappella', 'acapella', 'reprise',
  'interlude', 'skit', 'demo', 'sped', 'slowed', 'reverb', 'karaoke', 'cover',
  'rework', 'vip', 'bootleg', 'session', 'take',
];
const RECORDING_RE = new RegExp('\\b(' + RECORDING_ALTERING.join('|') + ')\\b');

// Credit markers (feat./featuring/ft/with) — these are credits, not recordings, so a
// group that is purely a credit is COSMETIC.
const CREDIT_RE = /\b(feat|featuring|ft|with)\b/;

// Cosmetic-only words — a group whose content reduces to nothing but these (after
// removing credit phrasing) is dropped. "original mix" is treated as the standard
// recording (cosmetic/no-op) per the spec.
const COSMETIC_WORDS = new Set([
  'remaster', 'remastered', 'remasters', 'deluxe', 'expanded', 'anniversary',
  'edition', 'bonus', 'track', 'mono', 'stereo', 'explicit', 'clean', 'original',
  'and', 'the', 'a', 'an', 'of', 'feat', 'featuring', 'ft', 'with',
]);

// Normalize a chunk of free text (no paren delimiters) to comparable word tokens.
const normChunk = (s) =>
  stripD(String(s || '').toLowerCase())
    .replace(/&/g, ' and ')
    // collapse inch markers (7", 12", 7-inch) to the token "inch" before stripping punct
    .replace(/\b(7|12)\s*("|''|inch)\b/g, ' inch ')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .replace(/\s+/g, ' ');

// Decide whether a single paren/bracket group's inner text is COSMETIC (droppable).
// Cosmetic iff: it is a pure credit (feat/with …), OR every remaining token is a
// cosmetic word — AND it contains no recording-altering marker. "original mix" ->
// contains 'mix' (recording-altering) but is the standard recording, so special-cased
// to cosmetic.
function isCosmeticGroup(inner) {
  const norm = normChunk(inner);
  if (!norm) return true; // empty group -> nothing
  // "original mix" (and "original version") == the standard recording -> cosmetic no-op
  if (/^original (mix|version|recording)$/.test(norm)) return true;
  // pure credit group: starts with a credit marker -> cosmetic
  if (CREDIT_RE.test(norm)) {
    const withoutCredit = norm.replace(/\b(feat|featuring|ft|with)\b.*$/, '').trim();
    // if nothing meaningful precedes the credit, it's a pure credit group
    if (!withoutCredit) return true;
    // text precedes the credit (e.g. "remix feat X") — judge that text below
    if (RECORDING_RE.test(withoutCredit)) return false;
    return withoutCredit.split(' ').every((w) => COSMETIC_WORDS.has(w));
  }
  if (RECORDING_RE.test(norm)) return false; // recording-altering -> keep
  // no recording marker, no credit: cosmetic iff every token is a cosmetic word
  return norm.split(' ').every((w) => COSMETIC_WORDS.has(w));
}

export function comparableTitle(s) {
  let raw = String(s || '');
  // Drop only COSMETIC paren/bracket groups; KEEP recording-altering groups as
  // comparable text (their inner words, normalized). Non-paren credit tails
  // (… feat. X) are cosmetic and dropped.
  // Replace each group with either '' (cosmetic) or ' <normalized-inner> '.
  let kept = raw.replace(/[\(\[]([^\)\]]*)[\)\]]/g, (_m, inner) =>
    isCosmeticGroup(inner) ? ' ' : ' ' + normChunk(inner) + ' ',
  );
  // strip a trailing un-parenthesized credit tail ("Song feat. X") — cosmetic
  kept = kept.replace(/\b(feat|featuring|ft)\b.*$/i, ' ');
  return normChunk(kept);
}
export function normArtist(s) {
  let t = stripD(String(s || '').toLowerCase());
  t = t.replace(/[\(\[].*?[\)\]]/g, ' ').replace(/\b(feat|featuring|ft)\b.*$/g, ' ').replace(/&/g, ' and ');
  t = t.replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
  return t.replace(/^the\s+/, '');
}
const toks = (s) => new Set(s.split(' ').filter(Boolean));
export function subsetEither(a, b) {
  const A = toks(a), B = toks(b); if (!A.size || !B.size) return false;
  const small = A.size <= B.size ? A : B, big = A.size <= B.size ? B : A;
  for (const x of small) if (!big.has(x)) return false; return true;
}

// ---------------- library load (XML preferred, TSV fallback) ----------------
export const unesc = (s) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
export function loadLibraryXML(file) {
  const text = readFileSync(file, 'utf8');
  const entries = [];
  let cur = null;
  for (const line of text.split('\n')) {
    if (line.includes('<dict>')) { cur = {}; continue; }
    if (line.includes('</dict>') && cur) { if (cur.persistentID || cur.title) entries.push(cur); cur = null; continue; }
    if (!cur) continue;
    const m = line.match(/<key>([^<]+)<\/key><(?:string|integer)>([^<]*)<\/(?:string|integer)>/);
    if (!m) continue;
    const k = m[1], v = unesc(m[2]);
    if (k === 'Name') cur.title = v;
    else if (k === 'Artist') cur.artist = v;
    else if (k === 'Album') cur.album = v;
    else if (k === 'Persistent ID') cur.persistentID = v;
    else if (k === 'Total Time') cur.lengthMs = parseInt(v, 10); // ms duration — same unit as song.length
  }
  return entries;
}
export function loadLibraryTSV(file) {
  return readFileSync(file, 'utf8').trim().split('\n').slice(1).map(ln => {
    const [persistentID, artist, title, album] = ln.split('\t');
    return { persistentID, artist, title, album };
  }).filter(e => e.title);
}
export function indexLibrary(entries) {
  // exact: keyed by normArtist + comparableTitle (version-aware) — only this overwrites
  //        / cloud-captures. byTitle: keyed by the looser normTitle (all parens stripped)
  //        for diagnostics ('loose').
  const exact = new Map(), byTitle = new Map();
  for (const e of entries) {
    e.na = normArtist(e.artist); e.nt = normTitle(e.title); e.ct = comparableTitle(e.title);
    const k = e.na + '\x00' + e.ct;
    if (!exact.has(k)) exact.set(k, e);
    if (!byTitle.has(e.nt)) byTitle.set(e.nt, []);
    byTitle.get(e.nt).push(e);
  }
  return { exact, byTitle, count: entries.length };
}
export function findInLibrary(lib, artist, title) {
  const na = normArtist(artist), nt = normTitle(title), ct = comparableTitle(title);
  // exact: artist agrees AND titles agree on recording-altering version markers
  // (cosmetic markers ignored). Only 'exact' is used to overwrite / cloud-capture.
  const ex = lib.exact.get(na + '\x00' + ct);
  if (ex) return { hit: ex, match: 'exact' };
  // loose: paren-stripped subset (diagnostics only — NEVER overwrites / captures).
  const loose = (lib.byTitle.get(nt) || []).find(e => subsetEither(e.na, na));
  return loose ? { hit: loose, match: 'loose' } : { hit: null, match: 'none' };
}
