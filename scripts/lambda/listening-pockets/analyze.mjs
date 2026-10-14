// LISTENING POCKETS — ANALYSIS. Pure functions: detected pockets + song features + the user's own
// baseline → the results document the app shows (results.v1, see docs/design/listening-pockets.md).
//
// "DEFINING" means CONCENTRATED, not merely present. A pocket of five house songs played by
// someone whose listening is 40% house is not defined by house; the same pocket from someone at
// 5% house is. So every categorical feature is scored as LIFT over the user's baseline share
// (smoothed, so a value the baseline has never seen is rare rather than infinitely rare), and every
// numeric one as DISPERSION against the baseline's spread (118–124 BPM is only "tight" next to a
// library that spans 85–140). Context — time of day, weekday/weekend, surface, place, trip — is
// scored exactly like the music, with a lower lift bar: a context is shared by every member by
// construction, so the question is only whether it is unusual for this user.
//
// Deterministic for identical input + `nowMs`: every Map is filled in the sorted event order and
// every list is sorted with a full tie-break, so a re-run never reshuffles ids, features or titles.

import { createHash } from 'node:crypto';
import { POCKET_PARAMS, ROUND_PARAMS } from './params.mjs';
import { detect } from './detect.mjs';
import { resolveSong } from './features.mjs';
import { buildCollectionModel, pocketMembership, meanVector, topNormalized, collectionCandidates } from './collections.mjs';

const DAY_MS = 24 * 60 * 60 * 1000;
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const round = (x, dp) => { const m = 10 ** dp; return Math.round(x * m) / m; };

// `collection` (multi-valued: the song's hard memberships AS OF the play) and `playContext` (the
// collection the play started from) are pockets-collections.md's dims — empty for a profile that
// never sent a collections snapshot / context ids, so its documents are unchanged by them.
const MUSICAL_DIMS = ['artist', 'genre', 'mood', 'camelot', 'collection'];
const CONTEXT_DIMS = ['timeBucket', 'dayType', 'dow', 'source', 'place', 'trip', 'carPlay', 'playContext'];
const CONTEXT_SET = new Set(CONTEXT_DIMS);
const CATEGORICAL_DIMS = [...MUSICAL_DIMS, ...CONTEXT_DIMS];
const NUMERIC_DIMS = ['bpm', 'energy', 'year'];
/// Display precision per numeric dimension (center / lo / hi; baselineCenter gets one more for bpm).
const NUMERIC_DP = { bpm: 0, energy: 3, year: 0 };

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
/// `PlayHistoryStore.PlaySource.label` on the device — the same words the History timeline uses.
const SOURCE_LABELS = {
  browser: 'Browser', playlist: 'Playlist', pocket: 'Pocket', album: 'Album',
  setlist: 'Set list', mix: 'Mix', artist: 'Artist', game: 'Game',
};
/// Genre categories whose title-casing would be wrong ("R&b", "Edm").
const GENRE_LABELS = { 'r&b': 'R&B', edm: 'EDM', 'hip-hop': 'Hip-Hop', 'k-pop': 'K-Pop', 'j-pop': 'J-Pop' };

const titleCase = (s) => String(s).replace(/(^|[\s/-])(\p{L})/gu, (m, p, c) => p + c.toUpperCase());
const capFirst = (s) => (s ? s[0].toUpperCase() + s.slice(1) : s);

// ── Primitives ──────────────────────────────────────────────────────────────────────────────────

/** Harmonic neighbor set of a Camelot code: itself, ±1 same letter (12↔1 wrap), same number
 *  other letter. Invalid/absent code -> empty set. Ported from rec-engine `camelotNeighbors`. */
export function camelotNeighbors(code) {
  const m = /^(\d{1,2})([AB])$/i.exec(String(code || '').trim());
  if (!m) return new Set();
  const n = parseInt(m[1], 10);
  if (n < 1 || n > 12) return new Set();
  const letter = m[2].toUpperCase();
  const prev = n === 1 ? 12 : n - 1;
  const next = n === 12 ? 1 : n + 1;
  const other = letter === 'A' ? 'B' : 'A';
  return new Set([`${n}${letter}`, `${prev}${letter}`, `${next}${letter}`, `${n}${other}`]);
}

const normCamelot = (c) => {
  const m = /^(\d{1,2})([AB])$/i.exec(String(c || '').trim());
  if (!m) return null;
  const n = parseInt(m[1], 10);
  return n >= 1 && n <= 12 ? `${n}${m[2].toUpperCase()}` : null;
};

