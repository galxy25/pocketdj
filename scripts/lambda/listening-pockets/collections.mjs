// LISTENING POCKETS — COLLECTION MEMBERSHIP (docs/design/pockets-collections.md). Pure functions over
// the stored collections snapshot + add history: no I/O, no clock.
//
//   m(s)     the membership vector of song s — collectionId → weight:
//            · HARD   1.0 × add-time recency `0.5 + 0.5·exp(−ageDays/addHalfLifeDays)` for every
//                     collection s is CURRENTLY a (flattened) member of, ageDays measured from the
//                     ANALYSIS time (`nowMs`). Membership is current and RETROACTIVE (Levi,
//                     2026-10-13): adding a song to a playlist today re-labels every older pocket it
//                     played in on the next compute; a removal stops counting the same way.
//                     Unknown add time → `unknownAddWeight`.
//            · SOFT   `softMax × sim(s, centroid(c))` when sim ≥ softMin, for collections s is NOT
//                     in — "a song similar to the songs in a playlist expresses that playlist".
//   add sessions  adds within `addSessionGapMs` of each other on one install; co-added pairs are an
//                 affinity signal ("the user thought these went together").
//
// Song musical facts arrive through an injected `songInfo(songId)` (analyze.mjs owns the features
// join), so this module has no import cycle with analyze.mjs.
//
// The TIMBRE math (axes, usable-row rule, centroid + spread profile, saturating fit) is COPIED from
// scripts/lambda/rec-engine/index.mjs (`isUsableTimbreRow` / `timbreDistance` / `timbreProfile` /
// `timbreFit`), not imported: each Lambda zip packages only its own directory.

import { POCKET_PARAMS } from './params.mjs';
import { identityKeys } from './features.mjs';

const DAY_MS = 24 * 60 * 60 * 1000;
const round = (x, dp) => { const m = 10 ** dp; return Math.round(x * m) / m; };

// ── Timbre (copied from rec-engine; constants mirror its TIMBRE_* block) ────────────────────────
const TIMBRE_AXES = ['bright', 'brightVar', 'air', 'width', 'noisy', 'fizz', 'punch', 'busy',
  'dynamic', 'loud', 'm1', 'm2', 'm3', 'm4'];
const TIMBRE_MIN_AXES = 8;
const TIMBRE_MAX_ZERO_AXES = 7;
const TIMBRE_MIN_VECTORS = 3;
const TIMBRE_DECAY = 0.12;   // rec-engine TIMBRE_DECAY = TIMBRE_NOISE_FLOOR

export function isUsableTimbreRow(f) {
  if (!f || typeof f !== 'object') return false;
  let usable = 0; let zeros = 0;
  for (const k of TIMBRE_AXES) {
    if (!(k in f)) continue;
    if (!Number.isFinite(f[k])) return false;
    usable += 1;
    if (f[k] === 0) zeros += 1;
  }
  return usable >= TIMBRE_MIN_AXES && zeros < TIMBRE_MAX_ZERO_AXES;
}

export function timbreDistance(a, b) {
  if (!a || !b) return null;
  let sum = 0; let n = 0;
  for (const k of TIMBRE_AXES) {
    const x = a[k]; const y = b[k];
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
    sum += (x - y) * (x - y);
    n += 1;
  }
  return n >= TIMBRE_MIN_AXES ? Math.sqrt(sum / n) : null;
}

export function timbreProfile(members, minVectors = TIMBRE_MIN_VECTORS) {
  const usable = (members || []).filter((m) => m && Number.isFinite(m.w) && m.w > 0 && isUsableTimbreRow(m.f));
  if (usable.length < Math.max(1, minVectors)) return null;
  const centroid = {};
  for (const k of TIMBRE_AXES) {
    let s = 0; let w = 0;
    for (const m of usable) {
      if (!Number.isFinite(m.f[k])) continue;
      s += m.f[k] * m.w;
      w += m.w;
    }
    if (w > 0) centroid[k] = s / w;
  }
  let dSum = 0; let dW = 0;
  for (const m of usable) {
    const d = timbreDistance(m.f, centroid);
    if (d == null) continue;
    dSum += d * m.w;
    dW += m.w;
  }
  if (!(dW > 0)) return null;
  return { centroid, spread: dSum / dW, vectors: usable.length };
}

