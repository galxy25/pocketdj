// LISTENING POCKETS — THE ONE PLACE EVERY KNOB LIVES.
//
// A listening pocket is the user in a groove: three or more songs in a row with no skip, for as
// long as they stay in it. `detect.mjs` finds them with the session/run rules below, `analyze.mjs`
// works out what DEFINES each one against the user's own baseline, and clusters the ones that
// recur across days into named patterns. Every threshold either of them reads is here, so a
// tuning pass is a diff to this file and nothing else — and `computeResults` echoes the whole
// object back as `algo.params`, so a results document always says which rules produced it.
//
// `version` is bumped whenever a change would make yesterday's results disagree with today's for
// the same events (a different pocket boundary, a different defining rule) — the app may show it.

export const POCKET_PARAMS = Object.freeze({
  version: 1,
  // ── Detection ────────────────────────────────────────────────────────────────────────────────
  sessionGapMs: 30 * 60 * 1000,      // start-to-start gap that splits sessions (strictly greater)
  minRun: 3,                         // consecutive non-skips that OPEN a pocket
  endOnConsecutiveSkips: 2,          // this many skips in a row END it (user hunting)
  unknownIsPlay: true,               // outcome 'unknown' counts as not-skipped
  partialIsPlay: true,               // stopped/paused <50% without advancing away = not a skip
  excludeSources: Object.freeze(['game']),   // game snippets are never pocket material
  // ── Analysis ─────────────────────────────────────────────────────────────────────────────────
  baselineDays: 90,
  resultsDays: 90, maxPockets: 200,
  thinBaselinePlays: 50,             // baseline.thin = fewer plays than this
  categorical: Object.freeze({ minShare: 0.4, minCount: 2, minLift: 1.5, contextMinLift: 1.25, smoothing: 1, maxFeatures: 8 }),
  numeric: Object.freeze({ minCoverage: 0.6, minValues: 3, maxDispersionRatio: 0.5, bpmFold: Object.freeze([80, 160]) }),
  // `minPairs` is an addition to the v1 spec: a "harmonic flow" claim over ONE transition is a
  // coin flip that happened to land, not a property of the pocket.
  harmonic: Object.freeze({ minRate: 0.5, minLiftOverBaseline: 2, minPairs: 2 }),
  ctxDominantShare: 0.6,
  // [name, startHour, endHour) in LOCAL time; a start after the end wraps midnight (night 22–5).
  timeBuckets: Object.freeze([
    Object.freeze(['night', 22, 5]), Object.freeze(['morning', 5, 10]), Object.freeze(['midday', 10, 14]),
    Object.freeze(['afternoon', 14, 18]), Object.freeze(['evening', 18, 22]),
  ]),
  patterns: Object.freeze({ minPockets: 2, minDistinctDays: 2, genreKeyMinShare: 0.5, maxTopSongs: 25 }),
  // ── Jobs ─────────────────────────────────────────────────────────────────────────────────────
  nightlyRecomputeAfterMs: 20 * 60 * 60 * 1000,
});

/// STORAGE + WIRE limits — not part of the algorithm (never echoed in results), but knobs all the
/// same, so they live beside it. Every one is load-bearing for the same reason as the rec engine's:
/// the events object is re-read and re-written on every upload.
export const POCKET_LIMITS = Object.freeze({
  maxBodyBytes: 4 * 1024 * 1024,     // raw request body, checked BEFORE parsing
  maxBatchEvents: 2000,              // events in one upload
  maxPlaces: 200, maxTrips: 400,     // label snapshot rows kept per upload
  maxStoredEvents: 20_000,           // per profile, oldest-first eviction
  retentionDays: 180,                // stored events older than this are dropped
  maxStr: 256,                       // every stored string, in SERIALIZED bytes
  maxStateBytes: 16 * 1024 * 1024,   // serialized events object; oldest rows shed past this
  futureSkewMs: 24 * 60 * 60 * 1000, // an atMs further in the future than this is a bad row
  maxProfilesDefault: 10,            // enrollment cap when MAX_PROFILES is unset
  nightlyLowTimeMs: 25_000,          // chain a continuation when less than this remains
  nightlyMaxHops: 20,
});