/// Fold a tempo into [lo, hi) by doubling/halving — a 60 BPM ballad and a 120 BPM house track
/// share a pulse, and BPM detectors flip octaves freely.
export function foldBpm(b, [lo, hi] = POCKET_PARAMS.numeric.bpmFold) {
  if (!Number.isFinite(b) || b <= 0 || !(hi > lo) || hi > lo * 2 + 1e-9) return null;
  let x = b;
  while (x < lo) x *= 2;
  while (x >= hi) x /= 2;
  return x;
}

/// Which named bucket a LOCAL hour (fractional) falls in; a bucket whose start is after its end
/// wraps midnight.
export function timeBucketOf(hour, buckets = POCKET_PARAMS.timeBuckets) {
  for (const [name, start, end] of buckets) {
    if (start < end ? hour >= start && hour < end : hour >= start || hour < end) return name;
  }
  return buckets[0]?.[0] ?? 'night';
}

/// Local calendar facts for a play: `atMs` shifted by the play's own UTC offset, then read as UTC.
export function localTimeOf(atMs, tzOffsetMin, params = POCKET_PARAMS) {
  const d = new Date(atMs + (tzOffsetMin || 0) * 60_000);
  const hour = d.getUTCHours() + d.getUTCMinutes() / 60;
  const dow = d.getUTCDay();
  return {
    hour, dow, dayType: dow === 0 || dow === 6 ? 'weekend' : 'weekday',
    timeBucket: timeBucketOf(hour, params.timeBuckets), localDate: d.toISOString().slice(0, 10),
  };
}