export function timbreFit(v, profile) {
  if (!profile) return null;
  const d = timbreDistance(v, profile.centroid);
  if (d == null) return null;
  return d <= profile.spread ? 1 : Math.exp(-(d - profile.spread) / TIMBRE_DECAY);
}

// ── Helpers ─────────────────────────────────────────────────────────────────────────────────────

/// The canonical key of a song id (base recording / store id) — what memberships and co-adds join on.
const keysOf = (songId) => { const ks = identityKeys(songId); return ks.length ? [...new Set([songId, ...ks])] : []; };
const canonOf = (songId) => identityKeys(songId)[0] || String(songId);

/// Cosine similarity of two sparse vectors (Map id → weight).
export function cosine(a, b) {
  if (!a?.size || !b?.size) return 0;
  let dot = 0; let na = 0; let nb = 0;
  for (const [k, v] of a) { na += v * v; const w = b.get(k); if (w) dot += v * w; }
  for (const v of b.values()) nb += v * v;
  return na > 0 && nb > 0 ? dot / Math.sqrt(na * nb) : 0;
}

/// Sparse vector → `[{ collectionId, weight }]`: top `k` by weight (ties → id), L1-normalised over
/// what is kept, 4 dp.
export function topNormalized(vec, k) {
  const rows = [...vec].filter(([, w]) => w > 0).sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, k);
  const sum = rows.reduce((s, [, w]) => s + w, 0);
  return sum > 0 ? rows.map(([collectionId, w]) => ({ collectionId, weight: round(w / sum, 4) })) : [];
}

/// The mean of several sparse vectors (missing entries count as 0).
export function meanVector(vecs) {
  const out = new Map();
  if (!vecs.length) return out;
  for (const v of vecs) for (const [k, w] of v) out.set(k, (out.get(k) || 0) + w);
  for (const [k, w] of out) out.set(k, w / vecs.length);
  return out;
}

// ── The model ───────────────────────────────────────────────────────────────────────────────────

/**
 * Stored `{ collections, addEvents }` → the membership model, or null when the profile has sent
 * neither. `songInfo(songId)` → `{ genre, bpm (folded), camelot, neighbors: Set, timbre, moods: [] }`
 * or null for a song the catalog does not know.
 */
export function buildCollectionModel(eventsDoc, songInfo, params = POCKET_PARAMS, nowMs = Date.now()) {
  const cp = params.collections;
  const list = Array.isArray(eventsDoc?.collections?.list) ? eventsDoc.collections.list : null;
  const addEvents = Array.isArray(eventsDoc?.addEvents) ? eventsDoc.addEvents : null;
  if (!list && !addEvents) return null;
  const cols = list || [];

  // Membership index: every identity key of every member → [{ id, addAt }] (one entry per collection).
  const memberIndex = new Map();
  for (const c of cols) {
    const addAt = new Map((Array.isArray(c.adds) ? c.adds : []).map(([s, t]) => [s, t]));
    for (const s of c.songIds || []) {
      const t = addAt.has(s) ? addAt.get(s) : null;
      for (const k of keysOf(s)) {
        if (!memberIndex.has(k)) memberIndex.set(k, new Map());
        const m = memberIndex.get(k);
        const cur = m.get(c.id);
        // Several ids of one recording in one collection: the latest KNOWN add time wins.
        if (cur === undefined || (t != null && (cur == null || t > cur))) m.set(c.id, t);
      }
    }
  }
  /// collectionId → addAt|null for every collection the song is CURRENTLY a member of.
  const hardEntries = (songId) => {
    const out = new Map();
    for (const k of keysOf(songId)) {
      const m = memberIndex.get(k);
      if (!m) continue;
      for (const [id, t] of m) {
        const cur = out.get(id);
        if (cur === undefined || (t != null && (cur == null || t > cur))) out.set(id, t);
      }
    }
    return out;
  };
  /// Hard weight from the add time, relative to the ANALYSIS time (never the play time).
  const hardWeight = (t) => {
    if (t == null || !Number.isFinite(nowMs)) return cp.unknownAddWeight;
    const ageDays = Math.max(0, (nowMs - t) / DAY_MS);
    return 0.5 + 0.5 * Math.exp(-ageDays / cp.addHalfLifeDays);
  };

  // Centroids: collections with ≥ minCentroidMembers resolvable members (first `centroidSample`).
  const centroids = new Map();
  for (const c of cols) {
    const infos = (c.songIds || []).slice(0, cp.centroidSample).map((s) => songInfo(s)).filter(Boolean);
    if (infos.length < cp.minCentroidMembers) continue;
    const genres = infos.map((i) => i.genre).filter(Boolean);
    const genreShare = new Map();
    for (const g of genres) genreShare.set(g, (genreShare.get(g) || 0) + 1 / genres.length);
    const bpms = infos.map((i) => i.bpm).filter((b) => b != null).sort((a, b) => a - b);
    let bpm = null;
    if (bpms.length) {
      const mid = bpms.length >> 1;
      const median = bpms.length % 2 ? bpms[mid] : (bpms[mid - 1] + bpms[mid]) / 2;
      const mean = bpms.reduce((s, x) => s + x, 0) / bpms.length;
      const std = Math.sqrt(bpms.reduce((s, x) => s + (x - mean) ** 2, 0) / bpms.length);
      bpm = { median, sigma: Math.max(cp.bpmSigmaMin, std) };
    }
    const keys = infos.map((i) => i.camelot).filter(Boolean);
    const keyCounts = new Map();
    for (const k of keys) keyCounts.set(k, (keyCounts.get(k) || 0) + 1);
    const timbre = timbreProfile(infos.map((i) => i.timbre).filter(Boolean).map((f) => ({ f, w: 1 })));
    const moodSets = infos.map((i) => i.moods).filter((m) => m?.length).map((m) => new Set(m));
    centroids.set(c.id, { genreShare, genreN: genres.length, bpm, keyCounts, keyN: keys.length, timbre, moodSets });
  }

  const W = cp.simWeights;
  const totalW = Object.values(W).reduce((s, x) => s + x, 0);
  const moodMemo = new Map();
  /// sim(s, centroid(c)) ∈ [0,1], or 0 when too few terms are computable to trust it.
  const simTo = (info, colId) => {
    const cen = centroids.get(colId);
    if (!info || !cen) return 0;
    let num = 0; let den = 0;
    if (info.genre && cen.genreN) { num += W.genre * (cen.genreShare.get(info.genre) || 0); den += W.genre; }
    if (info.bpm != null && cen.bpm) {
      const d = info.bpm - cen.bpm.median;
      num += W.bpm * Math.exp(-(d * d) / (2 * cen.bpm.sigma * cen.bpm.sigma)); den += W.bpm;
    }
    if (info.neighbors?.size && cen.keyN) {
      let hit = 0;
      for (const n of info.neighbors) hit += cen.keyCounts.get(n) || 0;
      num += W.camelot * (hit / cen.keyN); den += W.camelot;
    }
    if (info.timbre && cen.timbre) {
      const f = timbreFit(info.timbre, cen.timbre);
      if (f != null) { num += W.timbre * f; den += W.timbre; }
    }
    if (info.moods?.length && cen.moodSets.length) {
      const mk = `${[...info.moods].sort().join('\u0000')}\u0001${colId}`;
      let jac = moodMemo.get(mk);
      if (jac === undefined) {
        const sSet = new Set(info.moods);
        jac = cen.moodSets.reduce((sum, m) => {
          let inter = 0;
          for (const x of m) if (sSet.has(x)) inter += 1;
          const union = new Set([...m, ...sSet]).size;
          return sum + (union ? inter / union : 0);
        }, 0) / cen.moodSets.length;
        moodMemo.set(mk, jac);
      }
      num += W.mood * jac; den += W.mood;
    }
    if (!(den > 0) || den / totalW < cp.simMinWeight) return 0;
    return num / den;
  };
  const softWeight = (info, colId) => {
    const s = simTo(info, colId);
    return s >= cp.softMin ? cp.softMax * s : 0;
  };

  // Soft vector per song (time-independent; excludes collections the song is CURRENTLY in).
  const softMemo = new Map();
  const softOf = (songId) => {
    const key = canonOf(songId);
    if (softMemo.has(key)) return softMemo.get(key);
    const hard = hardEntries(songId);
    const info = songInfo(songId);
    const out = new Map();
    if (info) {
      for (const colId of centroids.keys()) {
        if (hard.has(colId)) continue;
        const w = softWeight(info, colId);
        if (w > 0) out.set(colId, w);
      }
    }
    softMemo.set(key, out);
    return out;
  };

  /// m(s): current hard memberships ∪ soft. The same for every play of s, old or new.
  const vectorMemo = new Map();
  const vectorOf = (songId) => {
    const key = canonOf(songId);
    if (vectorMemo.has(key)) return vectorMemo.get(key);
    const out = new Map(softOf(songId));
    for (const [colId, t] of hardEntries(songId)) out.set(colId, hardWeight(t));
    vectorMemo.set(key, out);
    return out;
  };

  /// The collections a song is CURRENTLY a hard member of (sorted) — the `collection` dim.
  const collectionsOf = (songId) => [...hardEntries(songId).keys()].sort();

  // ── Add sessions → co-add affinity ──────────────────────────────────────────────────────────
  // Records: `add` events (per install) ∪ the snapshot's current-member add times (install
  // unknown → their own '*' stream), deduplicated by (song, collection, minute).
  const records = []; const seenAdd = new Set();
  for (const a of addEvents || []) {
    if (a?.kind !== 'add') continue;
    const k = `${canonOf(a.songId)}\u0000${a.collectionId}\u0000${a.atMs}`;
    if (seenAdd.has(k)) continue;
    seenAdd.add(k);
    records.push({ songId: a.songId, colId: a.collectionId, atMs: a.atMs, stream: a.installId || '*' });
  }
  for (const c of cols) {
    for (const [s, t] of Array.isArray(c.adds) ? c.adds : []) {
      const k = `${canonOf(s)}\u0000${c.id}\u0000${t}`;
      if (seenAdd.has(k)) continue;
      seenAdd.add(k);
      records.push({ songId: s, colId: c.id, atMs: t, stream: '*' });
    }
  }
  records.sort((a, b) => (a.stream < b.stream ? -1 : a.stream > b.stream ? 1 : 0) || a.atMs - b.atMs
    || (a.songId < b.songId ? -1 : a.songId > b.songId ? 1 : 0) || (a.colId < b.colId ? -1 : a.colId > b.colId ? 1 : 0));
  const sessions = [];
  let cur = null;
  for (const r of records) {
    const prev = cur?.[cur.length - 1];
    if (!cur || prev.stream !== r.stream || r.atMs - prev.atMs > cp.addSessionGapMs) { cur = []; sessions.push(cur); }
    cur.push(r);
  }
  // coAdd: canon(a) → canon(b) → { n, songId (a representative raw id of b), cols: Set (b's add collections) }
  const coAdd = new Map();
  let addSessions = 0;
  for (const s of sessions) {
    const bySong = new Map();
    for (const r of s) {
      const k = canonOf(r.songId);
      if (!bySong.has(k)) bySong.set(k, { songId: r.songId, cols: new Set() });
      bySong.get(k).cols.add(r.colId);
    }
    if (bySong.size < 2 || bySong.size > cp.addSessionMaxSongs) continue;
    addSessions += 1;
    for (const [a] of bySong) {
      if (!coAdd.has(a)) coAdd.set(a, new Map());
      const row = coAdd.get(a);
      for (const [b, info] of bySong) {
        if (a === b) continue;
        if (!row.has(b)) row.set(b, { n: 0, songId: info.songId, cols: new Set() });
        const e = row.get(b);
        e.n += 1;
        for (const c of info.cols) e.cols.add(c);
      }
    }
  }

  // Each collection's members, most recently added first (unknown add times after, in snapshot order).
  const membersByRecency = new Map(cols.map((c) => {
    const addAt = new Map((Array.isArray(c.adds) ? c.adds : []).map(([s, t]) => [s, t]));
    const ids = (c.songIds || []).map((s, i) => ({ s, i, t: addAt.has(s) ? addAt.get(s) : -Infinity }))
      .sort((a, b) => b.t - a.t || a.i - b.i).map((x) => x.s);
    return [c.id, ids];
  }));

  return {
    seen: cols.length, list: cols, centroids, addSessions,
    hardEntries, collectionsOf, vectorOf, softOf, simTo, coAdd, membersByRecency, canonOf, keysOf,
  };
}