const median = (xs) => {
  const s = xs.slice().sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
const meanStd = (xs) => {
  const n = xs.length;
  if (!n) return { mean: null, std: null, n: 0 };
  const mean = xs.reduce((a, b) => a + b, 0) / n;
  const v = xs.reduce((a, b) => a + (b - mean) ** 2, 0) / n;
  return { mean, std: Math.sqrt(v), n };
};

// ── Per-play attributes ─────────────────────────────────────────────────────────────────────────

/**
 * One normalized event → the attributes analysis reads. Musical attributes come from the catalog
 * features row (any identity of the song id), with the event's own `artist` snapshot as the
 * fallback for songs the catalog does not know (Apple Music captures, deleted rows).
 */
export function attributesOf(e, features, { params = POCKET_PARAMS, tzFallbackMin = 0, collectionsAt = null } = {}) {
  const row = resolveSong(features?.byId, features?.byAm, e.songId);
  const artistRaw = (typeof row?.a === 'string' && row.a.trim()) || (typeof e.artist === 'string' && e.artist.trim()) || null;
  const tz = Number.isFinite(e.tzOffsetMin) ? e.tzOffsetMin : tzFallbackMin;
  const local = localTimeOf(e.atMs, tz, params);
  const loud = row?.t?.loud; const punch = row?.t?.punch;
  const ctx = e.ctx && typeof e.ctx === 'object' ? e.ctx : null;
  const moods = Array.isArray(row?.s)
    ? [...new Set(row.s.filter((m) => typeof m === 'string' && m.trim()).map((m) => m.trim().toLowerCase()))]
    : [];
  const year = Number.isFinite(row?.y) && row.y >= 1900 && row.y <= 2100 ? row.y : null;
  return {
    eventId: e.id, songId: e.songId, atMs: e.atMs, outcome: e.outcome ?? 'unknown',
    tzOffsetMin: tz, ...local,
    artistKey: artistRaw ? artistRaw.toLowerCase() : null, artistLabel: artistRaw,
    genre: typeof row?.g === 'string' && row.g.trim() ? row.g.trim().toLowerCase() : null,
    moods,
    camelot: normCamelot(row?.c),
    bpm: foldBpm(row?.b, params.numeric.bpmFold),
    energy: Number.isFinite(loud) && Number.isFinite(punch) ? (loud + punch) / 2 : null,
    year,
    source: typeof e.source === 'string' && e.source ? e.source : null,
    carPlay: e.carPlay === true ? 'yes' : e.carPlay === false ? 'no' : null,
    place: ctx?.kind === 'place' && ctx.placeId ? ctx.placeId : null,
    trip: ctx?.kind === 'trip' && ctx.tripId ? ctx.tripId : null,
    ctx: ctx && ((ctx.kind === 'place' && ctx.placeId) || (ctx.kind === 'trip' && ctx.tripId)) ? ctx : null,
    collections: collectionsAt ? collectionsAt(e.songId, e.atMs) : [],
    playContext: typeof e.contextId === 'string' && e.contextId ? e.contextId : null,
  };
}

/// The categorical values one play contributes to a dimension (mood is multi-valued).
function valuesOf(a, dim) {
  switch (dim) {
    case 'artist': return a.artistKey ? [a.artistKey] : [];
    case 'mood': return a.moods;
    case 'collection': return a.collections || [];
    case 'dow': return [String(a.dow)];
    default: return a[dim] != null ? [String(a[dim])] : [];
  }
}

/// The musical facts the collection model compares (memoized per song id): genre, folded BPM,
/// Camelot + its neighbour set, timbre vector, moods — the same normalisation `attributesOf` applies.
export function makeSongInfo(features, params = POCKET_PARAMS) {
  const feats = features instanceof Map ? { byId: features, byAm: new Map() } : features;
  const memo = new Map();
  return (songId) => {
    if (memo.has(songId)) return memo.get(songId);
    const r = resolveSong(feats?.byId, feats?.byAm, songId);
    const camelot = r ? normCamelot(r.c) : null;
    const info = r ? {
      genre: typeof r.g === 'string' && r.g.trim() ? r.g.trim().toLowerCase() : null,
      bpm: foldBpm(r.b, params.numeric.bpmFold), camelot,
      neighbors: camelotNeighbors(camelot), timbre: r.t && typeof r.t === 'object' ? r.t : null,
      moods: Array.isArray(r.s) ? [...new Set(r.s.filter((m) => typeof m === 'string' && m.trim()).map((m) => m.trim().toLowerCase()))] : [],
    } : null;
    memo.set(songId, info);
    return info;
  };
}

/**
 * 0…1: how many of a pattern's MUSICAL defining features a song carries — categorical artist /
 * genre / mood / camelot values, plus every defining numeric range (bpm folded, energy, year).
 * null when the pattern has no musical defining feature at all (the term is then not earnable).
 */
export function featureMatch(a, pattern) {
  let total = 0; let hit = 0;
  for (const f of pattern.features || []) {
    if (!['artist', 'genre', 'mood', 'camelot'].includes(f.dim)) continue;
    total += 1;
    if (valuesOf(a, f.dim).includes(f.value)) hit += 1;
  }
  for (const dim of NUMERIC_DIMS) {
    const n = pattern.numeric?.[dim];
    if (!n?.defining) continue;
    total += 1;
    if (a[dim] != null && a[dim] >= n.lo - (dim === 'bpm' ? 0.5 : 0) && a[dim] <= n.hi + (dim === 'bpm' ? 0.5 : 0)) hit += 1;
  }
  return total ? hit / total : null;
}

// ── Baseline ────────────────────────────────────────────────────────────────────────────────────

/**
 * The user's overall listening: every PLAY (skips excluded — a skip is the opposite of a
 * preference) in the trailing `baselineDays`, across the whole profile. Per categorical dimension
 * a value→count map, per numeric one mean + population std (bpm already folded), plus the Camelot
 * distribution the harmonic baseline is computed from.
 */
export function buildBaseline(playAttrs, params = POCKET_PARAMS) {
  const cat = {};
  for (const dim of CATEGORICAL_DIMS) cat[dim] = new Map();
  const numVals = { bpm: [], energy: [], year: [] };
  for (const a of playAttrs) {
    for (const dim of CATEGORICAL_DIMS) {
      for (const v of valuesOf(a, dim)) cat[dim].set(v, (cat[dim].get(v) || 0) + 1);
    }
    for (const dim of NUMERIC_DIMS) if (a[dim] != null) numVals[dim].push(a[dim]);
  }
  const num = {};
  for (const dim of NUMERIC_DIMS) num[dim] = meanStd(numVals[dim]);
  // P(next key is a harmonic neighbor of this one) if keys were drawn independently from the
  // user's own distribution — the rate a pocket has to beat for "flows harmonically" to mean
  // anything. Σ_c p(c) · Σ_{n ∈ N(c)} p(n).
  const keyTotal = [...cat.camelot.values()].reduce((s, c) => s + c, 0);
  let harmonicRate = 0;
  if (keyTotal) {
    for (const [c, cnt] of cat.camelot) {
      let nb = 0;
      for (const n of camelotNeighbors(c)) nb += (cat.camelot.get(n) || 0) / keyTotal;
      harmonicRate += (cnt / keyTotal) * nb;
    }
  }
  const N = playAttrs.length;
  return { N, cat, num, harmonicRate, thin: N < (params.thinBaselinePlays ?? 50) };
}

// ── Defining features ───────────────────────────────────────────────────────────────────────────

/**
 * What defines a set of member plays against the baseline. Used for pockets (one sequence) and
 * patterns (the union of their pockets' members — `sequences` keeps each pocket's ORDER so the
 * harmonic rate only counts real transitions, never a jump between two different days).
 */
export function analyzeMembers(sequences, baseline, labels, params = POCKET_PARAMS) {
  const members = sequences.flat();
  const n = members.length;
  const cp = params.categorical;
  const features = [];
  for (const dim of CATEGORICAL_DIMS) {
    const counts = new Map();
    for (const a of members) for (const v of valuesOf(a, dim)) counts.set(v, (counts.get(v) || 0) + 1);
    const base = baseline.cat[dim];
    const K = Math.max(1, base.size);
    const isContext = CONTEXT_SET.has(dim);
    for (const [v, count] of counts) {
      const share = count / n;
      const baselineShare = ((base.get(v) || 0) + cp.smoothing) / (baseline.N + cp.smoothing * K);
      const lift = share / baselineShare;
      if (share < cp.minShare) continue;
      if (lift < (isContext ? cp.contextMinLift : cp.minLift)) continue;
      if (!isContext && count < cp.minCount) continue;
      features.push({
        dim, value: v, label: labelFor(dim, v, labels),
        share: round(share, 3), baselineShare: round(baselineShare, 4),
        lift: round(lift, 2), score: round(share * Math.log(lift), 3), count,
      });
    }
  }
  features.sort((a, b) => b.score - a.score || b.share - a.share
    || (a.dim < b.dim ? -1 : a.dim > b.dim ? 1 : 0) || (a.value < b.value ? -1 : a.value > b.value ? 1 : 0));

  const np = params.numeric;
  const numeric = {};
  for (const dim of NUMERIC_DIMS) {
    const vals = members.map((a) => a[dim]).filter((x) => x != null);
    if (!vals.length) continue;
    const { std } = meanStd(vals);
    const base = baseline.num[dim];
    const ratio = base && base.std > 0 ? std / base.std : null;
    const coverage = vals.length / n;
    const dp = NUMERIC_DP[dim];
    numeric[dim] = {
      center: round(median(vals), dp), lo: round(Math.min(...vals), dp), hi: round(Math.max(...vals), dp),
      coverage: round(coverage, 3), dispersionRatio: ratio == null ? null : round(ratio, 3),
      baselineCenter: base?.mean == null ? null : round(base.mean, dim === 'bpm' ? 1 : dp),
      defining: coverage >= np.minCoverage && vals.length >= np.minValues && ratio != null && ratio <= np.maxDispersionRatio,
    };
  }

  const hp = params.harmonic;
  let pairs = 0; let hits = 0;
  for (const seq of sequences) {
    for (let i = 1; i < seq.length; i++) {
      const a = seq[i - 1].camelot; const b = seq[i].camelot;
      if (!a || !b) continue;
      pairs += 1;
      if (camelotNeighbors(a).has(b)) hits += 1;
    }
  }
  const harmonic = pairs ? {
    rate: round(hits / pairs, 3), baselineRate: round(baseline.harmonicRate, 3), pairs,
    defining: pairs >= (hp.minPairs ?? 1) && hits / pairs >= hp.minRate
      && hits / pairs >= hp.minLiftOverBaseline * baseline.harmonicRate,
  } : null;

  return { features: features.slice(0, cp.maxFeatures), numeric, harmonic };
}

function labelFor(dim, v, labels) {
  switch (dim) {
    case 'artist': return labels.artists.get(v) || v;
    case 'genre': return GENRE_LABELS[v] || titleCase(v);
    case 'mood': return titleCase(v);
    case 'camelot': return v;
    case 'timeBucket': return capFirst(v);
    case 'dayType': return capFirst(v);
    case 'dow': return DAY_NAMES[Number(v)] || v;
    case 'source': return SOURCE_LABELS[v] || capFirst(v);
    case 'place': return labels.places.get(v) || 'Place';
    case 'trip': return labels.trips.get(v) || 'Trip';
    case 'carPlay': return v === 'yes' ? 'CarPlay' : 'Not in CarPlay';
    default: return v;
  }
}

/// The member context shared by at least `ctxDominantShare` of the members (members with no
/// context count against it), or null.
export function dominantCtx(members, params = POCKET_PARAMS) {
  const counts = new Map(); const first = new Map();
  for (const a of members) {
    if (!a.ctx) continue;
    const k = a.place ? `place:${a.place}` : `trip:${a.trip}`;
    counts.set(k, (counts.get(k) || 0) + 1);
    if (!first.has(k)) first.set(k, a.ctx);
  }
  let best = null; let bestN = 0;
  for (const [k, c] of counts) if (c > bestN || (c === bestN && k < best)) { best = k; bestN = c; }
  if (!best || bestN / members.length < params.ctxDominantShare) return null;
  const c = first.get(best);
  const out = { kind: c.kind };
  for (const f of ['placeId', 'tripId', 'origin', 'destination']) if (c[f]) out[f] = c[f];
  if (c.kind === 'trip' && !out.destination) out.destination = null;
  return out;
}

const ctxKeyOf = (ctx) => (ctx?.kind === 'trip' && ctx.tripId ? `trip:${ctx.tripId}`
  : ctx?.kind === 'place' && ctx.placeId ? `place:${ctx.placeId}` : '-');

/**
 * "Weekday morning · A → B · 118–124 BPM · House". Parts, in order, each only when it holds:
 * the time phrase (always; plural for a pattern), the context label when that context is itself a
 * DEFINING feature, the BPM range when tempo is defining, then the top defining genre (else the
 * top defining artist). Never empty.
 */
export function titleFor({ dayType, timeBucket, ctx, features = [], numeric = {} }, { plural = false } = {}) {
  const parts = [];
  if (dayType && timeBucket) parts.push(`${capFirst(dayType)} ${timeBucket}${plural ? 's' : ''}`);
  if (ctx) {
    const f = features.find((x) => (ctx.kind === 'trip' && x.dim === 'trip' && x.value === ctx.tripId)
      || (ctx.kind === 'place' && x.dim === 'place' && x.value === ctx.placeId));
    if (f) parts.push(f.label);
  }
  const bpm = numeric.bpm;
  if (bpm?.defining) parts.push(bpm.lo === bpm.hi ? `${bpm.lo} BPM` : `${bpm.lo}–${bpm.hi} BPM`);
  const top = features.find((x) => x.dim === 'genre') || features.find((x) => x.dim === 'artist');
  if (top) parts.push(top.label);
  return parts.length ? parts.join(' · ') : 'Listening pocket';
}

// ── Patterns ────────────────────────────────────────────────────────────────────────────────────

/// The genre that holds at least `genreKeyMinShare` of a pocket's members, else '-'.
function genreKeyOf(members, params) {
  const counts = new Map();
  for (const a of members) if (a.genre) counts.set(a.genre, (counts.get(a.genre) || 0) + 1);
  let best = null; let bestN = 0;
  for (const [g, c] of counts) if (c > bestN || (c === bestN && g < best)) { best = g; bestN = c; }
  return best && bestN / members.length >= params.patterns.genreKeyMinShare ? best : '-';
}

/**
 * Pockets that RECUR across days → named patterns. Pass 1 groups by the full key
 * `dayType|timeBucket|ctx|genre`; whatever is left over is re-grouped by the relaxed key with the
 * context wildcarded (`dayType|timeBucket|*|genre`) — the same habit on days the user travelled a
 * different way, or before location was on. A group is a pattern when it holds `minPockets` pockets
 * on `minDistinctDays` different local dates. Direction is part of the trip id, so A→B mornings and
 * B→A evenings are never one pattern in pass 1.
 *
 * `internal` is the pockets with their member attributes (`_members`) still attached; each one's
 * `patternId` is set in place.
 */
export function clusterPatterns(internal, baseline, labels, params = POCKET_PARAMS) {
  const pp = params.patterns;
  const keyed = internal.map((p) => ({ p, ctxKey: ctxKeyOf(p.ctx), genreKey: genreKeyOf(p._members, params) }));
  const patterns = [];
  const assigned = new Set();
  const pass = (keyFn, withCtx) => {
    const groups = new Map();
    for (const k of keyed) {
      if (assigned.has(k.p.id)) continue;
      const key = keyFn(k);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(k);
    }
    for (const key of [...groups.keys()].sort()) {
      const group = groups.get(key);
      const days = new Set(group.map((k) => k.p.localDate));
      if (group.length < pp.minPockets || days.size < pp.minDistinctDays) continue;
      const pockets = group.map((k) => k.p).sort((a, b) => b.startMs - a.startMs || (a.id < b.id ? -1 : 1));
      const id = `pt_${sha256(key).slice(0, 12)}`;
      for (const p of pockets) { assigned.add(p.id); p.patternId = id; }
      const ctx = withCtx && group[0].ctxKey !== '-' ? group[0].p.ctx : null;
      const analysis = analyzeMembers(pockets.map((p) => p._members), baseline, labels, params);
      const songCounts = new Map();
      for (const p of pockets) for (const m of p._members) songCounts.set(m.songId, (songCounts.get(m.songId) || 0) + 1);
      const topSongs = [...songCounts].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
        .slice(0, pp.maxTopSongs).map(([songId, plays]) => ({ songId, plays }));
      const [dayType, timeBucket] = key.split('|');
      patterns.push({
        id, key,
        title: titleFor({ dayType, timeBucket, ctx, ...analysis }, { plural: true }),
        pocketIds: pockets.map((p) => p.id), occurrences: pockets.length, distinctDays: days.size,
        firstMs: Math.min(...pockets.map((p) => p.startMs)), lastMs: Math.max(...pockets.map((p) => p.startMs)),
        dayType, timeBucket, ctx,
        features: analysis.features, numeric: analysis.numeric, harmonic: analysis.harmonic, topSongs,
      });
    }
  };
  pass((k) => `${k.p.dayType}|${k.p.timeBucket}|${k.ctxKey}|${k.genreKey}`, true);
  pass((k) => `${k.p.dayType}|${k.p.timeBucket}|*|${k.genreKey}`, false);
  patterns.sort((a, b) => b.occurrences - a.occurrences || b.lastMs - a.lastMs || (a.id < b.id ? -1 : 1));
  return patterns;
}

// ── "In the Pocket" rounds → labels ─────────────────────────────────────────────────────────────

/// A round's label: +1 stayed in the pocket, −1 broke early (song ≤ `earlySkipMaxSong`), 0 otherwise
/// (a late break or an abandoned round says little about the prediction).
export function roundLabel(r, rp = ROUND_PARAMS) {
  if (r?.outcome === 'pocket') return 1;
  if (r?.outcome === 'broke' && Number.isInteger(r.brokeAt) && r.brokeAt <= rp.earlySkipMaxSong) return -1;
  return 0;
}

/// The context keys a round credits: always the relaxed `dayType|timeBucket|*`, plus the exact
/// `dayType|timeBucket|place:<id>` / `trip:<id>` when it was played somewhere known. A round with no
/// time context credits nothing (it cannot be matched to a future round's context).
export function roundContextKeys(r) {
  const c = r?.context;
  if (!c?.dayType || !c?.timeBucket) return [];
  const keys = [`${c.dayType}|${c.timeBucket}|*`];
  const ctxKey = ctxKeyOf(c.ctx);
  if (ctxKey !== '-') keys.push(`${c.dayType}|${c.timeBucket}|${ctxKey}`);
  return keys;
}

/// Laplace-smoothed positive rate, doubled so "no evidence" is exactly 1.0, clamped.
export function roundMultiplier(pos, neg, rp = ROUND_PARAMS) {
  const s = rp.smoothing;
  const m = (2 * (pos + s)) / (pos + neg + 2 * s);
  return round(Math.min(rp.maxMultiplier, Math.max(rp.minMultiplier, m)), 3);
}

/**
 * Stored rounds → the `rounds` section of a results document: overall counts, and per context the
 * scorer targets that predicted well (multiplier > 1) or badly (< 1). The app multiplies its own
 * target weights by these when it builds the next round in a matching context (exact key first,
 * then the relaxed one). Pure + deterministic: contexts and weights are sorted with full tie-breaks.
 */
export function learnFromRounds(rounds, { nowMs = Date.now(), params = POCKET_PARAMS, rp = ROUND_PARAMS } = {}) {
  const from = nowMs - params.resultsDays * DAY_MS;
  const list = (Array.isArray(rounds) ? rounds : []).filter((r) => r && Number.isFinite(r.startedAtMs) && r.startedAtMs >= from);
  const counts = { pocket: 0, broke: 0, abandoned: 0 };
  let positives = 0; let negatives = 0;
  const ctxs = new Map();
  for (const r of list) {
    if (r.outcome in counts) counts[r.outcome] += 1;
    const label = roundLabel(r, rp);
    if (label > 0) positives += 1; else if (label < 0) negatives += 1;
    for (const key of roundContextKeys(r)) {
      if (!ctxs.has(key)) {
        const [dayType, timeBucket] = key.split('|');
        ctxs.set(key, { key, dayType, timeBucket, ctx: key.endsWith('|*') ? null : r.context.ctx,
          rounds: 0, positives: 0, negatives: 0, weights: new Map() });
      }
      const g = ctxs.get(key);
      g.rounds += 1;
      if (label > 0) g.positives += 1; else if (label < 0) g.negatives += 1;
      if (label === 0) continue;
      const seen = new Set();
      for (const t of r.targets || []) {
        const wk = `${t.dim}\u0000${t.value}`;
        if (seen.has(wk)) continue;
        seen.add(wk);
        if (!g.weights.has(wk)) g.weights.set(wk, { dim: t.dim, value: t.value, pos: 0, neg: 0 });
        const w = g.weights.get(wk);
        if (label > 0) w.pos += 1; else w.neg += 1;
      }
    }
  }
  const decided = counts.pocket + counts.broke;
  const contexts = [...ctxs.values()].map((g) => ({
    key: g.key, dayType: g.dayType, timeBucket: g.timeBucket, ctx: g.ctx,
    rounds: g.rounds, positives: g.positives, negatives: g.negatives,
    weights: [...g.weights.values()]
      .map((w) => ({ ...w, multiplier: roundMultiplier(w.pos, w.neg, rp) }))
      .sort((a, b) => (b.pos + b.neg) - (a.pos + a.neg) || Math.abs(b.multiplier - 1) - Math.abs(a.multiplier - 1)
        || (a.dim < b.dim ? -1 : a.dim > b.dim ? 1 : 0) || (a.value < b.value ? -1 : a.value > b.value ? 1 : 0))
      .slice(0, rp.maxWeightsPerContext),
  })).sort((a, b) => b.rounds - a.rounds || (a.key < b.key ? -1 : 1)).slice(0, rp.maxContexts);
  return {
    v: 1, params: JSON.parse(JSON.stringify(rp)),
    total: list.length, ...counts, positives, negatives,
    pocketRate: decided ? round(counts.pocket / decided, 3) : null,
    contexts,
  };
}

// ── The whole job ───────────────────────────────────────────────────────────────────────────────

/// The params block a results document echoes (`algo.params`): the full knob set.
const algoOf = (params) => ({ version: params.version, params: JSON.parse(JSON.stringify(params)) });

/// The results shape for a profile with nothing computed yet — what GET answers before the first
/// compute, so the app never has to special-case a missing document.
export function emptyResults({ params = POCKET_PARAMS, stale = false, labels = null } = {}) {
  return {
    v: 1, generatedAtMs: null, stale, algo: algoOf(params),
    baseline: { plays: 0, windowDays: params.baselineDays, thin: true },
    labels: { places: labels?.places || [], trips: labels?.trips || [] },
    pockets: [], patterns: [], collectionsSeen: 0,
  };
}

/// The UTC offset most of the profile's plays carry — the fallback for a row uploaded without one.
function modalTz(rows) {
  const counts = new Map();
  for (const e of rows) if (Number.isFinite(e.tzOffsetMin)) counts.set(e.tzOffsetMin, (counts.get(e.tzOffsetMin) || 0) + 1);
  let best = 0; let bestN = 0;
  for (const [tz, c] of counts) if (c > bestN || (c === bestN && tz < best)) { best = tz; bestN = c; }
  return best;
}

/**
 * Stored events document (`{ events, labels }`) + features index (`{ byId, byAm }` from
 * `indexFeatures`/`loadFeatures`; a bare Map of id → row also works) → the results.v1 document.
 */
export function computeResults(eventsDoc, features, { nowMs = Date.now(), params = POCKET_PARAMS } = {}) {
  const feats = features instanceof Map ? { byId: features, byAm: new Map() } : (features || { byId: new Map(), byAm: new Map() });
  const labelSnap = eventsDoc?.labels || {};
  const placesSnap = Array.isArray(labelSnap.places) ? labelSnap.places : [];
  const tripsSnap = Array.isArray(labelSnap.trips) ? labelSnap.trips : [];
  const { normalized, pockets } = detect(eventsDoc?.events || [], { params });

  const tzFallbackMin = modalTz(normalized);
  // Collections (pockets-collections.md): null for a profile that never sent a snapshot / add history.
  const songInfo = makeSongInfo(feats, params);
  const model = params.collections ? buildCollectionModel(eventsDoc, songInfo, params) : null;
  const collectionsAt = model ? model.collectionsAt : null;
  const attrs = new Map();
  for (const e of normalized) attrs.set(e.id, attributesOf(e, feats, { params, tzFallbackMin, collectionsAt }));

  // Display label per artist key: the spelling seen most often (ties → first in order).
  const artistVotes = new Map();
  for (const a of attrs.values()) {
    if (!a.artistKey) continue;
    if (!artistVotes.has(a.artistKey)) artistVotes.set(a.artistKey, new Map());
    const m = artistVotes.get(a.artistKey);
    m.set(a.artistLabel, (m.get(a.artistLabel) || 0) + 1);
  }
  const labels = {
    artists: new Map([...artistVotes].map(([k, m]) => {
      let best = null; let bestN = 0;
      for (const [l, c] of m) if (c > bestN) { best = l; bestN = c; }
      return [k, best];
    })),
    places: new Map(placesSnap.filter((p) => p?.id && p.label).map((p) => [p.id, p.label])),
    trips: new Map(tripsSnap.filter((t) => t?.id && t.label).map((t) => [t.id, t.label])),
  };

  const baselineFrom = nowMs - params.baselineDays * DAY_MS;
  const baseline = buildBaseline(normalized.filter((e) => e.isPlay && e.atMs >= baselineFrom).map((e) => attrs.get(e.id)), params);

  const resultsFrom = nowMs - params.resultsDays * DAY_MS;
  const internal = [];
  for (const p of pockets) {
    const endMs = p.members[p.members.length - 1].atMs;
    if (endMs < resultsFrom) continue;
    const members = p.members.map((e) => attrs.get(e.id));
    const first = members[0];
    const analysis = analyzeMembers([members], baseline, labels, params);
    const ctx = dominantCtx(members, params);
    internal.push({
      id: p.id, startMs: first.atMs, endMs, tzOffsetMin: first.tzOffsetMin,
      localDate: first.localDate, localStartHour: round(first.hour, 2), dow: first.dow,
      dayType: first.dayType, timeBucket: first.timeBucket, installId: p.stream,
      memberCount: members.length, skippedCount: p.skippedCount, sessionPlays: p.sessionPlays,
      members: members.map((a) => ({ eventId: a.eventId, songId: a.songId, atMs: a.atMs, outcome: a.outcome })),
      ctx,
      features: analysis.features, numeric: analysis.numeric, harmonic: analysis.harmonic,
      title: titleFor({ dayType: first.dayType, timeBucket: first.timeBucket, ctx, ...analysis }),
      patternId: null,
      _members: members,
    });
    if (model) {
      const vec = pocketMembership(model, members);
      internal[internal.length - 1]._membership = vec;
      internal[internal.length - 1].membership = topNormalized(vec, params.collections.membershipTopK);
    }
  }
  const patterns = clusterPatterns(internal, baseline, labels, params);
  if (model) {
    const byId = new Map(internal.map((p) => [p.id, p]));
    const matchAttrs = new Map();
    for (const pt of patterns) {
      const vecs = pt.pocketIds.map((id) => byId.get(id)?.membership).filter(Boolean)
        .map((m) => new Map(m.map((x) => [x.collectionId, x.weight])));
      pt.membership = topNormalized(meanVector(vecs), params.collections.membershipTopK);
      const patternVec = new Map(pt.membership.map((x) => [x.collectionId, x.weight]));
      pt.collectionCandidates = collectionCandidates(model, patternVec, pt.topSongs, {
        nowMs, params,
        matchOf: (songId) => {
          if (!matchAttrs.has(songId)) {
            matchAttrs.set(songId, attributesOf({ id: null, songId, atMs: nowMs }, feats, { params, tzFallbackMin }));
          }
          return featureMatch(matchAttrs.get(songId), pt);
        },
      });
    }
  }
  internal.sort((a, b) => b.startMs - a.startMs || (a.id < b.id ? -1 : 1));
  const out = internal.slice(0, params.maxPockets).map(({ _members, _membership, ...rest }) => rest);

  const doc = {
    v: 1, generatedAtMs: nowMs, stale: false, algo: algoOf(params),
    baseline: { plays: baseline.N, windowDays: params.baselineDays, thin: baseline.thin },
    labels: { places: placesSnap, trips: tripsSnap },
    pockets: out, patterns,
    collectionsSeen: model ? model.seen : 0,
  };
  // "In the Pocket" labels — only when the profile has played the game, so a profile that never
  // has computes exactly the document it always did.
  if (Array.isArray(eventsDoc?.rounds) && eventsDoc.rounds.length) {
    doc.rounds = learnFromRounds(eventsDoc.rounds, { nowMs, params });
  }
  return doc;
}