/// Pocket membership vector M(P): mean of m(s) over the pocket's (non-skipped) members.
export function pocketMembership(model, members) {
  return meanVector(members.map((a) => model.vectorOf(a.songId)));
}

/**
 * A pattern's `collectionCandidates` (pockets-collections.md): songs that are hard members of the
 * pattern's top collections, or co-added with its topSongs, NOT already in topSongs (under any id).
 * score = blend of cosine(m(song), pattern vector), add-session affinity with the topSongs
 * (saturating at `coAddSaturation`), and the pattern's musical feature match (`matchOf(songId)` →
 * 0…1, or null when the pattern has no musical defining features — that term then drops and the
 * blend renormalises over the rest).
 */
export function collectionCandidates(model, patternVec, topSongs, { nowMs, params = POCKET_PARAMS, matchOf = () => null } = {}) {
  const cp = params.collections;
  const top = new Set();
  for (const t of topSongs) for (const k of model.keysOf(t.songId)) top.add(k);
  const isTop = (songId) => model.keysOf(songId).some((k) => top.has(k));
  const pool = new Map();   // canon → { songId, via: Set, coAdds }
  const enter = (songId) => {
    const k = model.canonOf(songId);
    if (!pool.has(k)) pool.set(k, { songId, via: new Set(), coAdds: 0 });
    return pool.get(k);
  };
  const topCols = [...patternVec].filter(([, w]) => w > 0)
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, cp.candidateTopCollections).map(([id]) => id);
  for (const colId of topCols) {
    let n = 0;
    for (const s of model.membersByRecency.get(colId) || []) {
      if (n >= cp.candidatePerCollection) break;
      if (isTop(s)) continue;
      enter(s).via.add(colId); n += 1;
    }
  }
  for (const t of topSongs) {
    const row = model.coAdd.get(model.canonOf(t.songId));
    if (!row) continue;
    for (const [, e] of row) {
      if (isTop(e.songId)) continue;
      const c = enter(e.songId);
      c.coAdds += e.n;
      for (const col of e.cols) c.via.add(col);
    }
  }
  const B = cp.candidateBlend;
  const out = [];
  for (const c of pool.values()) {
    const mem = cosine(model.vectorOf(c.songId), patternVec);
    const aff = Math.min(1, c.coAdds / cp.coAddSaturation);
    const feat = matchOf(c.songId);
    let num = B.membership * mem + B.coAdd * aff; let den = B.membership + B.coAdd;
    if (feat != null) { num += B.features * feat; den += B.features; }
    const score = den > 0 ? num / den : 0;
    if (!(score > 0)) continue;
    const via = [...c.via].sort((a, b) => (patternVec.get(b) || 0) - (patternVec.get(a) || 0) || (a < b ? -1 : 1));
    out.push({ songId: c.songId, score: round(score, 3), via });
  }
  out.sort((a, b) => b.score - a.score || (a.songId < b.songId ? -1 : 1));
  return out.slice(0, cp.maxCandidates);
}
