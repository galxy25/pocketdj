// PocketDJ RECOMMENDATION ENGINE Lambda (WS-E) — API Gateway HTTP API $default catch-all -> this
// handler. Stores ONE per-profile state JSON (plays / favorites / collection activity / puzzle
// events / collections snapshot) in a PRIVATE S3 bucket and computes recommendations ON REQUEST
// from that state plus a slim precomputed public catalog-features file (rec-features.json, built
// by scripts/build-rec-features.mjs, served from the catalog CloudFront).
//
// ── Auth (single-user pragmatic, ENROLLMENT SECRET + TOFU) ──────────────────────────────────────
// Every route except /health requires the `x-pocketdj-profile` header (validated shape; 400 when
// missing/invalid) and `authorization: Bearer <key>` (401 when missing). State S3 key =
// rec/state/<sha256hex(profileId)>.json.
// The id in that header is OPAQUE here, and since the scoped-profile-id client change it is NOT
// the broadcast X-PocketDJ-Profile the app sends to user-configured third-party servers (jukebox
// brokers, shared rip servers): the client derives `HMAC-SHA256(profileId, key: bearerKey)`, so a
// hostile third party that logged the broadcast id cannot address this profile's state for
// DELETE / rebind. Old builds still present the raw id and keep working (back-compat is just
// "another opaque id"); migrating clients one-time DELETE their raw-id object on first flush.
//
// CREATING state (the FIRST `POST /events` for a profile, which binds keyHash = sha256hex(key)
// trust-on-first-use) additionally requires the shared ENROLLMENT SECRET in
// `x-pocketdj-enroll` — `REC_ENROLL_SECRET` on the function's env, compared in constant time.
// WITHOUT that gate any bearer + any profile header minted a brand-new state object, i.e. the
// endpoint was an open, unbounded write into a bucket with no lifecycle expiry.
// DEFENCE IN DEPTH, because that secret ships in the binary and is therefore extractable: the
// enroll path is ALSO capped at MAX_PROFILES (default 10) distinct state objects, counted with a
// single `rec/state/` LIST. Someone who reverses the token can enroll up to the cap and no
// further; already-enrolled profiles never touch that branch, so the cap can never lock the real
// user out of their own data.
// SINGLE-USER TRADEOFF, deliberately noted for the multi-user revisit: the secret ships inside
// the app binary (`Config.recEngineEnrollSecret`), so it is a CAPABILITY TOKEN, not a per-user
// credential — anyone who extracts it can still enroll profiles. It raises the bar from "curl
// the public URL" to "reverse the binary", and it is rotatable (redeploy + ship a build). The
// real fix when this stops being a one-user service is a per-user identity (Sign in with Apple /
// CloudKit-verified user record) minting a per-profile token, at which point this header goes.
// An ALREADY-BOUND profile keeps working with nothing but its TOFU key — the secret is only ever
// consulted when state would be created (or destroyed, see below).
//
// Every later call must present the same key or 403 { error:'key-mismatch' }. A GET before any
// POST (no state object) returns the empty-recs 200s, never 403. Recovery for a genuinely wedged
// key (a reinstall without iCloud, or two devices racing before CloudKit synced the key doc):
// `DELETE /state` accepts EITHER the bound key OR the enrollment secret, so the in-app "Delete
// cloud data" button really can unwedge the profile — after it, the next POST re-binds fresh.
// REC_ALLOW_REBIND=1 (dev only) still bypasses both checks.
//
// ── Size limits (every one of these is load-bearing; the state object is re-read + re-written on
//    every /events call, inside a 1024 MB / 60 s Lambda) ──────────────────────────────────────────
//   MAX_BODY_BYTES  — raw request body, checked BEFORE parsing
//   MAX_BATCH_EVENTS— plays+favorites+activity+puzzle in one batch
//   CAPS            — per-stream stored caps, favorites INCLUDED (a map that only ever grew)
//   cleanSnapshot   — collections / songIds-per-collection / total-songIds truncation
//   cleanPlayCounts — lifetime play-count SNAPSHOT truncated to MAX_PLAYCOUNT_SONGS, most-played
//                     first (a snapshot, replaced wholesale — never summed; see the function)
//   MAX_STR         — every stored string, bounded by SERIALIZED BYTES (not UTF-16 units)
//   MAX_STATE_BYTES — budget enforced before the PUT by SHEDDING the oldest rows, so no object
//                     can grow past what readState can safely parse
//
// ── Routes ──────────────────────────────────────────────────────────────────────────────────────
//   GET    /health                       -> { ok:true, service:'rec-engine', version:1 }
//   POST   /events                       -> ingest batch (id-deduped, capped) -> accepted/totals
//   GET    /recs/songs?limit=50          -> For You suggestions
//   GET    /recs/collections?songId=S    -> collection suggestions for a song
//   GET    /recs/similar?collectionIds=… -> songs similar to a SET of collections (Gem Collector)
//   DELETE /state                        -> delete the state object
//
// ── Test seams (zero AWS) ───────────────────────────────────────────────────────────────────────
//   REC_LOCAL_DIR      — filesystem state store instead of S3 (the jukebox DRY_RUN idea)
//   REC_FEATURES_FILE  — local features fixture path instead of fetching FEATURES_URL
//   REC_ENROLL_SECRET  — read per request (not captured at module load) so a test can flip it
//   MAX_PROFILES       — likewise per request, so a test can drive the enrollment cap

import { createHash, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, unlinkSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';

const REGION = process.env.AWS_REGION || 'us-west-2';
const REC_BUCKET = process.env.REC_BUCKET;
const FEATURES_URL = process.env.FEATURES_URL || 'https://d2p4cubg6se03u.cloudfront.net/rec-features.json';
const LOCAL_DIR = process.env.REC_LOCAL_DIR || null;
const FEATURES_FILE = process.env.REC_FEATURES_FILE || null;

const PROFILE_RE = /^[A-Za-z0-9._-]{8,64}$/;
const CAPS = { plays: 5000, activity: 3000, puzzle: 2000, favorites: 5000, feedback: 3000 };
/// How far a thumbs-down on an artist/genre may pull a candidate's score down, as a fraction.
/// MIRRORS `ZoneEngine.Tuning.rejectionPenalty` on the device — the two rankers have to agree
/// about what a rejection means, or the tile the user tuned locally and the cloud's "Suggested"
/// tile give opposite answers to the same feedback.
const REJECT_PENALTY = 0.45;
/// And the positive half, likewise mirroring `ZoneEngine.Tuning.acceptanceBoost`.
const ACCEPT_BOOST = 0.20;
/// How many rejections of one ARTIST / one GENRE amount to a full-strength penalty. MIRRORS
/// `RecFeedbackStore.artistSaturation` / `.genreSaturation`. The gap between them is load-bearing:
/// a genre is ~1/12th of the library (and on the owner's, two genres are ~68% of all plays), so a
/// single thumbs-down must not write one off.
const REJECT_ARTIST_SATURATION = 3;
const REJECT_GENRE_SATURATION = 8;
/// Seed weight of an explicitly ACCEPTED song. Below a favorite's 1.0: a ♥ is a standing
/// statement about a song, a thumbs-up is a statement about one recommendation of it.
const MAX_BATCH_EVENTS = 2000;
/// Raw request body ceiling, checked before JSON.parse. Well under Lambda's 6 MB synchronous
/// invocation payload limit, and far above any honest batch (2000 events ≈ 250 KB, a snapshot of
/// a very large library ≈ 1 MB).
const MAX_BODY_BYTES = 4 * 1024 * 1024;
/// Hard ceiling on the SERIALIZED state object. readState GET+parses this on every route
/// (DELETE included), so a state that can't be parsed is a permanently wedged profile.
const MAX_STATE_BYTES = 20 * 1024 * 1024;
/// Per-string ceiling, in SERIALIZED BYTES (see `str`).
const MAX_STR = 256;
/// How many distinct profiles this deployment will ever ENROLL. See the header: the enrollment
/// secret ships inside the app binary, so the cap is what bounds a leaked-token flood. Read per
/// request (a test flips it); a non-positive/absent value means the default.
const defaultMaxProfiles = () => {
  const n = Number(process.env.MAX_PROFILES);
  return Number.isFinite(n) && n > 0 ? Math.trunc(n) : 10;
};
/// How many song ids may sit in the AUDIO-ANALYSIS QUEUE at once (`state.audioQueue`).
///
/// The device asks for ~40 a night (`RecAudioShortlist.defaultPerNight`) and the nightly worker
/// drains what it can before its 06:00 cut-off, so the queue is a short backlog, not a corpus.
/// The cap is what stops a device that refreshes For You twenty times in a day — or one that has
/// lost its `pendingIds` and re-proposes the same rows — from parking an unbounded id list inside
/// an object that is re-read and re-written on every `/events` call. Oldest-first eviction, so a
/// flood pushes out stale requests rather than refusing new ones.
const MAX_AUDIO_QUEUE = 400;
/// How many analysed songs the per-profile FEATURE STORE holds (`rec/audio/<hash>.json`).
///
/// A separate object from the state on purpose: the state is on the hot path of every upload, and
/// a corpus that grows by 40 rows a night forever would put a slowly-inflating read-modify-write
/// in front of every play the user records. This one is read only when a ranking needs it.
/// 20,000 rows ≈ 500 nights at the observed rate — past the point where the corpus stops being
/// the limiting factor — and ≈ 4 MB serialized, which a 1024 MB Lambda parses without noticing.
const MAX_AUDIO_FEATURES = 20_000;
/// Which calibration of the timbre extractor this deployment expects. MIRRORS `TIMBRE_VERSION` in
/// `scripts/lib/audio-analyze.mjs`; served on `GET /audio/queue` so the worker can tell whether a
/// vector it already holds was produced by the current lo/hi table or a superseded one, without
/// the two halves having to be deployed in lockstep.
const TIMBRE_VERSION = 1;
const MAX_COLLECTIONS = 500;
const MAX_SONGIDS_PER_COLLECTION = 5000;
const MAX_SNAPSHOT_SONGIDS = 100_000;
const DAY_MS = 24 * 60 * 60 * 1000;
// ── THE ERA WINDOW (owner: "also factor in year range for recommendation along with genre as a
//    feature, eg some playlist like 808 & swinging is very new jack swing 88-94 r&b") ────────────
// A seed set / collection carries a year WINDOW derived from its own members — p15–p85 of the
// member years, padded ±2y — and candidates score on era fit alongside genre. PERCENTILE, never
// min/max: a deliberate era-outlier the owner filed widens nothing (the real "🏋🏾‍♀️" pocket holds a
// member tagged year 1012 and still windows to 1999–2018). MIRRORS
// `SimilarityFamilies.eraWindow` on the device — cloud and device must compute the SAME window
// for the same membership, or the local tile and the cloud tile disagree about what fits a crate.
const ERA_PCT_LOW = 0.15;
const ERA_PCT_HIGH = 0.85;
const ERA_PAD_YEARS = 2;
/// e-folding of the fit OUTSIDE the window, in years: 2y out keeps 61%, 8y out 14%. A feature,
/// not a filter — a 2020 song against a 1986–1996 window is buried on ERA and still free to win
/// on genre/artist.
const ERA_DECAY_YEARS = 4;
/// Exactly the weight the old |year − mean| term carried, so the rebalance the owner asked for is
/// in the SHAPE of the term (range fit, fail-open), not a quiet reweighting of the score.
const ERA_TERM_WEIGHT = 0.5;
/// Fallback neutral for a round with too few dated candidates to measure one. MEASURED: mean era
/// fit of the full dated catalog (106,879 songs) vs the 81 real pocket windows = 0.758. Mirrors
/// `SimilarityFamilies.fallbackNeutralEraFit`.
const ERA_NEUTRAL_FALLBACK = 0.76;
/// Below this many dated candidates the round mean is noise — same order as a seed set, mirroring
/// `SimilarityFamilies.minObservationsForRoundNeutral`.
const ERA_MIN_NEUTRAL_OBS = 25;
// The similarity BUDGETS the era term renormalizes against when it is structurally dead for a
// whole round (no dated seed / no dated member anywhere / an undated query song): the sum of the
// nominal max weights of each route's similarity terms. The known scoreForYou finding is that an
// unearnable term does NOT renormalize and quietly shrinks every candidate against any absolute
// threshold — the era term refuses to repeat that: when it cannot be earned AT ALL this round,
// its weight redistributes proportionally over the live axes (a uniform ×budget/(budget−era)
// on the summed similarity — ranking-neutral within the round, magnitude-honest across rounds).
//   scoreForYou:      genre 2.0 + bpm 1.0 + camelot 1.0 + year 0.5 + sentiment 1.0
//                     + collection 1.5 + artist 0.75                            = 7.75
//   scoreCollections: genre 2.0 + bpm 1.0 + camelot 0.75 + year 0.5 + sentiment 1.0
//                     + coplay 1.25 + recency 0.5 + puzzle 0.5 + timbre 0.5     = 8.0
const FORYOU_SIM_BUDGET = 7.75;
const COLLECTIONS_SIM_BUDGET = 8.0;
// ── TIMBRE (audio-similarity v2 — the 14-axis sound of a crate / seed set) ──────────────────────
// The corpus rides `rec-features.json` as `t` (build-rec-features.mjs attaches public/timbre.json,
// aliases already resolved), so the Lambda pays NOTHING new for it — `loadFeatures` was already
// fetching the whole file (17.4 MB parses in well under a second on a 1024 MB function, cached 15
// minutes across warm invocations). ~14% of rows carry a vector, concentrated in the vinyl-heavy
// pockets actually being scored — 78 of the owner's 87 collections clear the 3-vector liveness bar.
//
// MIRRORS `SimilarityFamilies`'s timbre section on the device — same axes, same RMS distance
// (F10's: recomputing F10's within-artist+genre vs between-group measurement with this exact
// formula over the full corpus gives 0.163/0.233, ratio 0.70, the published 0.205/0.288 = 0.71
// scale), same centroid+spread profile (centroid beat kNN(k=5) head-to-head on the real pockets,
// held-out-member-vs-same-genre AUC 0.557 vs 0.538 over 60 pockets), same saturating fit and the
// same fail-open rules. The timbre-parity fixture pins the two implementations to 1e-9.
const TIMBRE_AXES = ['bright', 'brightVar', 'air', 'width', 'noisy', 'fizz', 'punch', 'busy',
                     'dynamic', 'loud', 'm1', 'm2', 'm3', 'm4'];
/// Below this many shared finite axes two vectors are not comparable.
const TIMBRE_MIN_AXES = 8;
/// At or above this many axes pinned to EXACTLY 0.0 the row is a failed capture, not a dark
/// record. Mirrors `SimilarityFamilies.timbreMaxZeroAxes`, `scripts/lib/timbre-hygiene.mjs` and
/// `analyze-timbre.py`'s MAX_ZERO_AXES.
const TIMBRE_MAX_ZERO_AXES = 7;

/**
 * IS THIS ROW USABLE AT ALL? Degenerate rows — a null axis, too few axes, or 7+ axes at exactly
 * 0.0 — are all the SAME POINT, so they read as each other's nearest neighbours and recommend
 * each other in a little self-referential clump. That is strictly worse than a missing vector,
 * which merely makes the term fail open. The fold quarantines them and `build-rec-features`
 * refuses to attach them, but this is a READER and a reader must not depend on the writer's
 * discipline — a features file built before those guards existed is still cached at the edge.
 * Mirrors `SimilarityFamilies.isUsableTimbreRow`.
 */
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
/// Minimum analysed members for a LIVE positive profile — a centroid of two songs is those two
/// songs, not a sound. (The NEGATIVE profile passes 1: every 👎 is a deliberate act.)
const TIMBRE_MIN_VECTORS = 3;
/// The INSTRUMENT'S OWN ERROR BAR — the median distance between two independent captures of the
/// same recording, 0.1022 (410 duration-corroborated pairs) to 0.1202 (279 looser ones), against
/// a random-pair median of 0.2324. Mirrors `SimilarityFamilies.timbreNoiseFloor`.
const TIMBRE_NOISE_FLOOR = 0.12;
/// e-fold of the fit OUTSIDE the profile's own spread, set AT the noise floor: one e-fold per
/// error bar. It was 0.05 — finer than the instrument — so `exp(-0.1022/0.05) = 0.130` let pure
/// measurement noise destroy 87% of the term. Reference points: a same-genre non-member now keeps
/// ~90% and one at the corpus between-group mean ~61%. In v1 rail units, like every distance in
/// this file; a rail recalibration invalidates it. Mirrors `SimilarityFamilies.timbreDecay`.
const TIMBRE_DECAY = TIMBRE_NOISE_FLOOR;
/// How far the fit may lift a candidate in the MULTIPLIER surfaces (scoreForYou):
/// `sim × (1 + TIMBRE_GAIN × fit)` — the NOVELTY_AUX_GAIN shape, deliberately under its 1.40×
/// band because timbre's measured same-genre separation (AUC 0.56) is real but modest. Its
/// maximum influence sits between the era sub-term and the genre term. Mirrors
/// `ZoneEngine.Tuning.timbreGain`.
const TIMBRE_GAIN = 0.35;
/// The same signal inside `scoreCollections`, where the house style is a summed TERM (that route
/// has no aux multiplier): exactly the era term's weight, so "comparable to genre/era" is a
/// constant, not a claim.
const TIMBRE_TERM_WEIGHT = 0.5;
/// How much the fit to the REJECTED sound subtracts inside the net fit — mirrors
/// `ZoneEngine.Tuning.rejectionWeight` (a 👎 reorders, never censors).
const TIMBRE_REJECT_WEIGHT = 0.5;
/// Fallback neutral for a round with too few analysed candidates to measure one. MEASURED: mean
/// fit of the full analysed corpus (164,246 scorings) against the owner's 78 live pocket
/// profiles = 0.565. Mirrors `SimilarityFamilies.fallbackNeutralTimbreFit`.
const TIMBRE_NEUTRAL_FALLBACK = 0.57;
/// Below this many analysed candidates the round mean is noise — same bar as the era term.
const TIMBRE_MIN_NEUTRAL_OBS = 25;
/// SHRINKAGE — the `musicalPrior` mechanism, needed here for the same reason family C needs it
/// at 10.4% coverage: with 14% of rows analysed, an unshrunk term over-selects analysed rows at
/// the top purely by variance even though the imputation is unbiased. Measured on the owner's 78
/// live real pockets (unanalysed rows across all top-25s, term off = 1,213): prior 0 keeps 467
/// and empties ELEVEN pockets entirely — structural burial; prior 2 keeps 830 with 2 tie-heavy
/// residuals; prior 3 keeps 871 (diminishing returns). A vector is ONE observation, so at 2 the
/// shrunk fit sits a third of the way from the round mean toward its own evidence — and because
/// the multiplier is monotone, an analysed candidate whose fit measured BELOW the round neutral
/// can never displace an unanalysed one: displacement only ever happens TOWARD the crate's
/// sound. Mirrors `SimilarityFamilies.timbrePrior`; scale down as the corpus grows.
const TIMBRE_PRIOR = 2;
/// How many songs of the LIFETIME play-count snapshot are stored. The client sends its
/// most-played rows first, so the truncation drops the tail — the rows that carry the least
/// ranking signal anyway. A real library tops out around 56k songs with plays; 20k is where the
/// log-scaled weight has long since flattened.
const MAX_PLAYCOUNT_SONGS = 20_000;
/// How much a song's LIFETIME play count can add to its seed weight, at the top of the
/// distribution. One recent play contributes ~1.0 (`exp(0)`), so this makes the single
/// most-played song of all time worth about one play from today — enough to shape taste, not
/// enough to drown out what the user is listening to THIS month.
const PLAYCOUNT_SEED_WEIGHT = 1.0;
/// How much a CANDIDATE's lifetime play count can add to its score. Deliberately below the genre
/// term (2.0): "you love this song" is a real signal in a library of the user's own music, but it
/// must not turn For You into a list of the same ten songs forever. The 72 h exclusion already
/// keeps what is playing right now out.
///
/// ── DEMOTED FROM A SCORE TERM TO AN AUX COMPONENT (the owner's novelty rebalance) ──────────────
/// This is no longer summed into the score alongside genre and collection. Measured on the real
/// profile, `/recs/songs` returned **50 of 50 rows with play history** — and it kept doing so with
/// play counts removed entirely, with last-played dates removed, and at every seed limit from 20 to
/// 2000. So the additive play terms were not the whole cause, but they were the part that put four
/// Drake-credited rows in the top ten. They now reach the score through the same bounded aux
/// multiplier the device's `ZoneEngine.suggestions` uses, alongside the novelty term that is the
/// actual fix. See `NOVELTY_AUX_GAIN`. Kept as WEIGHTS INSIDE that mix, at their shipped ratio to
/// each other, so the relative statement "lifetime affinity outranks a single recent touch" is
/// preserved rather than silently rewritten.
const PLAYCOUNT_CANDIDATE_WEIGHT = 0.15;
/// The same term inside `/recs/similar` (Gem Collector). Lower still: that route is about
/// resembling a CRATE, and familiarity is a tiebreak there rather than a reason.
const PLAYCOUNT_SIMILAR_WEIGHT = 0.5;
/// Half-life of the LAST-PLAYED signal, in days. Two years — the value at which recency lands on
/// the same 0…1 scale as `playCountSignal` over a real library (measured on the owner's 56,224
/// played songs: play-count mean 0.196, recency mean 0.206), which is what makes the weights
/// below mean what they say. Shorter half-lives collapse the term onto a ~500-song sliver (the
/// median song there was last played 5.8 years ago); longer ones flatten it into noise. Mirrors
/// `PlayRecency.halfLifeDays` on the client — change both together.
const RECENCY_HALF_LIFE_DAYS = 730;
/// How much a song's RECENCY can add to its seed weight. Below `PLAYCOUNT_SEED_WEIGHT` because
/// the two are on the same scale (see above), so this ratio is a deliberate statement — lifetime
/// affinity outranks a single recent touch — rather than an artifact of units. The 30-day play
/// window above already speaks for genuinely fresh listening.
const RECENCY_SEED_WEIGHT = 0.75;
/// A CANDIDATE's recency. One notch below `PLAYCOUNT_CANDIDATE_WEIGHT` — the same ratio it has
/// always had — but, like it, now a component of the bounded aux mix rather than a term summed
/// into the score. See `PLAYCOUNT_CANDIDATE_WEIGHT`.
const RECENCY_CANDIDATE_WEIGHT = 0.10;
/// ── NOVELTY: THE SECOND SIGNAL ─────────────────────────────────────────────────────────────────
/// Pull of ARTIST-LEVEL novelty inside the aux mix — three quarters of it, against 0.15 + 0.10 for
/// the two play-derived components. MIRRORS `ZoneEngine.Tuning.suggestionNoveltyWeight` on the
/// device (0.75 against 0.25); the two rankers have to agree about what novelty means or the tile
/// the user tunes locally and the cloud "Suggested" tile give opposite answers to the same library.
///
/// WHY THE ARTIST AND NOT THE SONG — the identity that kills the obvious version. With song-level
/// novelty `nov = 1 − fam`, `sim + wf·fam + wn·(1 − fam)` is `sim + wn + (wf − wn)·fam`: the `wn`
/// is a constant across candidates and cannot reorder anything, so adding song novelty at `wn` is
/// exactly cutting the play weight to `wf − wn` under a different name (measured Spearman between
/// the two axes: **−1.000**). Artist novelty measures −0.387 against the play term — partly
/// independent — and, being an artist AGGREGATE, is defined for 100% of songs including the 47.8%
/// that carry no play data at all. Full derivation in `apple/PocketDJ/Services/Recommendations/RecNovelty.swift`.
const NOVELTY_CANDIDATE_WEIGHT = 0.75;
/// How far the aux mix may lift a candidate: `sim × (1 + NOVELTY_AUX_GAIN × aux)`.
///
/// MULTIPLICATIVE AND BOUNDED, which is what keeps novelty from becoming randomness: a candidate
/// can never outrank one whose SIMILARITY is more than 1.40× its own, so similarity still decides
/// which tier a song is in and novelty only reorders inside it. Added on instead — the obvious
/// shape — a novelty term has no such bound, and at the bottom of the admitted similarity range a
/// flat bonus is a multi-fold swing. Mirrors `ZoneEngine.Tuning.suggestionAuxGain`.
const NOVELTY_AUX_GAIN = 0.40;
/// The same term inside `/recs/similar`, where — like familiarity — recency is a tiebreak about
/// the crate rather than a reason for it.
const RECENCY_SIMILAR_WEIGHT = 0.35;
/// ── THE INCUMBENT CAP (the owner's 50% newcomer floor) ─────────────────────────────────────────
/// Owner, verbatim: *"cap our for you per collection at max 50% of suggestions for artists that
/// are already in the pocket, that way we can learn the features of related artists to make our
/// recommendations more novel and collection expanding vs model collapse."*
///
/// A COMPOSITION CONSTRAINT, not a scoring change: `scoreCollections` ranks exactly as before,
/// then `composeIncumbentCap` composes the final suggestion list so rows that are INCUMBENT —
/// here, a collection that ALREADY HOLDS any of the song's credited artists — are at most this
/// share, rounding in the newcomers' favor on odd counts (⌊n·share⌋ incumbents in an n-row list).
/// FAIL OPEN: when the newcomer pool runs dry the remainder fills from incumbents rather than
/// starving the list — the floor is a target, never a hole. Mirrors
/// `ZoneEngine.Tuning.suggestionIncumbentMaxShare` on the device; the newcomer-parity fixture
/// pins the two compose implementations to identical output.
const INCUMBENT_MAX_SHARE = 0.5;

const sha256 = (s) => createHash('sha256').update(s).digest('hex');

// ── State store: S3 (ETag-conditional) or local filesystem (tests) ──────────────────────────────
// Local mode mirrors the conditional-put semantics with a content-hash pseudo-ETag so the retry
// path is testable without AWS.

let _s3 = null; let _s3mod = null;
async function s3() {
  if (!_s3) {
    _s3mod = await import('@aws-sdk/client-s3');
    _s3 = new _s3mod.S3Client({ region: REGION });
  }
  return { client: _s3, mod: _s3mod };
}

const stateKey = (profileHash) => `rec/state/${profileHash}.json`;
const localStatePath = (profileHash) => join(LOCAL_DIR, 'rec', 'state', `${profileHash}.json`);
/// The AUDIO FEATURE STORE — one object per profile, beside the state and never inside it.
const audioKey = (profileHash) => `rec/audio/${profileHash}.json`;
const localAudioPath = (profileHash) => join(LOCAL_DIR, 'rec', 'audio', `${profileHash}.json`);

class Precondition extends Error {}

async function readState(profileHash) {
  if (LOCAL_DIR) {
    const p = localStatePath(profileHash);
    if (!existsSync(p)) return null;
    const bytes = readFileSync(p, 'utf8');
    return { state: JSON.parse(bytes), etag: sha256(bytes) };
  }
  const { client, mod } = await s3();
  try {
    const out = await client.send(new mod.GetObjectCommand({ Bucket: REC_BUCKET, Key: stateKey(profileHash) }));
    return { state: JSON.parse(await out.Body.transformToString()), etag: out.ETag };
  } catch (e) {
    if (e.name === 'NoSuchKey' || e.name === 'NotFound' || e.$metadata?.httpStatusCode === 404) return null;
    throw e;
  }
}

/// How many profiles already have a state object. Only ever called on the ENROLL branch (a
/// profile that has no state yet), so the steady-state cost is zero: one prefix LIST on the
/// handful of requests that would create something. Stops as soon as the cap is reached.
async function countProfiles(cap) {
  if (LOCAL_DIR) {
    const dir = join(LOCAL_DIR, 'rec', 'state');
    if (!existsSync(dir)) return 0;
    return readdirSync(dir).filter((f) => f.endsWith('.json')).length;
  }
  const { client, mod } = await s3();
  let count = 0; let token;
  do {
    const out = await client.send(new mod.ListObjectsV2Command({
      Bucket: REC_BUCKET, Prefix: 'rec/state/', ContinuationToken: token, MaxKeys: 1000,
    }));
    count += out.KeyCount || 0;
    if (count >= cap) return count;
    token = out.IsTruncated ? out.NextContinuationToken : undefined;
  } while (token);
  return count;
}

const serializedBytes = (obj) => Buffer.byteLength(JSON.stringify(obj), 'utf8');

/// Bring a state object back under `max` by SHEDDING its oldest rows.
///
/// The per-stream caps make this unreachable for honest data — but they cap ROW COUNT, and a
/// batch of pathologically long strings can blow the byte ceiling at any row count. REFUSING the
/// write there (what this used to do) wedged the profile FOREVER: every later upload re-read the
/// same too-big state, re-merged, and 413'd again, with no path back. Shedding costs the oldest
/// history's recommendation value instead, which the client simply re-uploads inside its 30-day
/// overlap window.
///
/// Order is least-valuable-first: plays and activity (the bulk, and the most redundant), then
/// puzzle, then favorites by the same rule `capFavorites` uses, and only then the membership
/// snapshot. Quarter-at-a-time so a 20 MB object converges in a few dozen re-serializations.
export function shedToFit(state, max = MAX_STATE_BYTES) {
  let bytes = serializedBytes(state);
  if (bytes <= max) return { bytes, shed: 0 };
  let shed = 0;
  const dropOldest = (arr) => {
    const n = Math.max(1, Math.ceil(arr.length / 4));
    arr.sort((a, b) => a.atMs - b.atMs || (a.id < b.id ? -1 : 1));
    return arr.splice(0, n).length;
  };
  /// Play counts shed LEAST-PLAYED first (not oldest — they have no per-row timestamp). That is
  /// the right direction: a 1-play row contributes almost nothing to a log-scaled weight, while
  /// the head of the distribution is the entire point of the signal.
  const dropLeastPlayed = (counts) => {
    const keys = Object.keys(counts);
    const n = Math.max(1, Math.ceil(keys.length / 4));
    keys.sort((a, b) => (counts[a] || 0) - (counts[b] || 0) || (a < b ? -1 : 1));
    for (const k of keys.slice(0, n)) delete counts[k];
    return n;
  };
  for (let guard = 0; guard < 400 && bytes > max; guard++) {
    if (state.plays?.length) shed += dropOldest(state.plays);
    else if (state.activity?.length) shed += dropOldest(state.activity);
    else if (state.puzzle?.length) shed += dropOldest(state.puzzle);
    // Feedback sheds AFTER puzzle and BEFORE play counts: it is the smallest stream and the most
    // deliberate — every row is something the user pressed a button to say — so it is worth more
    // per byte than a play event and should be among the last things to go.
    else if (state.feedback?.length) shed += dropOldest(state.feedback);
    else if (Object.keys(state.playCounts?.counts || {}).length) {
      shed += dropLeastPlayed(state.playCounts.counts);
    } else if (Object.keys(state.favorites || {}).length) {
      const before = Object.keys(state.favorites).length;
      capFavorites(state.favorites, Math.max(0, before - Math.max(1, Math.ceil(before / 4))));
      shed += before - Object.keys(state.favorites).length;
    } else if (state.collections?.list?.length) {
      state.collections.list.pop(); shed += 1;
    } else break;
    bytes = serializedBytes(state);
  }
  return { bytes, shed };
}

async function writeState(profileHash, state, { ifMatch } = {}) {
  // Enforce the byte budget by shedding, not by refusing — see shedToFit.
  shedToFit(state);
  const body = JSON.stringify(state);
  // Only reachable now if a SINGLE remaining row is itself over budget, which the MAX_STR bound
  // makes impossible; keep the throw as the assertion it has become.
  if (Buffer.byteLength(body, 'utf8') > MAX_STATE_BYTES) {
    const err = new Error('state-too-large'); err.statusCode = 413; throw err;
  }
  if (LOCAL_DIR) {
    const p = localStatePath(profileHash);
    if (ifMatch) {
      const cur = existsSync(p) ? sha256(readFileSync(p, 'utf8')) : null;
      if (cur !== ifMatch) throw new Precondition('etag mismatch');
    } else if (existsSync(p)) {
      throw new Precondition('exists');
    }
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, body);
    return;
  }
  const { client, mod } = await s3();
  try {
    await client.send(new mod.PutObjectCommand({
      Bucket: REC_BUCKET, Key: stateKey(profileHash), Body: body, ContentType: 'application/json',
      ...(ifMatch ? { IfMatch: ifMatch } : { IfNoneMatch: '*' }),
    }));
  } catch (e) {
    const code = e.$metadata?.httpStatusCode;
    if (code === 412 || code === 409 || e.name === 'PreconditionFailed' || e.name === 'ConditionalRequestConflict') {
      throw new Precondition(e.message);
    }
    throw e;
  }
}

async function deleteState(profileHash) {
  if (LOCAL_DIR) {
    const p = localStatePath(profileHash);
    if (existsSync(p)) unlinkSync(p);
    const a = localAudioPath(profileHash);
    if (existsSync(a)) unlinkSync(a);
    return;
  }
  const { client, mod } = await s3();
  await client.send(new mod.DeleteObjectCommand({ Bucket: REC_BUCKET, Key: stateKey(profileHash) }));
  // "Delete cloud data" has to mean ALL of it. The audio-feature store lives in its own object,
  // so a delete that only removed the state would leave a per-profile corpus behind — derived
  // from listening, addressable by the same hash, and invisible to the user who asked for
  // erasure. Best-effort: a profile with no corpus yet has no object, and a failure here must
  // not turn a successful state deletion into an error the app reports as "not deleted".
  try {
    await client.send(new mod.DeleteObjectCommand({ Bucket: REC_BUCKET, Key: audioKey(profileHash) }));
  } catch { /* absent or already gone */ }
}

// ── AUDIO FEATURE STORE (rec/audio/<hash>.json) ─────────────────────────────────────────────────
// The timbre vectors the nightly librosa job produced, per profile. Plain read/overwrite: exactly
// ONE writer exists (the nightly worker, serially, once a night), so the ETag-conditional dance
// the state object needs would be ceremony without a race to prevent.
//
// ── THE RANKING CHANGE THIS STORE WAS BUILT TOWARD IS NOW WIRED (2026-08-11) ────────────────────
// F10 deferred the timbre term at 1.75% coverage because a term defined for a handful of
// candidates and none of the rest is not "a weak signal" — it is an INCOMPARABLE one: two songs
// ranked by different formulas, the tile reordering for reasons no thumbs-up caused. Both
// blockers are gone and the term is live in `scoreForYou` (bounded multiplier, TIMBRE_GAIN) and
// `scoreCollections` (summed term, TIMBRE_TERM_WEIGHT — that route's house style, exactly the
// era term's shape):
//   1. COVERAGE — the warm-batch backfill (timbre-batch.mjs) swept every song with decodable
//      audio: 14,916 corpus rows (~14% of catalog), CONCENTRATED in the pockets actually being
//      scored — 78 of the owner's 87 collections clear the 3-vector liveness bar, vinyl-heavy
//      pockets near-totally. F10's "~60% of the candidate pool" trigger was superseded by the
//      RENORMALIZE-OVER-LIVE-AXES pattern the era term shipped: round-neutral imputation makes
//      mixed coverage FAIR (an unanalysed candidate scores the measured mean of its analysed
//      competitors), which was the actual requirement behind the coverage number.
//   2. FEEDBACK — verdicts on analysed songs shift the taste: accepted songs SEED (so they move
//      the positive centroid at seed weight) and rejected analysed songs build a negative
//      centroid subtracted inside the net fit (timbreNetFit). Where no verdicts exist the term
//      degrades to the play-derived centroid alone — gracefully, never structurally.
//   3. BOUNDED — `sim × (1 + TIMBRE_GAIN × fit)`, the NOVELTY_AUX_GAIN shape, 1.35× band.
//
// The vectors reach the scorer through `rec-features.json`'s `t` field (public corpus, folded
// nightly), NOT through this per-profile store: `loadFeatures` already fetches that file, so the
// term costs the request path nothing, while reading this store per-request would add an S3 GET
// for vectors that reach the public corpus on the next fold anyway. This store remains the
// nightly worker's landing zone.
//
// The discrimination the term rests on, measured on the owner's real catalog: F10's original 96
// songs across 12 artist+genre groups gave within/between pairwise distance 0.205/0.288 (ratio
// 0.71); recomputed over the FULL 2026-08-11 corpus with the shipped `timbreDistance` the same
// measurement gives 0.163/0.233 (ratio 0.70) — same scale, same conclusion, which is also the
// verification that the shipped RMS formula IS F10's distance and not a reinvention.

async function readAudio(profileHash) {
  if (LOCAL_DIR) {
    const p = localAudioPath(profileHash);
    if (!existsSync(p)) return null;
    return JSON.parse(readFileSync(p, 'utf8'));
  }
  const { client, mod } = await s3();
  try {
    const out = await client.send(new mod.GetObjectCommand({ Bucket: REC_BUCKET, Key: audioKey(profileHash) }));
    return JSON.parse(await out.Body.transformToString());
  } catch (e) {
    if (e.name === 'NoSuchKey' || e.name === 'NotFound' || e.$metadata?.httpStatusCode === 404) return null;
    throw e;
  }
}

async function writeAudio(profileHash, doc) {
  const body = JSON.stringify(doc);
  if (LOCAL_DIR) {
    const p = localAudioPath(profileHash);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, body);
    return;
  }
  const { client, mod } = await s3();
  await client.send(new mod.PutObjectCommand({
    Bucket: REC_BUCKET, Key: audioKey(profileHash), Body: body, ContentType: 'application/json',
  }));
}

/// Which profiles have state at all — the worker's "whose queues should I drain" list. Only the
/// nightly job calls this (once a night, holding the enrollment secret), so a full prefix LIST is
/// the right shape; nothing on the request path pays for it.
async function listProfileHashes() {
  if (LOCAL_DIR) {
    const dir = join(LOCAL_DIR, 'rec', 'state');
    if (!existsSync(dir)) return [];
    return readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5));
  }
  const { client, mod } = await s3();
  const hashes = []; let token;
  do {
    const out = await client.send(new mod.ListObjectsV2Command({
      Bucket: REC_BUCKET, Prefix: 'rec/state/', ContinuationToken: token, MaxKeys: 1000,
    }));
    for (const o of out.Contents || []) {
      const m = /^rec\/state\/([0-9a-f]{64})\.json$/.exec(o.Key || '');
      if (m) hashes.push(m[1]);
    }
    token = out.IsTruncated ? out.NextContinuationToken : undefined;
  } while (token);
  return hashes;
}

/// Fold a worker's batch into a profile's feature corpus. LAST WRITE WINS PER SONG so a
/// re-analysis at a newer `TIMBRE_VERSION` replaces the old vector instead of accumulating two
/// readings of the same recording under one id.
///
/// REFUSES ANOTHER CALIBRATION, like every other store of these vectors. The rails ARE the units,
/// so a v(N) and a v(N+1) reading are different quantities sharing a name — and this was the one
/// store in the system with no version refusal: it stamped `v` on the row and then filtered on
/// nothing, so one document could hold both and no reader could tell them apart. The doc comment
/// above describes exactly this filter, and it was not there. A row at another calibration is
/// DROPPED (never accepted, never counted), which leaves the previous vector standing rather than
/// replacing a readable number with an unreadable one; the id still drains from the queue at the
/// call site, because a worker that reported is a worker that reported.
///
/// Exported for the tests: this is where the corpus cap and the shape validation live, and both
/// are far easier to pin here than through an HTTP fixture.
export function mergeAudioFeatures(doc, rows) {
  const out = doc && typeof doc === 'object' && doc.songs && typeof doc.songs === 'object'
    ? doc : { v: 1, songs: {}, updatedAtMs: 0 };
  let accepted = 0;
  for (const raw of Array.isArray(rows) ? rows : []) {
    const songId = str(raw?.songId);
    const f = raw?.f;
    if (!songId || !f || typeof f !== 'object') continue;
    // Absent ⇒ 1, the version that shipped before the field existed — the same reading every
    // other consumer gives an unstamped row.
    if ((Number.isFinite(raw.v) ? raw.v : 1) !== TIMBRE_VERSION) continue;
    const clean = {};
    for (const [k, v] of Object.entries(f)) {
      // Axis names are short identifiers and values are 0…1 — anything else is a bug or a
      // hostile worker, and either way it must not reach the scorer.
      if (!/^[a-z][a-z0-9]{0,11}$/.test(k)) continue;
      if (!Number.isFinite(v)) continue;
      clean[k] = Math.round(Math.min(1, Math.max(0, v)) * 1000) / 1000;
    }
    if (!Object.keys(clean).length) continue;
    out.songs[songId] = { v: TIMBRE_VERSION, f: clean, atMs: Date.now() };
    accepted += 1;
  }
  // Oldest-first eviction, matching every other cap here.
  const ids = Object.keys(out.songs);
  if (ids.length > MAX_AUDIO_FEATURES) {
    ids.sort((a, b) => (out.songs[a].atMs || 0) - (out.songs[b].atMs || 0));
    for (const id of ids.slice(0, ids.length - MAX_AUDIO_FEATURES)) delete out.songs[id];
  }
  out.updatedAtMs = Date.now();
  return { doc: out, accepted };
}

// ── Features cache (module-level, survives warm invocations) ────────────────────────────────────

let _features = null;   // { parsed, byId, etag, fetchedAtMs }
const FEATURES_TTL_MS = 15 * 60 * 1000;

function indexFeatures(parsed) {
  const byId = new Map();
  for (const row of parsed?.songs || []) byId.set(row.i, row);
  return byId;
}

async function loadFeatures() {
  if (FEATURES_FILE) {
    if (!_features) {
      const parsed = JSON.parse(readFileSync(FEATURES_FILE, 'utf8'));
      _features = { parsed, byId: indexFeatures(parsed), etag: null, fetchedAtMs: Date.now() };
    }
    return _features;
  }
  const now = Date.now();
  if (_features && now - _features.fetchedAtMs < FEATURES_TTL_MS) return _features;
  const headers = _features?.etag ? { 'If-None-Match': _features.etag } : {};
  const res = await fetch(FEATURES_URL, { headers, signal: AbortSignal.timeout(20_000) });
  if (res.status === 304 && _features) {
    _features.fetchedAtMs = now;
    return _features;
  }
  if (!res.ok) {
    if (_features) return _features;   // stale beats none
    const err = new Error('features-unavailable'); err.statusCode = 503; throw err;
  }
  let parsed = null;
  try { parsed = await res.json(); } catch { /* SPA fallback HTML / partial body */ }
  if (!parsed || !Array.isArray(parsed.songs)) {
    // The catalog CDN answers missing files with the SPA shell (200 + HTML) — before
    // rec-features.json is deployed this is the path every /recs/* request takes.
    if (_features) return _features;
    const err = new Error('features-unavailable'); err.statusCode = 503; throw err;
  }
  _features = { parsed, byId: indexFeatures(parsed), etag: res.headers.get('etag'), fetchedAtMs: now };
  return _features;
}

// ── Camelot ─────────────────────────────────────────────────────────────────────────────────────

/** Harmonic neighbor set of a Camelot code: itself, ±1 same letter (12↔1 wrap), same number
 *  other letter. Invalid/absent code -> empty set. */
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

/** Genre category of a song per the features file (g omitted = 'other'/unknown -> null). */
export function genreOf(byId, songId) {
  return byId.get(songId)?.g ?? null;
}

// ── Song IDENTITY (the "already in that collection" rule) ───────────────────────────────────────

/**
 * Every key one song id can be recognised by — the SERVER half of the client's `RecMembership`.
 *
 * Owner: "don't recommend songs that are already in that collection for adding to a collection."
 * The device filters, and it filters better than this can (it holds the catalog, so it can join a
 * `sng_` row to an `amrec_` capture through `appleMusicId`). But a client-side filter alone
 * silently WASTES CANDIDATE SLOTS: every member this route emits is a row the client then throws
 * away, so a 200-song answer can come back 190 songs long for no reason the owner can see. So the
 * server applies everything it can decide from the id STRING ALONE:
 *
 *   · `sng_<hex>_clean` / `_explicit`  -> the base recording (`SongVariant.baseId` on the client)
 *   · `amrec_<storeId>`                -> `am:<storeId>` (the ad-hoc capture convention)
 *
 * It deliberately does NOT try the catalog join: `rec-features.json` carries no Apple Music store
 * id (fields are i/al/a/n/g/y/b/c/s), and inventing one here would mean shipping catalog metadata
 * to the server that the device already has. The device computes; the server receives ids.
 */
export function identityKeys(songId) {
  const id = String(songId || '');
  if (!id) return [];
  const out = [];
  const variant = /^(sng_[0-9a-f]{12})_(clean|explicit)$/.exec(id);
  out.push(variant ? variant[1] : id);
  const adhoc = /^amrec_(\d+)$/.exec(id);
  // Same guard as the client's `validStoreKey`: a short or all-zero "store id" is a placeholder,
  // and folding a placeholder into one identity would delete real suggestions wholesale.
  if (adhoc && adhoc[1].length >= 4 && /[1-9]/.test(adhoc[1])) out.push(`am:${adhoc[1]}`);
  return out;
}

/** The identity keys of a whole membership list, as one Set. */
export function identitySet(songIds) {
  const out = new Set();
  for (const id of songIds || []) for (const k of identityKeys(id)) out.add(k);
  return out;
}

/** Is `songId` already in `keys` (an `identitySet`), under ANY of its identities? */
export function identityHas(keys, songId) {
  for (const k of identityKeys(songId)) if (keys.has(k)) return true;
  return false;
}

// ── State shape + batch merge ───────────────────────────────────────────────────────────────────

function freshState(profileId) {
  const now = Date.now();
  return {
    v: 1, profileId, keyHash: null, createdAtMs: now, updatedAtMs: now,
    plays: [], favorites: {}, activity: [], puzzle: [], feedback: [],
    collections: { atMs: 0, list: [] },
    playCounts: { atMs: 0, counts: {} },
  };
}

const num = (v) => (Number.isFinite(v) ? v : null);

/// What one string COSTS in the serialized state object: its JSON form minus the two quotes.
const jsonCost = (s) => JSON.stringify(s).length - 2;

/// Every stored string goes through here: absent/empty -> null, everything else TRUNCATED to
/// `max` SERIALIZED BYTES. Truncation (not rejection) keeps an honest-but-long name/id ingesting,
/// while a megabyte "id" can no longer be parked in the state object.
///
/// The budget is bytes-on-the-wire, NOT UTF-16 units, because those differ by 6×: `''`
/// is one unit but serializes to the six characters ``, and any non-ASCII character is 2-4
/// UTF-8 bytes. A unit-based `slice(0, 256)` therefore let an adversarial batch of control
/// characters push the state object past MAX_STATE_BYTES at a perfectly legal row count.
const str = (v, max = MAX_STR) => {
  if (typeof v !== 'string' || v === '') return null;
  let s = v.length > max ? v.slice(0, max) : v;
  // Converges in a couple of passes: each step scales the length by the budget/cost ratio and
  // always removes at least one unit.
  while (s.length > 0 && jsonCost(s) > max) {
    const next = Math.min(s.length - 1, Math.max(0, Math.floor((s.length * max) / jsonCost(s))));
    s = s.slice(0, next);
  }
  // A slice can land between a surrogate pair; drop the orphan rather than store a lone half.
  const lastCode = s.charCodeAt(s.length - 1);
  if (lastCode >= 0xd800 && lastCode <= 0xdbff) s = s.slice(0, -1);
  return s === '' ? null : s;
};

function cleanPlay(e) {
  const id = str(e?.id); const songId = str(e?.songId); const atMs = num(e?.atMs);
  if (!id || !songId || atMs == null) return null;
  const out = { id, songId, atMs };
  const source = str(e.source);
  if (source) out.source = source;
  return out;
}
function cleanFavorite(e) {
  const songId = str(e?.songId); const atMs = num(e?.atMs);
  if (!songId || atMs == null || typeof e?.favorited !== 'boolean') return null;
  return { songId, favorited: e.favorited, atMs };
}
function cleanActivity(e) {
  const id = str(e?.id); const atMs = num(e?.atMs);
  const kind = str(e?.kind); const itemId = str(e?.itemId);
  if (!id || atMs == null || !kind || !itemId) return null;
  const out = { id, atMs, kind, itemId };
  for (const k of ['collectionId', 'collectionKind', 'collectionName']) {
    const v = str(e[k]);
    if (v) out[k] = v;
  }
  return out;
}
function cleanPuzzle(e) {
  const id = str(e?.id); const atMs = num(e?.atMs); const action = str(e?.action);
  if (!id || atMs == null || !action) return null;
  const out = { id, atMs, action };
  for (const k of ['gameId', 'songId', 'collectionId']) {
    const v = str(e[k]);
    if (v) out[k] = v;
  }
  if (num(e.points) != null) out.points = e.points;
  return out;
}
/// EXPLICIT accept/reject on a recommendation — the owner's tuning loop.
///
/// An EVENT STREAM, deliberately, not a per-song map: "rejected three times" is a stronger
/// statement than "rejected", and the artist/genre penalty below is built from the COUNTS. The
/// hard exclusion reads the same rows folded last-writer-wins (`feedbackOf`), which is exactly the
/// pair of readings `RecFeedbackStore` makes on the device.
///
/// `cleared` is a first-class action, not a delete: the log is append-only on both sides so the
/// union-by-id CloudKit merge stays safe, and an undo the server never hears is an undo that only
/// works on one device.
const FEEDBACK_ACTIONS = new Set(['accepted', 'rejected', 'cleared']);
function cleanFeedback(e) {
  const id = str(e?.id); const atMs = num(e?.atMs);
  const songId = str(e?.songId); const action = str(e?.action);
  if (!id || atMs == null || !songId || !action || !FEEDBACK_ACTIONS.has(action)) return null;
  const out = { id, atMs, songId, action };
  for (const k of ['surface', 'context']) {
    const v = str(e[k]);
    if (v) out[k] = v;
  }
  return out;
}

/// The membership snapshot is stored WHOLESALE, and (unlike the event streams) it is not counted
/// toward MAX_BATCH_EVENTS — a legitimate flush carries a full batch AND the snapshot, so
/// counting it would reject honest uploads. It is bounded by TRUNCATION instead: at most
/// MAX_COLLECTIONS entries, MAX_SONGIDS_PER_COLLECTION ids each, MAX_SNAPSHOT_SONGIDS in total.
function cleanSnapshot(s) {
  if (!s || typeof s !== 'object' || !Array.isArray(s.collections)) return null;
  const list = [];
  let budget = MAX_SNAPSHOT_SONGIDS;
  for (const c of s.collections) {
    if (list.length >= MAX_COLLECTIONS) break;
    const id = str(c?.id); const kind = str(c?.kind); const name = str(c?.name) ?? '';
    if (!id || !kind || !Array.isArray(c?.songIds)) continue;
    const songIds = [];
    for (const x of c.songIds) {
      if (songIds.length >= MAX_SONGIDS_PER_COLLECTION || budget <= 0) break;
      const v = str(x);
      if (!v) continue;
      songIds.push(v); budget -= 1;
    }
    list.push({ id, kind, name, songIds });
  }
  return { atMs: num(s.atMs) ?? Date.now(), list };
}

/// LIFETIME play counts — a SNAPSHOT, not an event stream.
///
/// Stored (and merged) WHOLESALE, exactly like `collectionsSnapshot`, because that is what it is
/// on the client too: Apple's counters are read as a whole and REPLACE the previous reading. The
/// alternative — treating each row as an increment — would inflate on every re-upload, which is
/// the same bug the SET-never-ADD rule exists to prevent on the device. A stale batch (older
/// `atMs` than what is stored) is DROPPED rather than applied, so two devices uploading out of
/// order can't walk the numbers backwards.
///
/// Bounded by TRUNCATION, like the collections snapshot, and not counted toward
/// MAX_BATCH_EVENTS: an honest flush carries a full event batch AND this.
function cleanPlayCounts(p) {
  if (!p || typeof p !== 'object' || !p.counts || typeof p.counts !== 'object') return null;
  // Highest counts first, so the MAX_PLAYCOUNT_SONGS truncation keeps the rows that matter.
  const rows = [];
  for (const [rawId, rawN] of Object.entries(p.counts)) {
    const songId = str(rawId);
    const n = num(rawN);
    if (!songId || n == null || !(n > 0)) continue;
    rows.push([songId, Math.trunc(n)]);
  }
  rows.sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
  const counts = {};
  for (const [songId, n] of rows.slice(0, MAX_PLAYCOUNT_SONGS)) counts[songId] = n;
  // LAST-PLAYED days ride the same snapshot, and are bounded by the SAME truncation: a date for
  // a songId whose count did not survive is dropped, or the map would be unbounded (a real
  // library carries 56k dates against a 20k count cap) and would describe rows nothing else
  // stores. Whole days only; non-positive/garbage dropped, so absent stays "never played".
  const src = p.lastPlayedDays;
  let lastPlayedDays;
  if (src && typeof src === 'object') {
    const days = {};
    let kept = 0;
    for (const songId of Object.keys(counts)) {
      const d = num(src[songId]);
      if (d == null || !(d > 0)) continue;
      days[songId] = Math.trunc(d);
      kept += 1;
    }
    if (kept > 0) lastPlayedDays = days;
  }
  const out = { atMs: num(p.atMs) ?? Date.now(), counts };
  if (lastPlayedDays) out.lastPlayedDays = lastPlayedDays;
  return out;
}

function capOldest(arr, cap) {
  if (arr.length <= cap) return arr;
  return [...arr].sort((a, b) => a.atMs - b.atMs || (a.id < b.id ? -1 : 1)).slice(arr.length - cap);
}

/// Favorites are a MAP keyed by songId, so `capOldest` doesn't fit — but an uncapped map was the
/// one stream that only ever grew (2000 fresh songIds per batch, forever). Evict OLDEST-atMs
/// first, exactly like every other stream; heart-over-tombstone only breaks an atMs TIE.
///
/// Preferring hearts as the PRIMARY key (what this did) quietly broke last-writer-wins, the rule
/// the whole favorites merge is built on: a FRESH un-heart arriving at the cap was evicted while
/// a STALE heart survived, and the next upload from a lagging device — which still carries that
/// old heart inside its 30-day overlap window — then re-merged it as if it were current. The
/// user's un-favorite came back on its own. Eviction must never invert the merge's time order.
function capFavorites(favorites, cap) {
  const keys = Object.keys(favorites);
  if (keys.length <= cap) return favorites;
  keys.sort((a, b) => {
    const fa = favorites[a]; const fb = favorites[b];
    const ta = fa?.favorited ? 1 : 0; const tb = fb?.favorited ? 1 : 0;
    return (fa?.atMs || 0) - (fb?.atMs || 0) || ta - tb || (a < b ? -1 : 1);
  });
  for (const k of keys.slice(0, keys.length - cap)) delete favorites[k];
  return favorites;
}

/** Pure ingest merge: dedupe by event id (plays/activity/puzzle — idempotent re-uploads are the
 *  norm), favorites keyed by songId newer-atMs wins, collections snapshot replaced WHOLESALE when
 *  the batch carries one, caps applied after merge (drop oldest). Unknown batch fields ignored
 *  (the reserved `songFeatures` key is accepted and dropped in v1). Mutates + returns `state`
 *  with an `accepted` tally. */
export function mergeBatch(state, batch) {
  const accepted = { plays: 0, favorites: 0, activity: 0, puzzle: 0, feedback: 0,
                     collectionsSnapshot: false, playCounts: 0, audioQueue: 0 };

  const playIds = new Set(state.plays.map((e) => e.id));
  for (const raw of batch.plays || []) {
    const e = cleanPlay(raw);
    if (!e || playIds.has(e.id)) continue;
    playIds.add(e.id); state.plays.push(e); accepted.plays += 1;
  }
  state.plays = capOldest(state.plays, CAPS.plays);

  for (const raw of batch.favorites || []) {
    const e = cleanFavorite(raw);
    if (!e) continue;
    const cur = state.favorites[e.songId];
    if (cur && cur.atMs >= e.atMs) continue;
    state.favorites[e.songId] = { favorited: e.favorited, atMs: e.atMs };
    accepted.favorites += 1;
  }
  state.favorites = capFavorites(state.favorites, CAPS.favorites);

  const actIds = new Set(state.activity.map((e) => e.id));
  for (const raw of batch.activity || []) {
    const e = cleanActivity(raw);
    if (!e || actIds.has(e.id)) continue;
    actIds.add(e.id); state.activity.push(e); accepted.activity += 1;
  }
  state.activity = capOldest(state.activity, CAPS.activity);

  const puzIds = new Set(state.puzzle.map((e) => e.id));
  for (const raw of batch.puzzle || []) {
    const e = cleanPuzzle(raw);
    if (!e || puzIds.has(e.id)) continue;
    puzIds.add(e.id); state.puzzle.push(e); accepted.puzzle += 1;
  }
  state.puzzle = capOldest(state.puzzle, CAPS.puzzle);

  // Feedback. `state.feedback` is defaulted rather than assumed: a state object written before
  // this stream existed has no such key, and every read below would otherwise throw on it.
  if (!Array.isArray(state.feedback)) state.feedback = [];
  const fbIds = new Set(state.feedback.map((e) => e.id));
  for (const raw of batch.feedback || []) {
    const e = cleanFeedback(raw);
    if (!e || fbIds.has(e.id)) continue;
    fbIds.add(e.id); state.feedback.push(e); accepted.feedback += 1;
  }
  state.feedback = capOldest(state.feedback, CAPS.feedback);

  const snap = cleanSnapshot(batch.collectionsSnapshot);
  if (snap) { state.collections = { atMs: snap.atMs, list: snap.list }; accepted.collectionsSnapshot = true; }

  // AUDIO-ANALYSIS QUEUE — a SET of song ids, merged rather than replaced.
  //
  // Merged, because two devices can each propose a shortlist between two nightly runs and the
  // second must not erase the first. A SET, because the client's own `pendingIds` can be lost
  // (a reinstall, a restore) and the re-proposal that follows has to be a no-op — that is the
  // idempotence the whole refresh protocol rests on. Oldest-first eviction at the cap.
  if (!Array.isArray(state.audioQueue)) state.audioQueue = [];
  const queued = new Set(state.audioQueue);
  for (const raw of batch.audioQueue?.songIds || []) {
    const id = str(raw);
    if (!id || queued.has(id)) continue;
    queued.add(id); state.audioQueue.push(id); accepted.audioQueue += 1;
  }
  if (state.audioQueue.length > MAX_AUDIO_QUEUE) {
    state.audioQueue = state.audioQueue.slice(state.audioQueue.length - MAX_AUDIO_QUEUE);
  }

  const pc = cleanPlayCounts(batch.playCounts);
  // Newer-snapshot-wins. Re-uploading the SAME snapshot is a no-op (equal atMs loses), which is
  // what makes an idempotent client flush free.
  if (pc && pc.atMs > (state.playCounts?.atMs || 0)) {
    // SET, never merge — the dates are part of the same wholesale snapshot as the counts, so a
    // newer reading REPLACES both together. Carrying old dates forward under new counts would
    // resurrect rows the newer snapshot deliberately dropped.
    state.playCounts = { atMs: pc.atMs, counts: pc.counts };
    if (pc.lastPlayedDays) state.playCounts.lastPlayedDays = pc.lastPlayedDays;
    accepted.playCounts = Object.keys(pc.counts).length;
  }

  state.updatedAtMs = Date.now();
  return { state, accepted };
}

// ── For You (GET /recs/songs) ───────────────────────────────────────────────────────────────────

/**
 * LIFETIME play counts as a 0…1 ranking signal.
 *
 * LOG-SCALED and normalised against the library's own maximum, for two reasons. Raw counts are
 * hopelessly skewed — one real library's top song has 244 plays while the median played song has
 * 2 — so a linear term would make the top ten songs the only ones that ever scored. And the
 * normalisation is what keeps the term comparable across users: someone with a 10-play maximum
 * and someone with a 5000-play maximum both get a full-strength 1.0 at the top of their own
 * distribution.
 *
 * Returns 0 for absent/zero, so an unplayed song contributes nothing rather than a penalty.
 */
export function playCountSignal(n, maxN) {
  if (!Number.isFinite(n) || n <= 0 || !Number.isFinite(maxN) || maxN <= 0) return 0;
  return Math.log2(1 + Math.min(n, maxN)) / Math.log2(1 + maxN);
}

/**
 * `PuzzleSimilarity.artistKey` — diacritic + case insensitive, trimmed, leading "the " stripped.
 * The device's normalizer, mirrored so both sides bucket an artist the same way.
 */
export function artistKey(a) {
  let s = String(a || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  if (s.startsWith('the ')) s = s.slice(4);
  return s;
}

/**
 * The PRIMARY artist of a credit string — what a per-artist cap has to key on.
 *
 * MIRRORS `RecNovelty.primaryArtistKey` on the device, separators and all. Measured on the real
 * profile, the shipped cap of 2-per-artist let FOUR Drake-credited rows into a 50-row list, because
 * "Drake & Future" is a different string from "Drake" and therefore had its own budget. A cap a
 * credit string can walk around is not a cap.
 *
 * The comma guard is the one hand-written exception: a comma normally separates a list, but
 * "Tyler, The Creator" is a NAME, and a list item never begins with "the ".
 *
 * Where the two risks trade off this SPLITS, because the failure directions are not symmetric:
 * two different artists colliding into one bucket makes the cap stricter (a tile loses a row it
 * could have had), while one artist escaping their bucket is the defect being fixed.
 */
export function primaryArtistKey(credit) {
  const s = String(credit || '').toLowerCase();
  const seps = ['& ', 'feat. ', 'feat ', 'featuring ', 'ft. ', 'ft ', 'with ', 'x ', 'vs. ', 'vs '];
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === ',') {
      let j = i + 1;
      while (j < s.length && s[j] === ' ') j++;
      if (!s.startsWith('the ', j)) return artistKey(s.slice(0, i));
      i = j - 1;
      continue;
    }
    if (c === '/') return artistKey(s.slice(0, i));
    // The word-ish separators only count STANDING ALONE between spaces, so "Fetty Wap" does not
    // split on a "with"-shaped middle and "Xavier" is not an " x " collaboration.
    if (c === ' ') {
      for (const w of seps) if (s.startsWith(w, i + 1)) return artistKey(s.slice(0, i));
    }
  }
  return artistKey(s);
}

// ── The credit split (incumbent identity) ──────────────────────────────────────────────────────
// MIRRORS `RecVersionIdentity.creditArtistKeys` on the device, helper for helper. The incumbent
// test ("is this artist already in the pocket?") must run on CREDIT keys, never raw strings:
// measured on the owner's real library, both of his Dinner Party albums are filed under
// "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington" and the raw
// string never meets "Terrace Martin". The newcomer-parity fixture pins this mirror to the Swift.

const RVI_CREDIT_SPLIT_WORDS = [' and ', ' x ', ' with ', ' vs ', ' versus '];
const RVI_MAX_CREDIT_NAMES = 12;

/// `RecVersionIdentity.fold` — diacritic-folded, lowercased, `&` ⇒ ` and `, 7"/12" ⇒ ` inch `.
function rviFold(raw) {
  let t = String(raw || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  if (t.includes('&')) t = t.replace(/&/g, ' and ');
  if (t.includes('"') || t.includes("''") || t.includes('inch')) {
    t = t.replace(/\b(7|12)\s*(?:"|''|-?\s*inch)/g, ' inch ');
  }
  return t;
}

/// `RecVersionIdentity.tokens` — alphanumeric runs, everything else a separator.
const rviTokens = (s) => s.match(/[\p{L}\p{N}]+/gu) || [];

/// `RecVersionIdentity.stripParenGroups` — bracketed groups removed, depth-aware.
function rviStripParenGroups(s) {
  let out = '';
  let depth = 0;
  for (const ch of s) {
    if (ch === '(' || ch === '[' || ch === '{') { depth += 1; continue; }
    if (ch === ')' || ch === ']' || ch === '}') { if (depth > 0) depth -= 1; continue; }
    if (depth === 0) out += ch;
  }
  return out;
}

/// `RecVersionIdentity.stripCreditTail` — an un-parenthesized trailing credit dropped ("Song
/// feat. X"). `with` deliberately not a tail marker there (it IS a split word below).
function rviStripCreditTail(s) {
  const toks = rviTokens(s);
  const idx = toks.findIndex((t) => t === 'feat' || t === 'featuring' || t === 'ft');
  if (idx <= 0) return s;
  return toks.slice(0, idx).join(' ');
}

/// `RecVersionIdentity.artistKey` — the loose artist key the credit split emits.
function rviArtistKey(raw) {
  const s = rviStripCreditTail(rviStripParenGroups(rviFold(raw)));
  const t = rviTokens(s).join(' ');
  if (t.startsWith('the ') && t.length > 4) return t.slice(4);
  return t;
}

/// `RecVersionIdentity.splitCredit` — break a folded credit into names on `, ; /` and the padded
/// word separators (whole words only — " and " never splits "Bandit").
function rviSplitCredit(folded) {
  let pieces = folded.split(/[,;/]/).filter((p) => p !== '');
  for (const word of RVI_CREDIT_SPLIT_WORDS) {
    pieces = pieces.flatMap((piece) => {
      const padded = ` ${piece} `;
      if (!padded.includes(word)) return [piece];
      return padded.split(word);
    });
  }
  return pieces;
}

/**
 * EVERY ARTIST NAMED IN A CREDIT — the whole-string key plus one per name. Mirrors
 * `RecVersionIdentity.creditArtistKeys` exactly (the newcomer-parity fixture is the law): a
 * bracketed credit is read twice ("[IVY] & XIRA" must index "ivy"), a compilation sleeve naming
 * more than RVI_MAX_CREDIT_NAMES stops indexing, duplicates keep first position.
 */
export function creditArtistKeys(raw) {
  const s = String(raw || '');
  const out = [];
  const seen = new Set();
  const add = (k) => {
    if (k && out.length < RVI_MAX_CREDIT_NAMES && !seen.has(k)) { seen.add(k); out.push(k); }
  };
  const debracketed = s.replace(/[()[\]{}]/g, ' ');
  for (const source of (debracketed === s ? [s] : [s, debracketed])) {
    add(rviArtistKey(source));
    const folded = rviStripCreditTail(rviStripParenGroups(rviFold(source)));
    if (!/[,;/]/.test(folded) && !RVI_CREDIT_SPLIT_WORDS.some((w) => folded.includes(w))) continue;
    for (const piece of rviSplitCredit(folded)) add(rviArtistKey(piece));
  }
  return out;
}

/**
 * THE OWNER'S 50% NEWCOMER FLOOR, as a pure composition function — the shared idiom both sides
 * run (`RecComposition.compose` on the device; the newcomer-parity fixture pins the two).
 *
 * Rank first, compose after: `rows` arrive in FINAL RANKED ORDER, each knowing its `capKey`
 * (per-artist budget key; '' ⇒ uncapped) and whether it is INCUMBENT. The composition then:
 *
 *   1. sizes the list exactly as the plain capped walk would (`n` — the floor may reorder the
 *      list, never shorten it);
 *   2. walks the ranking in order, taking every row the artist budget allows EXCEPT incumbents
 *      beyond ⌊n·incumbentMaxShare⌋, which spill — so newcomers deeper in the ranking are pulled
 *      up and relative order is preserved WITHIN each pool (the 3-per-artist cap idiom);
 *   3. FAILS OPEN: spilled incumbents refill the remainder, in order, when the newcomer pool runs
 *      dry — a tiny catalog gets its full list, never a hole.
 *
 * A list already under the cap is untouched (the budget never binds), and ⌊·⌋ rounds odd counts
 * in the newcomers' favor.
 */
export function composeIncumbentCap(rows, { limit = Infinity, maxPerArtist = Infinity,
                                            incumbentMaxShare = INCUMBENT_MAX_SHARE } = {}) {
  const cap = maxPerArtist > 0 ? maxPerArtist : Infinity;
  // Phase 0 — the target size: what the plain artist-capped walk returns today.
  let n = 0;
  {
    const per = new Map();
    for (const r of rows) {
      if (n >= limit) break;
      const k = r.capKey || '';
      if (k && (per.get(k) || 0) >= cap) continue;
      if (k) per.set(k, (per.get(k) || 0) + 1);
      n += 1;
    }
  }
  const incumbentCap = Math.min(n, Math.max(0, Math.floor(n * incumbentMaxShare)));
  const per = new Map();
  const out = [];
  const spill = [];
  let incumbents = 0;
  const blocked = (r) => { const k = r.capKey || ''; return !!k && (per.get(k) || 0) >= cap; };
  const take = (r) => { const k = r.capKey || ''; if (k) per.set(k, (per.get(k) || 0) + 1); out.push(r); };
  // Phase A — the capped walk, incumbents budgeted.
  for (const r of rows) {
    if (out.length >= n) break;
    if (blocked(r)) continue;
    if (r.isIncumbent && incumbents >= incumbentCap) { spill.push(r); continue; }
    if (r.isIncumbent) incumbents += 1;
    take(r);
  }
  // Phase B — fail open: the newcomer pool ran dry, refill from the spilled incumbents in order.
  for (const r of spill) {
    if (out.length >= n) break;
    if (blocked(r)) continue;
    take(r);
  }
  return out;
}

/**
 * ARTIST-level familiarity, 0…1, log-scaled against the listener's own top artist.
 *
 * Rolled up to the PRIMARY artist deliberately: keyed on the raw credit, a "Drake & Future" row is
 * an artist with almost no plays and would therefore score as NOVEL — which lets the very
 * concentration this term exists to break back in through the collaboration door.
 *
 * `live: false` when the profile carries no play counts at all. The caller then drops the whole aux
 * mix rather than scoring every candidate an identical novelty of 1.0 — the renormalization rule,
 * the same one `feedbackOf` and the device's `hasDormancy` follow.
 */
export function artistFamiliarityOf(featuresById, lifetimeCounts) {
  // ONE PASS, and it MEMOIZES the split. The scoring loop, the reason strings and the per-artist
  // cap all need a row's primary-artist key, and the features doc is ~108k rows against ~20k
  // distinct credits — so resolving it per row per call site is three full splits of the catalog
  // on every request. `keyOf` is handed back so every later call site is a Map lookup.
  const keys = new Map();
  const keyOf = (credit) => {
    if (!credit) return '';
    let k = keys.get(credit);
    if (k === undefined) { k = primaryArtistKey(credit); keys.set(credit, k); }
    return k;
  };
  const totals = new Map();
  let live = false;
  for (const row of featuresById.values()) {
    const k = keyOf(row.a);
    const n = lifetimeCounts[row.i] || 0;
    if (!(n > 0) || !k) continue;
    live = true;
    totals.set(k, (totals.get(k) || 0) + n);
  }
  let maxN = 0;
  for (const n of totals.values()) if (n > maxN) maxN = n;
  const denom = maxN > 0 ? Math.log2(1 + maxN) : 0;
  const fam = new Map();
  if (denom > 0) for (const [k, n] of totals) fam.set(k, Math.min(1, Math.log2(1 + n) / denom));
  return {
    live: live && denom > 0,
    keyOf,
    familiarity: (k) => fam.get(k) || 0,
    novelty: (k) => (live && denom > 0 ? 1 - (fam.get(k) || 0) : 0),
    /// Never played this artist at all ⇒ the strongest form of the signal, and the one worth
    /// spelling out on the row.
    isUnknown: (k) => live && denom > 0 && !fam.has(k),
  };
}

/**
 * Blend novelty with the two play-derived axes into one 0…1 aux, RENORMALIZED over whichever the
 * profile can actually speak. Mirrors `RecNovelty.aux` on the device (which has no recency axis —
 * that one is the cloud's, and it renormalizes out when there are no last-played dates).
 */
export function auxMix({ novelty, plays, recency, hasNovelty, hasPlays, hasRecency }) {
  let num = 0; let den = 0;
  if (hasNovelty) { num += NOVELTY_CANDIDATE_WEIGHT * novelty; den += NOVELTY_CANDIDATE_WEIGHT; }
  if (hasPlays) { num += PLAYCOUNT_CANDIDATE_WEIGHT * plays; den += PLAYCOUNT_CANDIDATE_WEIGHT; }
  if (hasRecency) { num += RECENCY_CANDIDATE_WEIGHT * recency; den += RECENCY_CANDIDATE_WEIGHT; }
  return den > 0 ? num / den : 0;
}

/**
 * The ERA WINDOW of a set of member years — p15–p85 (weighted nearest-rank), padded ±2y — or
 * null when nothing is dated. See the ERA constants above for the owner's brief and why it is a
 * percentile and never min/max. `weights` (optional, parallel to `years`) lets a recency-weighted
 * seed set count a heavy seed as more of the era than a marginal one; uniform weights make this
 * EXACTLY the device's `SimilarityFamilies.eraWindow`, which is what keeps the two sides' windows
 * identical for the same membership.
 */
export function eraWindow(years, weights = null) {
  const rows = [];
  for (let i = 0; i < (years?.length || 0); i++) {
    const y = years[i];
    if (!Number.isFinite(y) || y <= 0) continue;
    const w = weights ? weights[i] : 1;
    if (!Number.isFinite(w) || w <= 0) continue;
    rows.push([y, w]);
  }
  if (!rows.length) return null;
  rows.sort((a, b) => a[0] - b[0]);
  const total = rows.reduce((s, [, w]) => s + w, 0);
  // Weighted nearest-rank: the smallest member year at which the cumulative weight reaches p.
  // The epsilon absorbs float summing so uniform weights reproduce ceil(p·n) exactly.
  const at = (p) => {
    const target = p * total - 1e-9;
    let cum = 0;
    for (const [y, w] of rows) { cum += w; if (cum >= target) return y; }
    return rows[rows.length - 1][0];
  };
  return { lo: at(ERA_PCT_LOW) - ERA_PAD_YEARS, hi: at(ERA_PCT_HIGH) + ERA_PAD_YEARS };
}

/**
 * 0…1 era fit of one dated song against a window: 1.0 anywhere INSIDE (an era is a range — 1989
 * is not "more 88–94" than 1993), exponential decay outside. Mirrors
 * `SimilarityFamilies.eraFit`.
 */
export function eraFit(year, window) {
  if (!window || !Number.isFinite(year)) return 0;
  if (year >= window.lo && year <= window.hi) return 1;
  const gap = year < window.lo ? window.lo - year : year - window.hi;
  return Math.exp(-gap / ERA_DECAY_YEARS);
}

/**
 * RMS timbre distance over the axes BOTH vectors carry, or null below TIMBRE_MIN_AXES.
 * F10's distance, not a new one — see the TIMBRE constants for the verification.
 * Mirrors `SimilarityFamilies.timbreDistance`.
 */
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

/**
 * A profile's timbre — the weighted member CENTROID plus the profile's own weighted SPREAD (mean
 * member→centroid distance), or null under `minVectors` usable vectors (the term is then
 * unearnable this round and DROPS — fail open at round level, never per song).
 * `members`: [{ f, w }]. Mirrors `SimilarityFamilies.timbreProfile`.
 */
export function timbreProfile(members, minVectors = TIMBRE_MIN_VECTORS) {
  const usable = (members || []).filter((m) => m && Number.isFinite(m.w) && m.w > 0
    && isUsableTimbreRow(m.f));
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

/**
 * 0…1 fit of one analysed song to a profile: 1.0 anywhere inside the profile's own spread (a
 * crate's sound is a REGION — a song inside it is not "more the sound" for hugging the
 * centroid), exponential decay outside. null when the vectors share too few axes ("no vector").
 * Mirrors `SimilarityFamilies.timbreFit(_:profile:)`.
 */
export function timbreFit(v, profile) {
  if (!profile) return null;
  const d = timbreDistance(v, profile.centroid);
  if (d == null) return null;
  return d <= profile.spread ? 1 : Math.exp(-(d - profile.spread) / TIMBRE_DECAY);
}

/**
 * The NET fit — positive fit minus TIMBRE_REJECT_WEIGHT × the fit to the rejected sound, floored
 * at 0. How a 👎 on an analysed song shifts the taste on the timbre axis.
 * Mirrors `SimilarityFamilies.timbreNetFit`.
 */
export function timbreNetFit(v, positive, negative) {
  const pos = timbreFit(v, positive);
  if (pos == null) return null;
  const neg = negative ? timbreFit(v, negative) : null;
  return neg == null ? pos : Math.max(0, pos - TIMBRE_REJECT_WEIGHT * neg);
}

/**
 * The words a profile's sound can honestly be described in — NAMED axes only (m1…m4 are the
 * unnamed residual; brightVar/width have no adjective a listener would recognise). An axis
 * speaks only ≥0.15 off the middle; strongest deviations win the (≤ max) slots.
 * Mirrors `SimilarityFamilies.timbreAdjectives` — the parity fixture pins the table.
 */
export function timbreAdjectives(centroid, max = 3) {
  const table = [
    ['punch', 'punchy', 'smooth'],
    ['bright', 'bright', 'dark'],
    ['busy', 'busy', 'sparse'],
    ['dynamic', 'dynamic', 'even'],
    ['loud', 'loud', 'quiet'],
    ['noisy', 'gritty', 'clean'],
    ['air', 'airy', 'warm'],
  ];
  const picks = [];
  for (const [axis, hi, lo] of table) {
    const v = centroid?.[axis];
    if (!Number.isFinite(v)) continue;
    const dev = v - 0.5;
    if (Math.abs(dev) < 0.15) continue;
    picks.push([dev > 0 ? hi : lo, Math.abs(dev)]);
  }
  picks.sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
  return picks.slice(0, Math.max(0, max)).map(([w]) => w);
}

/** The stored lifetime counts as `{ counts, maxN }`, with `maxN` 0 when there is no signal. */
function playCountsOf(state) {
  const counts = state.playCounts?.counts || {};
  let maxN = 0;
  for (const n of Object.values(counts)) if (Number.isFinite(n) && n > maxN) maxN = n;
  return { counts, maxN };
}

/**
 * LAST-PLAYED as a 0…1 ranking signal — a SEPARATE AXIS from `playCountSignal`, never a
 * refinement of it.
 *
 * Smooth exponential decay at a two-year half-life, not a "played in the last N days" flag. On a
 * real library the last-played dates skew heavily old (median 5.8 years, and 0 songs inside a
 * week), so a cliff scores 99.5% of the catalog identically zero and ranks on a sliver; the
 * gradient is what lets the term say anything about the library the user actually owns.
 *
 * `lastPlayedDay` is WHOLE DAYS since the epoch (what the client sends — see `RecPlayCountsWire`).
 * Returns 0 for absent, so a never-played song contributes nothing rather than a penalty. A
 * FUTURE date (clock skew) clamps to 1 rather than growing without bound.
 */
export function recencySignal(lastPlayedDay, nowMs) {
  if (!Number.isFinite(lastPlayedDay) || lastPlayedDay <= 0 || !Number.isFinite(nowMs)) return 0;
  // BOTH SIDES IN WHOLE DAYS. Comparing a millisecond `now` against a day-granular date charges
  // a song played this morning up to a full day of age depending on what time the request lands,
  // which makes the signal wobble over the course of a day for input that never changed. Flooring
  // `now` too makes the age an exact integer count of days.
  const ageDays = Math.floor(nowMs / DAY_MS) - lastPlayedDay;
  return Math.pow(0.5, Math.max(0, ageDays) / RECENCY_HALF_LIFE_DAYS);
}

/** The stored last-played days, `{}` when the client has never sent any. */
function lastPlayedOf(state) {
  return state.playCounts?.lastPlayedDays || {};
}

/**
 * The feedback log, folded the two ways the ranking needs it.
 *
 *  • `rejected` / `accepted` — LAST WRITER WINS per song. This is the HARD half: a rejected song
 *    is excluded from the output outright. Anything softer makes a thumbs-down a suggestion the
 *    engine may ignore, which is not what the button means.
 *  • `rejectedArtists` / `rejectedGenres` / `acceptedArtists` — 0..1 SATURATED strengths
 *    (count / saturation, capped at 1). This is the SOFT half: the neighbourhood drifts away from
 *    what was rejected, in proportion to how much the user actually said. Saturating rather than
 *    normalising against the most-rejected entry is deliberate — the latter makes the FIRST
 *    rejection in any genre full-strength, because that genre is trivially its own maximum, and a
 *    single thumbs-down would then cut a third of this library by 45%. Mirrors
 *    `RecFeedbackStore.signal` on the device.
 *
 * A row whose songId has no feature row still counts for the song-level exclusion; it just cannot
 * contribute an artist or genre, because nothing here knows what it is.
 */
export function feedbackOf(state, featuresById) {
  const rows = Array.isArray(state.feedback) ? state.feedback : [];
  const latest = new Map();
  for (const e of rows) {
    const prev = latest.get(e.songId);
    // `>=` so two rows stamped the same millisecond resolve to the later-ingested one — the same
    // tiebreak the device applies to its append-ordered log.
    if (!prev || e.atMs >= prev.atMs) latest.set(e.songId, e);
  }
  const rejected = new Set(); const accepted = new Set();
  const rejArtist = new Map(); const rejGenre = new Map(); const accArtist = new Map();
  const bump = (m, k) => { if (k) m.set(k, (m.get(k) || 0) + 1); };
  for (const [songId, e] of latest) {
    const row = featuresById?.get(songId);
    if (e.action === 'rejected') {
      rejected.add(songId);
      bump(rejArtist, row?.a); bump(rejGenre, row?.g);
    } else if (e.action === 'accepted') {
      accepted.add(songId);
      bump(accArtist, row?.a);
    }
  }
  const saturate = (m, saturation) => {
    const out = new Map();
    for (const [k, v] of m) out.set(k, Math.min(1, v / saturation));
    return out;
  };
  return {
    rejected, accepted,
    rejectedArtists: saturate(rejArtist, REJECT_ARTIST_SATURATION),
    rejectedGenres: saturate(rejGenre, REJECT_GENRE_SATURATION),
    acceptedArtists: saturate(accArtist, REJECT_ARTIST_SATURATION),
  };
}

/**
 * The multiplier the feedback applies to a candidate's score. 1.0 = untouched.
 *
 * The two PENALTIES combine with `max`, not a sum: an artist rejected inside a genre that was also
 * rejected is one grievance, not two. Multiplicative and bounded so a rejection can reorder within
 * a tier of comparable candidates and never invert the ranking outright — three thumbs-down on one
 * artist should thin them out, not erase an artist the user has 400 plays of. Mirrors
 * `ZoneEngine.Feedback.multiplier` on the device.
 */
export function feedbackMultiplier(fb, artist, genre) {
  if (!fb) return 1;
  const worst = Math.max(artist ? (fb.rejectedArtists.get(artist) || 0) : 0,
                         genre ? (fb.rejectedGenres.get(genre) || 0) : 0);
  const liked = artist ? (fb.acceptedArtists.get(artist) || 0) : 0;
  const down = worst > 0 ? Math.max(0, 1 - REJECT_PENALTY * Math.min(1, worst)) : 1;
  const up = liked > 0 ? 1 + ACCEPT_BOOST * Math.min(1, liked) : 1;
  return down * up;
}

/**
 * Deterministic For You compute over the profile state + the features doc. Pure.
 *
 * `playCountSeedLimit` — how many of the most-played songs of all time are allowed to SEED. The
 * default (200) shapes taste from the head of the distribution while leaving the rest of a
 * 56k-row baseline available as CANDIDATES (a seed is excluded from its own recommendations, so
 * seeding everything would hide every song the user has ever played). Injectable so a test can
 * drive both sides of that line against a small fixture.
 */
export function scoreForYou(state, featuresById,
                            { nowMs = Date.now(), limit = 50, playCountSeedLimit = 200 } = {}) {
  limit = Math.min(Math.max(Math.trunc(limit) || 50, 1), 200);

  // 1) Seeds: plays in the last 30 days grouped by song, recency-weighted; favorites and puzzle
  //    references add flat weight. Top 50 by weight.
  const weights = new Map();
  for (const p of state.plays) {
    const ageDays = (nowMs - p.atMs) / DAY_MS;
    if (ageDays < 0 || ageDays > 30) continue;
    weights.set(p.songId, (weights.get(p.songId) || 0) + Math.exp(-ageDays / 7));
  }

  // 1b) LIFETIME plays seed too — the signal a 30-day window structurally cannot see.
  //
  // Without this, a user whose Apple library holds a decade of listening gets recommendations
  // built from whatever happened to be on this month, and a user who just installed the app gets
  // NOTHING (no plays in the window ⇒ no seeds ⇒ an empty For You). Their imported baseline is
  // 144k plays of taste; refusing to read it because none of them are recent is the whole reason
  // this signal was added. Weighted well below a fresh play (see PLAYCOUNT_SEED_WEIGHT) so
  // recency still leads, and capped (see `playCountSeedLimit`) so a huge library can't swamp
  // stage 2 — and so the long tail of played songs stays available as candidates.
  const { counts: lifetime, maxN: maxLifetime } = playCountsOf(state);
  const lastPlayedDays = lastPlayedOf(state);
  if (maxLifetime > 0 && playCountSeedLimit > 0) {
    // Rank the seed shortlist by the COMBINED signal, not by raw count. Sorting by `n` alone
    // meant a song played three times last week could never seed while 200 songs untouched since
    // 2015 always did — which is exactly the "played a lot long ago" vs "played once yesterday"
    // conflation this axis exists to undo. The two terms keep their own weights, so a song can
    // qualify on either.
    const seedWeightOf = (songId, n) =>
      PLAYCOUNT_SEED_WEIGHT * playCountSignal(n, maxLifetime)
      + RECENCY_SEED_WEIGHT * recencySignal(lastPlayedDays[songId], nowMs);
    const top = Object.entries(lifetime)
      .map(([songId, n]) => [songId, n, seedWeightOf(songId, n)])
      .sort((a, b) => b[2] - a[2] || (a[0] < b[0] ? -1 : 1))
      .slice(0, playCountSeedLimit);
    for (const [songId, , bonus] of top) {
      if (bonus > 0) weights.set(songId, (weights.get(songId) || 0) + bonus);
    }
  }

  const puzzleSongs = new Set(state.puzzle.map((e) => e.songId).filter(Boolean));
  const fb = feedbackOf(state, featuresById);
  for (const [songId, w] of weights) {
    let bonus = 0;
    if (state.favorites[songId]?.favorited) bonus += 1.0;
    if (puzzleSongs.has(songId)) bonus += 0.5;
    // An explicit thumbs-up is a SEED: "more like this" only means anything if the thing itself
    // shapes the taste profile. Below a favorite (see ACCEPT_SEED_WEIGHT's neighbours above).
    if (fb.accepted.has(songId)) bonus += 0.75;
    if (bonus) weights.set(songId, w + bonus);
  }
  // …and an accepted song the 30-day window never saw still seeds, which is the whole point of a
  // tuning loop that has to work on a library whose median play is 5.8 years old.
  for (const songId of fb.accepted) {
    if (!weights.has(songId)) weights.set(songId, 0.75);
  }
  // A REJECTED song can never seed, whatever else says otherwise — it is the one instruction the
  // user gave explicitly, and letting a favorite or a play count override it would make the
  // button a no-op for exactly the songs it was pressed on.
  for (const songId of fb.rejected) weights.delete(songId);
  const seeds = [...weights.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, 50);
  const seedIds = new Set(seeds.map(([id]) => id));
  if (seeds.length === 0) return { v: 1, generatedAtMs: nowMs, seeds: [], songs: [] };

  // 2) Taste aggregates from the seed feature rows, weighted by w.
  const genreCount = new Map(); const seedGenreN = new Map(); const artistCount = new Map();
  let bpmW = 0; let bpmSum = 0;
  const seedYears = []; const seedYearWeights = [];
  const neighborSet = new Set(); const kwCount = new Map();
  for (const [songId, w] of seeds) {
    const row = featuresById.get(songId);
    if (!row) continue;
    if (row.g) {
      genreCount.set(row.g, (genreCount.get(row.g) || 0) + w);
      seedGenreN.set(row.g, (seedGenreN.get(row.g) || 0) + 1);
    }
    if (row.a) artistCount.set(row.a, (artistCount.get(row.a) || 0) + w);
    if (row.b != null) { bpmW += w; bpmSum += w * row.b; }
    if (row.y != null) { seedYears.push(row.y); seedYearWeights.push(w); }
    for (const c of camelotNeighbors(row.c)) neighborSet.add(c);
    for (const kw of row.s || []) kwCount.set(kw, (kwCount.get(kw) || 0) + w);
  }
  const mu = bpmW > 0 ? bpmSum / bpmW : null;
  // THE SEEDS' ERA — the year-range feature (see the ERA constants): the weighted p15–p85 window
  // of the seed years, not their mean. A listener whose month spans 1992 soul and 2024 rap has a
  // WIDE era, and a mean would claim 2008 — a year they play nothing from.
  const eraWin = eraWindow(seedYears, seedYearWeights);
  // The round neutral an UNDATED candidate scores on the era term — the measured mean fit of the
  // dated candidate pool, mirroring the device's `EraCalibration`. FAIL OPEN: at 99.2% year
  // coverage, scoring the odd untagged song 0 buries it for its tag; a per-candidate denominator
  // would instead reward the missing tag. Round-level, one number, applied identically.
  let eraNeutral = ERA_NEUTRAL_FALLBACK;
  if (eraWin) {
    let s = 0; let n = 0;
    for (const row of featuresById.values()) {
      if (row.y != null) { s += eraFit(row.y, eraWin); n += 1; }
    }
    if (n >= ERA_MIN_NEUTRAL_OBS) eraNeutral = s / n;
  }
  // …and when NO seed is dated the term is unearnable for every candidate: it drops and its
  // weight renormalizes over the live axes (see the SIM_BUDGET constants — the audio-term lesson).
  const eraRenorm = eraWin ? 1 : FORYOU_SIM_BUDGET / (FORYOU_SIM_BUDGET - ERA_TERM_WEIGHT);

  // ── THE SEEDS' SOUND (audio-similarity v2) ──────────────────────────────────────────────────
  // The weighted timbre centroid + spread of the seed set. The seeds already fold in the 👍'd
  // songs (they SEED — stage 1) and exclude the 👎'd ones, so an accepted analysed song shifts
  // this centroid exactly as F10 intended ("a 👍 can carry I like this kind of sound"); the
  // rejected songs' vectors additionally form a NEGATIVE sound, subtracted inside the net fit —
  // the same two-profile shape the device's inDaZone uses for taste/distaste. Fewer than
  // TIMBRE_MIN_VECTORS analysed seeds ⇒ no profile ⇒ the multiplier below drops for the whole
  // round (fail open, and being multiplicative its absence is exactly ranking-neutral).
  const timbrePos = timbreProfile(seeds.map(([songId, w]) => {
    const t = featuresById.get(songId)?.t;
    return t ? { f: t, w } : null;
  }).filter(Boolean));
  const timbreNeg = timbrePos ? timbreProfile([...fb.rejected].map((songId) => {
    const t = featuresById.get(songId)?.t;
    return t ? { f: t, w: 1 } : null;
  }).filter(Boolean), 1) : null;
  // The round neutral an UNANALYSED candidate scores — the measured mean net fit of the analysed
  // candidate pool (the EraCalibration mechanism). At ~14% coverage THIS constant is what keeps
  // the analysed and unanalysed halves of the catalog comparable — the incomparability that
  // deferred this term at 1.75% coverage. Round-level, one number, applied identically.
  let timbreNeutral = TIMBRE_NEUTRAL_FALLBACK;
  if (timbrePos) {
    let s = 0; let n = 0;
    for (const row of featuresById.values()) {
      if (!row.t) continue;
      const f = timbreNetFit(row.t, timbrePos, timbreNeg);
      if (f == null) continue;
      s += f; n += 1;
    }
    if (n >= TIMBRE_MIN_NEUTRAL_OBS) timbreNeutral = s / n;
  }
  const timbreWords = timbrePos ? timbreAdjectives(timbrePos.centroid).join(', ') : '';
  const maxGenre = Math.max(0, ...genreCount.values());
  const top20 = new Set([...kwCount.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, 20).map(([k]) => k));

  // Collection co-membership: every song sharing a user collection with any seed.
  const coMemberIds = new Set(); const coMemberName = new Map();
  for (const col of state.collections?.list || []) {
    if (!col.songIds?.some((id) => seedIds.has(id))) continue;
    for (const id of col.songIds) {
      coMemberIds.add(id);
      if (!coMemberName.has(id)) coMemberName.set(id, col.name);
    }
  }

  // 3) Exclusions: any play in the last 72 h + the seed songs themselves.
  const excluded = new Set(seedIds);
  for (const p of state.plays) if (nowMs - p.atMs < 72 * 60 * 60 * 1000) excluded.add(p.songId);
  // The HARD half of the loop. Unconditional: a rejected song is never recommended again until the
  // user clears the decision.
  for (const songId of fb.rejected) excluded.add(songId);

  // 4) Score every candidate. Each term contributes 0 when its field is absent.
  //
  // ── SIMILARITY GATES, NOVELTY REORDERS ──────────────────────────────────────────────────────
  // `terms` are the SIMILARITY terms only — genre, tempo, key, era, mood, shared crate, artist.
  // The play-derived signals and the novelty term reach the score through a bounded multiplier
  // below, never as another addend, so a candidate can never outrank one whose similarity is more
  // than 1.40× its own. That boundary is what stops "value novelty" from becoming "value noise".
  const artistFam = artistFamiliarityOf(featuresById, lifetime);
  const hasRecencyDates = Object.keys(lastPlayedDays).length > 0;
  const scored = [];
  for (const row of featuresById.values()) {
    if (excluded.has(row.i)) continue;
    const terms = [];
    if (row.g && maxGenre > 0 && genreCount.has(row.g)) {
      terms.push(['genre', 2.0 * (genreCount.get(row.g) / maxGenre),
                  `Same genre as ${seedGenreN.get(row.g) || 1} recent play${(seedGenreN.get(row.g) || 1) === 1 ? '' : 's'}`]);
    }
    if (row.b != null && mu != null) {
      terms.push(['bpm', Math.exp(-((row.b - mu) ** 2) / (2 * 15 * 15)), `BPM near ${Math.round(mu)}`]);
    }
    if (row.c && neighborSet.has(row.c)) {
      terms.push(['camelot', 1.0, `Harmonically compatible key (${row.c})`]);
    }
    if (eraWin) {
      if (row.y != null) {
        terms.push(['year', ERA_TERM_WEIGHT * eraFit(row.y, eraWin),
                    `From your ${Math.round(eraWin.lo)}–${Math.round(eraWin.hi)} era`]);
      } else {
        // Undated candidate, live window ⇒ the round neutral (fail open; see `eraNeutral`).
        terms.push(['year', ERA_TERM_WEIGHT * eraNeutral, 'Era unknown — scored neutrally']);
      }
    }
    if (row.s?.length && top20.size) {
      const overlap = row.s.reduce((n, k) => n + (top20.has(k) ? 1 : 0), 0);
      if (overlap > 0) {
        terms.push(['sentiment', overlap / Math.max(1, Math.min(row.s.length, 5)), 'Similar mood to your recent plays']);
      }
    }
    if (coMemberIds.has(row.i)) {
      terms.push(['collection', 1.5, `In your collection ${coMemberName.get(row.i) || ''} with recent plays`.trim()]);
    }
    if (row.a && (artistCount.get(row.a) || 0) > 0) {
      terms.push(['artist', 0.75, `Artist you've played: ${row.a}`]);
    }
    // SIMILARITY is everything above, and it is what this row had to earn to be here at all.
    // `eraRenorm` is 1 whenever the era term is live; when no seed is dated it redistributes the
    // dead term's weight uniformly over what WAS earnable (ranking-neutral within the round).
    const sim = terms.reduce((s, [, v]) => s + v, 0) * eraRenorm;
    if (sim <= 0) continue;

    // ── THE AUX MIX: novelty · lifetime affinity · recency ──────────────────────────────────
    // Everything here is the user's OWN library, so "you have played this a lot" is still a real
    // signal — it is just no longer allowed to be a third of the discrimination at the head of the
    // ranking while being described as a tiebreak. Novelty outweighs the two play axes 3:1, which
    // is the owner's instruction made arithmetic: the tile has to propose things the ranking is
    // genuinely UNSURE about, or a thumbs-up only ever confirms a play count it already read.
    const capKey = artistFam.keyOf(row.a);
    const lifetimeN = lifetime[row.i] || 0;
    const playSig = playCountSignal(lifetimeN, maxLifetime);
    const rec = recencySignal(lastPlayedDays[row.i], nowMs);
    const nov = capKey ? artistFam.novelty(capKey) : 0;
    const hasNovelty = artistFam.live && !!capKey;
    const aux = auxMix({
      novelty: nov, plays: playSig, recency: rec,
      hasNovelty, hasPlays: maxLifetime > 0, hasRecency: hasRecencyDates,
    });

    // ── THE TIMBRE MULTIPLIER (audio-similarity v2) ─────────────────────────────────────────
    // Bounded exactly like the aux mix: similarity still gates, sound reorders inside a 1.35×
    // band. An unanalysed candidate gets the ROUND-NEUTRAL multiplier and an analysed one is
    // SHRUNK toward that neutral (TIMBRE_PRIOR — the winner's-curse correction), so no candidate
    // is ever structurally buried for lacking a vector (the fairness rule the tests assert on
    // the real catalog).
    let rawTimbreF = null;
    let timbreF = null;
    if (timbrePos) {
      rawTimbreF = row.t ? timbreNetFit(row.t, timbrePos, timbreNeg) : null;
      timbreF = rawTimbreF == null
        ? timbreNeutral
        : (TIMBRE_PRIOR * timbreNeutral + rawTimbreF) / (TIMBRE_PRIOR + 1);
    }
    const timbreMult = timbrePos ? 1 + TIMBRE_GAIN * timbreF : 1;

    // The SOFT half of the feedback loop, applied to the whole score rather than as another term:
    // it must scale what the other signals concluded, never manufacture a rank of its own.
    const score = sim * timbreMult * (1 + NOVELTY_AUX_GAIN * aux) * feedbackMultiplier(fb, row.a, row.g);
    if (score <= 0) continue;

    // EXPLAINABILITY. The aux components are reported alongside the similarity terms at the
    // magnitude they actually contributed, so the top-3 "why" tells the truth about which signal
    // put the row here — including when the honest answer is "you have never played this artist".
    const auxDen = (hasNovelty ? NOVELTY_CANDIDATE_WEIGHT : 0)
      + (maxLifetime > 0 ? PLAYCOUNT_CANDIDATE_WEIGHT : 0)
      + (hasRecencyDates ? RECENCY_CANDIDATE_WEIGHT : 0);
    const share = (w, v) => (auxDen > 0 ? sim * NOVELTY_AUX_GAIN * w * v / auxDen : 0);
    const why = [...terms];
    if (hasNovelty) {
      if (artistFam.isUnknown(capKey)) {
        why.push(['novelty', share(NOVELTY_CANDIDATE_WEIGHT, nov),
                  `An artist you've never played: ${row.a}`]);
      } else if (nov > 0.75) {
        why.push(['novelty', share(NOVELTY_CANDIDATE_WEIGHT, nov),
                  `An artist you rarely play: ${row.a}`]);
      }
    }
    if (lifetimeN > 0) {
      why.push(['plays', share(PLAYCOUNT_CANDIDATE_WEIGHT, playSig),
                `You've played this ${lifetimeN} time${lifetimeN === 1 ? '' : 's'}`]);
    }
    if (rec > 0) {
      why.push(['recency', share(RECENCY_CANDIDATE_WEIGHT, rec), 'You played this recently']);
    }
    // TIMBRE speaks only when it was OBSERVED (the row has a vector — never off the imputed
    // neutral, which would claim a sound nothing measured), the RAW fit is real (≥0.8 — the gate
    // is on the evidence, not the shrunk score), and the adjective table can honestly say
    // something. Reported at the magnitude it actually contributed, like the aux components.
    if (timbrePos && rawTimbreF != null && timbreWords && rawTimbreF >= 0.8) {
      why.push(['timbre', sim * TIMBRE_GAIN * timbreF,
                `Sounds like your recent plays: ${timbreWords}`]);
    }
    const reasons = why.sort((a, b) => b[1] - a[1]).slice(0, 3).map(([, , r]) => r);
    scored.push({ row, score, reasons });
  }

  // 5) Deterministic order + diversity caps (max 2 per artist, 3 per album), then top `limit`.
  //
  // The cap runs AFTER the sort — it is a property of the OUTPUT, so no change to the ranking can
  // defeat it — and on the PRIMARY artist, so a collaboration credit cannot claim a second budget.
  // Measured before that fix: four Drake-credited rows inside a 50-row list capped at 2.
  scored.sort((a, b) => b.score - a.score || (a.row.i < b.row.i ? -1 : 1));
  const perArtist = new Map(); const perAlbum = new Map();
  const out = [];
  for (const { row, score, reasons } of scored) {
    if (out.length >= limit) break;
    const a = artistFam.keyOf(row.a); const al = row.al || '';
    if (a && (perArtist.get(a) || 0) >= 2) continue;
    if (al && (perAlbum.get(al) || 0) >= 3) continue;
    if (a) perArtist.set(a, (perArtist.get(a) || 0) + 1);
    if (al) perAlbum.set(al, (perAlbum.get(al) || 0) + 1);
    out.push({ songId: row.i, name: row.n ?? null, artist: row.a ?? null,
               score: Math.round(score * 100) / 100, reasons });
  }
  return { v: 1, generatedAtMs: nowMs, seeds: [...seedIds], songs: out };
}

// ── Collection suggestions (GET /recs/collections?songId=S) ─────────────────────────────────────

/** Deterministic per-song collection suggestions over the profile state + features doc. Pure. */
export function scoreCollections(state, featuresById, songId, { nowMs = Date.now(), threshold = 0.8 } = {}) {
  const S = featuresById.get(songId);
  if (!S) return { v: 1, songId, suggestions: [] };

  const sNeighbors = camelotNeighbors(S.c);
  const playsOfS = state.plays.filter((p) => p.songId === songId).map((p) => p.atMs);
  const lastActivityByCol = new Map();
  for (const a of state.activity) {
    if (!a.collectionId) continue;
    const cur = lastActivityByCol.get(a.collectionId) || 0;
    if (a.atMs > cur) lastActivityByCol.set(a.collectionId, a.atMs);
  }
  // Puzzle: an "added" event into a collection whose song shares S's genre category.
  const puzzleGenreCols = new Set();
  if (S.g) {
    for (const e of state.puzzle) {
      if (!e.collectionId || !e.songId) continue;
      if (featuresById.get(e.songId)?.g === S.g) puzzleGenreCols.add(e.collectionId);
    }
  }

  // EACH COLLECTION'S ERA (see the ERA constants): the p15–p85 (±2y) window of its own members'
  // years, matched against S's year — "does this song belong to that crate's era", the owner's
  // year-range feature. Pre-passed because the round neutral below needs every window first.
  const eraByCol = new Map();
  if (S.y != null) {
    for (const col of state.collections?.list || []) {
      if (!col.songIds?.length) continue;
      const yrs = col.songIds.slice(0, 200)
        .map((id) => featuresById.get(id)?.y).filter((y) => y != null);
      const w = eraWindow(yrs);
      if (w) eraByCol.set(col.id, w);
    }
  }
  // Live iff S is dated AND at least one collection has a dated member. When live, an UNDATED
  // collection scores the term at the round neutral — the mean fit S earns across the dated
  // collections (the exact quantity being imputed, so ≥1 observation is usable; a user's
  // collections are far too few for a 25-observation floor). When dead, the term drops for every
  // collection and its weight renormalizes over the live axes — with a fixed `threshold` (0.8), a
  // silently unearnable 0.5-weight term would make the bar quietly stricter for an undated song,
  // which is the scoreForYou audio-term mistake this refuses to repeat.
  const eraLive = eraByCol.size > 0;
  let eraNeutralCol = ERA_NEUTRAL_FALLBACK;
  if (eraLive) {
    let s = 0;
    for (const w of eraByCol.values()) s += eraFit(S.y, w);
    eraNeutralCol = s / eraByCol.size;
  }

  // EACH COLLECTION'S SOUND (audio-similarity v2): the centroid+spread profile of its members'
  // timbre vectors (same 200-member sample as the era pass), matched against S's vector — "does
  // this song SOUND like that crate", the term F10 built the corpus for. Same liveness shape as
  // era: live iff S is analysed AND at least one collection clears the 3-vector bar; when live,
  // an unprofiled collection scores the round neutral — the mean fit S earns across the profiled
  // collections (≥1 observation usable, same reasoning as `eraNeutralCol`); when dead, the term
  // drops for every collection and its weight renormalizes (`simRenormCol`).
  const timbreByCol = new Map();
  if (S.t) {
    for (const col of state.collections?.list || []) {
      if (!col.songIds?.length) continue;
      const p = timbreProfile(col.songIds.slice(0, 200)
        .map((id) => featuresById.get(id)?.t).filter(Boolean).map((f) => ({ f, w: 1 })));
      if (p) timbreByCol.set(col.id, p);
    }
  }
  const timbreLiveCol = timbreByCol.size > 0;
  let timbreNeutralCol = TIMBRE_NEUTRAL_FALLBACK;
  if (timbreLiveCol) {
    let s = 0; let n = 0;
    for (const p of timbreByCol.values()) {
      const f = timbreFit(S.t, p);
      if (f != null) { s += f; n += 1; }
    }
    if (n > 0) timbreNeutralCol = s / n;
  }

  // The COMBINED dead-term renormalization — era and timbre each drop independently, and with a
  // fixed absolute `threshold` (0.8) a silently unearnable term makes the bar quietly stricter
  // for the song that cannot earn it, which is the scoreForYou audio-term mistake neither term
  // repeats.
  const deadWeight = (eraLive ? 0 : ERA_TERM_WEIGHT) + (timbreLiveCol ? 0 : TIMBRE_TERM_WEIGHT);
  const simRenormCol = deadWeight > 0
    ? COLLECTIONS_SIM_BUDGET / (COLLECTIONS_SIM_BUDGET - deadWeight) : 1;

  // ── THE INCUMBENT TEST (the owner's 50% newcomer floor) ───────────────────────────────────
  // Is S's artist ALREADY IN this pocket? By CREDIT identity, never raw string: a pocket holding
  // "Dinner Party, Terrace Martin, …" is incumbent for a Terrace Martin song and vice versa —
  // one shared credit is enough. Keys are memoized per credit string (a collection sweep sees
  // the same few thousand credits over and over).
  const sCreditKeys = new Set(creditArtistKeys(S.a || ''));
  const creditKeyCache = new Map();
  const creditKeysOf = (credit) => {
    let k = creditKeyCache.get(credit);
    if (k === undefined) { k = creditArtistKeys(credit); creditKeyCache.set(credit, k); }
    return k;
  };
  const holdsArtist = (col) => {
    if (!sCreditKeys.size) return false;
    for (const id of col.songIds) {
      const a = featuresById.get(id)?.a;
      if (!a) continue;
      if (creditKeysOf(a).some((k) => sCreditKeys.has(k))) return true;
    }
    return false;
  };

  const scored = [];
  for (const col of state.collections?.list || []) {
    // NEVER OFFER A COLLECTION THE SONG IS ALREADY IN, under any of its ids — `includes` alone
    // misses the `_clean`/`_explicit` variant and the `amrec_<storeId>` capture of the same
    // recording, which is how this route came to suggest "add it to the crate it is already in".
    if (!col.songIds?.length || identityHas(identitySet(col.songIds), songId)) continue;
    const sample = col.songIds.slice(0, 200);
    const rows = sample.map((id) => featuresById.get(id)).filter(Boolean);
    const terms = [];

    if (S.g && rows.length) {
      const share = rows.reduce((n, r) => n + (r.g === S.g ? 1 : 0), 0) / rows.length;
      if (share > 0) terms.push(['genre', 2.0 * share, `Mostly ${S.g} like this song`]);
    }
    const bpms = rows.map((r) => r.b).filter((b) => b != null);
    if (S.b != null && bpms.length) {
      const muc = bpms.reduce((a, b) => a + b, 0) / bpms.length;
      const variance = bpms.reduce((a, b) => a + (b - muc) ** 2, 0) / bpms.length;
      const sigma = Math.max(10, Math.sqrt(variance));
      terms.push(['bpm', Math.exp(-((S.b - muc) ** 2) / (2 * sigma * sigma)), `BPM fits (~${Math.round(muc)})`]);
    }
    const camelots = rows.map((r) => r.c).filter(Boolean);
    if (sNeighbors.size && camelots.length) {
      const frac = camelots.reduce((n, c) => n + (sNeighbors.has(c) ? 1 : 0), 0) / camelots.length;
      if (frac > 0) terms.push(['camelot', 0.75 * frac, 'Harmonically compatible keys']);
    }
    if (eraLive) {
      const w = eraByCol.get(col.id);
      if (w) {
        terms.push(['year', ERA_TERM_WEIGHT * eraFit(S.y, w),
                    `Fits this collection's ${Math.round(w.lo)}–${Math.round(w.hi)} era`]);
      } else {
        // Undated collection, live round ⇒ the round neutral (fail open; see `eraNeutralCol`).
        terms.push(['year', ERA_TERM_WEIGHT * eraNeutralCol, 'Era unknown — scored neutrally']);
      }
    }
    if (timbreLiveCol) {
      const p = timbreByCol.get(col.id);
      const f = p ? timbreFit(S.t, p) : null;
      if (f != null) {
        // Shrunk toward the round neutral (TIMBRE_PRIOR), exactly like the For You multiplier —
        // profiled and unprofiled crates face the same absolute threshold, so the same
        // winner's-curse correction applies. The WORDY claim gates on the RAW fit.
        const shrunk = (TIMBRE_PRIOR * timbreNeutralCol + f) / (TIMBRE_PRIOR + 1);
        const words = f >= 0.8 ? timbreAdjectives(p.centroid).join(', ') : '';
        terms.push(['timbre', TIMBRE_TERM_WEIGHT * shrunk,
                    words ? `Sounds like this crate: ${words}`
                          : (f >= 0.8 ? 'Sounds like this crate' : 'Sound weighed against this crate')]);
      } else {
        // Unprofiled collection, live round ⇒ the round neutral (fail open; see
        // `timbreNeutralCol`) — a crate must not lose the song for ITS members being unanalysed.
        terms.push(['timbre', TIMBRE_TERM_WEIGHT * timbreNeutralCol,
                    'Sound unknown — scored neutrally']);
      }
    }
    const withKw = rows.filter((r) => r.s?.length);
    if (S.s?.length && withKw.length) {
      const sSet = new Set(S.s);
      const jac = withKw.reduce((sum, r) => {
        const inter = r.s.reduce((n, k) => n + (sSet.has(k) ? 1 : 0), 0);
        const union = new Set([...r.s, ...S.s]).size;
        return sum + (union ? inter / union : 0);
      }, 0) / withKw.length;
      if (jac > 0) terms.push(['sentiment', 1.0 * jac, 'Similar mood']);
    }
    if (playsOfS.length) {
      const members = new Set(col.songIds);
      let coPlay = 0;
      for (const p of state.plays) {
        if (!members.has(p.songId)) continue;
        if (playsOfS.some((t) => Math.abs(p.atMs - t) <= 30 * 60 * 1000)) coPlay += 1;
      }
      if (coPlay > 0) terms.push(['coplay', 1.25 * Math.min(1, coPlay / 3), 'Often played together']);
    }
    const lastAct = lastActivityByCol.get(col.id);
    if (lastAct) {
      const days = Math.max(0, (nowMs - lastAct) / DAY_MS);
      terms.push(['recency', 0.5 * Math.exp(-days / 14), 'Recently updated']);
    }
    if (puzzleGenreCols.has(col.id)) {
      // The game is SHOWN as "Gem Collector" (its persisted token stays `collectorsPuzzle`).
      // This string renders inside the app's Suggested section, so it only changes on a
      // Lambda deploy — a stale chip after an app ship is cosmetic and self-healing within
      // the client's 15-minute suggestion cache.
      terms.push(['puzzle', 0.5, 'Matches your Gem Collector picks']);
    }

    // `simRenormCol` is 1 whenever both round-level terms are live — see the pre-pass above.
    const score = terms.reduce((s, [, v]) => s + v, 0) * simRenormCol;
    if (score <= 0) continue;
    const reasons = [...terms].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([, , r]) => r);
    scored.push({ id: col.id, kind: col.kind, name: col.name,
                  score: Math.round(score * 100) / 100, reasons,
                  isIncumbent: holdsArtist(col) });
  }
  scored.sort((a, b) => b.score - a.score || (a.id < b.id ? -1 : 1));
  // ── COMPOSE, DON'T RE-SCORE (the owner's 50% newcomer floor) ──────────────────────────────
  // Ranked exactly as before; the final list is then composed so collections that already hold
  // S's artist take at most INCUMBENT_MAX_SHARE of the rows — the other half proposes crates the
  // artist would be NEW to, which is the collection-expanding half of the owner's instruction.
  // Fail open: with no newcomer crates above threshold the list is exactly what it was.
  const eligible = scored.filter((s) => s.score >= threshold);
  const composed = composeIncumbentCap(eligible, { limit: 5 });
  return { v: 1, songId, suggestions: composed.map(({ isIncumbent, ...row }) => {
    // A newcomer row's WHY says so when there is room — below every scored term in precedence,
    // and only when S actually carries an artist to be new (`sCreditKeys` non-empty).
    if (!isIncumbent && sCreditKeys.size && row.reasons.length < 3) {
      return { ...row, reasons: [...row.reasons, 'New artist for this crate'] };
    }
    return row;
  }) };
}

// ── Similar-to-collections (GET /recs/similar?collectionIds=…) ──────────────────────────────────

/**
 * Songs similar to a SET of collections — Gem Collector's cloud booster. Deliberately the same
 * shape as `scoreForYou`'s stages 2–5 so the two stay reviewable side by side, and it returns
 * the EXACT `RecSongsResponse` wire ({v, generatedAtMs, songs}) so the client needs no new type.
 *
 * The client treats an absent route (404), an unreachable service, and a disabled engine
 * identically — it ranks locally — so this can deploy independently of any app ship. Pure.
 */
export function scoreSimilarToCollections(state, featuresById, collectionIds,
                                          { nowMs = Date.now(), limit = 200 } = {}) {
  limit = Math.min(Math.max(Math.trunc(limit) || 200, 1), 500);
  // The same hard exclusion the For You route applies: a thumbs-down is a statement about the
  // SONG, so it holds on every surface that could offer it back.
  const fbSimilar = feedbackOf(state, featuresById);
  const wanted = new Set((collectionIds || []).filter(Boolean));
  const targets = (state.collections?.list || []).filter((c) => wanted.has(c.id));
  const members = new Set();
  for (const c of targets) for (const id of c.songIds || []) members.add(id);
  if (members.size === 0) return { v: 1, generatedAtMs: nowMs, songs: [] };
  // The same membership by IDENTITY rather than by string — see `identityKeys`. `members` itself
  // stays the raw id set: it is also the key the taste aggregates and the co-play term join on,
  // and those must match the features file's own ids exactly.
  const memberKeys = identitySet(members);

  // 1) Taste aggregates over the members' feature rows (unweighted — a crate has no recency).
  const genreCount = new Map(); const seedGenreN = new Map(); const artistCount = new Map();
  let yearN = 0; let yearSum = 0; let bpmN = 0; let bpmSum = 0;
  const neighborSet = new Set(); const kwCount = new Map();
  let resolved = 0;
  for (const id of members) {
    const row = featuresById.get(id);
    if (!row) continue;
    resolved += 1;
    if (row.g) {
      genreCount.set(row.g, (genreCount.get(row.g) || 0) + 1);
      seedGenreN.set(row.g, (seedGenreN.get(row.g) || 0) + 1);
    }
    if (row.a) artistCount.set(row.a, (artistCount.get(row.a) || 0) + 1);
    if (row.y != null) { yearN += 1; yearSum += row.y; }
    if (row.b != null) { bpmN += 1; bpmSum += row.b; }
    for (const c of camelotNeighbors(row.c)) neighborSet.add(c);
    for (const kw of row.s || []) kwCount.set(kw, (kwCount.get(kw) || 0) + 1);
  }
  if (resolved === 0) return { v: 1, generatedAtMs: nowMs, songs: [] };
  const maxGenre = Math.max(0, ...genreCount.values());
  const yearMean = yearN > 0 ? yearSum / yearN : null;
  const mu = bpmN > 0 ? bpmSum / bpmN : null;
  const top20 = new Set([...kwCount.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, 20).map(([k]) => k));

  // 2) Co-membership: songs sharing ANOTHER collection with a member.
  const coMemberIds = new Set(); const coMemberName = new Map();
  for (const col of state.collections?.list || []) {
    if (wanted.has(col.id)) continue;
    if (!col.songIds?.some((id) => members.has(id))) continue;
    for (const id of col.songIds) {
      if (members.has(id)) continue;
      coMemberIds.add(id);
      if (!coMemberName.has(id)) coMemberName.set(id, col.name);
    }
  }

  // 3) Co-play: played within 30 min of a member's play.
  const memberPlayTimes = state.plays.filter((p) => members.has(p.songId)).map((p) => p.atMs);
  const coPlayCount = new Map();
  if (memberPlayTimes.length) {
    memberPlayTimes.sort((a, b) => a - b);
    for (const p of state.plays) {
      if (members.has(p.songId)) continue;
      if (memberPlayTimes.some((t) => Math.abs(p.atMs - t) <= 30 * 60 * 1000)) {
        coPlayCount.set(p.songId, (coPlayCount.get(p.songId) || 0) + 1);
      }
    }
  }

  // 4) Puzzle seed bonus: songs the player already filed INTO these collections.
  const puzzleSongs = new Set(
    state.puzzle.filter((e) => e.collectionId && wanted.has(e.collectionId))
      .map((e) => e.songId).filter(Boolean));

  // 4b) Lifetime plays — a familiarity TIEBREAK here, not a reason. A Gem Collector round is
  //     about what resembles the crate; between two equally-fitting cards, the one the player
  //     actually listens to is the better card.
  //
  // ── DELIBERATELY NOT REBALANCED. DO NOT "FIX" THIS TO MATCH `scoreForYou`. ──────────────────
  // The owner's novelty rebalance covers the two SUGGESTION surfaces — the device's collection
  // tiles and For You. This route feeds GEM COLLECTOR, whose scoreboard history was recorded under
  // these weights and whose ranking is pinned by tests on both sides (`PuzzleSimilarityTests`,
  // `PuzzleSampler.playCountBias` — a user-facing picker that already defaults to `.off`). A
  // novelty term here would move every ranking that game has ever produced to buy it a signal it
  // has no use for: "does this belong in the same crate" is not a question novelty answers.
  // The same reason `PuzzleSimilarity` takes `balance:` as an opt-in and the puzzle passes nil.
  const { counts: lifetime, maxN: maxLifetime } = playCountsOf(state);
  const lastPlayedDays = lastPlayedOf(state);

  const scored = [];
  for (const row of featuresById.values()) {
    // 5) EXCLUDE EXISTING MEMBERS — they are already filed, and a card the player cannot
    //    score is dead weight in a timed game. BY IDENTITY: a `_clean` variant or an
    //    `amrec_<storeId>` capture of a filed song is that song, not a new card.
    if (identityHas(memberKeys, row.i)) continue;
    if (fbSimilar.rejected.has(row.i)) continue;
    const terms = [];
    if (row.g && maxGenre > 0 && genreCount.has(row.g)) {
      const n = seedGenreN.get(row.g) || 1;
      terms.push(['genre', 2.0 * (genreCount.get(row.g) / maxGenre),
                  `Mostly ${row.g} like ${n} song${n === 1 ? '' : 's'} in these collections`]);
    }
    if (row.a && (artistCount.get(row.a) || 0) > 0) {
      terms.push(['artist', 1.5, `Artist already in these collections: ${row.a}`]);
    }
    if (row.y != null && yearMean != null) {
      terms.push(['year', 0.5 * Math.exp(-Math.abs(row.y - yearMean) / 10), `Era fits (~${Math.round(yearMean)})`]);
    }
    if (row.b != null && mu != null) {
      terms.push(['bpm', 0.5 * Math.exp(-((row.b - mu) ** 2) / (2 * 15 * 15)), `BPM fits (~${Math.round(mu)})`]);
    }
    if (row.c && neighborSet.has(row.c)) {
      terms.push(['camelot', 0.5, `Harmonically compatible key (${row.c})`]);
    }
    if (row.s?.length && top20.size) {
      const overlap = row.s.reduce((n, k) => n + (top20.has(k) ? 1 : 0), 0);
      if (overlap > 0) {
        terms.push(['sentiment', overlap / Math.max(1, Math.min(row.s.length, 5)), 'Similar mood']);
      }
    }
    if (coMemberIds.has(row.i)) {
      terms.push(['collection', 1.5, `In your collection ${coMemberName.get(row.i) || ''}`.trim()]);
    }
    const cp = coPlayCount.get(row.i) || 0;
    if (cp > 0) terms.push(['coplay', 1.25 * Math.min(1, cp / 3), 'Often played together']);
    if (puzzleSongs.has(row.i)) terms.push(['puzzle', 0.5, 'Matches your Gem Collector picks']);
    const lifetimeN = lifetime[row.i] || 0;
    if (lifetimeN > 0) {
      terms.push(['plays', PLAYCOUNT_SIMILAR_WEIGHT * playCountSignal(lifetimeN, maxLifetime),
                  `You've played this ${lifetimeN} time${lifetimeN === 1 ? '' : 's'}`]);
    }
    const rec = recencySignal(lastPlayedDays[row.i], nowMs);
    if (rec > 0) {
      terms.push(['recency', RECENCY_SIMILAR_WEIGHT * rec, 'You played this recently']);
    }

    // The SOFT half of the loop here too — a crate's "more like this" should drift away from the
    // artists and genres the user has thumbed down, exactly as For You does.
    const score = terms.reduce((s, [, v]) => s + v, 0)
      * feedbackMultiplier(fbSimilar, row.a, row.g);
    if (score <= 0) continue;
    const reasons = [...terms].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([, , r]) => r);
    scored.push({ row, score, reasons });
  }

  // 6) Deterministic order + the same diversity caps as For You, then top `limit`.
  scored.sort((a, b) => b.score - a.score || (a.row.i < b.row.i ? -1 : 1));
  const perArtist = new Map(); const perAlbum = new Map();
  const out = [];
  for (const { row, score, reasons } of scored) {
    if (out.length >= limit) break;
    const a = row.a || ''; const al = row.al || '';
    if (a && (perArtist.get(a) || 0) >= 2) continue;
    if (al && (perAlbum.get(al) || 0) >= 3) continue;
    if (a) perArtist.set(a, (perArtist.get(a) || 0) + 1);
    if (al) perAlbum.set(al, (perAlbum.get(al) || 0) + 1);
    out.push({ songId: row.i, name: row.n ?? null, artist: row.a ?? null,
               score: Math.round(score * 100) / 100, reasons });
  }
  return { v: 1, generatedAtMs: nowMs, songs: out };
}

// ── HTTP plumbing ───────────────────────────────────────────────────────────────────────────────

function reply(status, obj) {
  return { statusCode: status, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) };
}

function authOf(event) {
  const h = event.headers || {};
  const profile = h['x-pocketdj-profile'] || h['X-PocketDJ-Profile'];
  if (!profile || !PROFILE_RE.test(profile)) return { fail: reply(400, { error: 'bad-request' }) };
  const raw = h.authorization || h.Authorization || '';
  const key = raw.startsWith('Bearer ') ? raw.slice(7).trim() : '';
  if (!key) return { fail: reply(401, { error: 'unauthorized' }) };
  return { profileId: profile, profileHash: sha256(profile), keyHash: sha256(key) };
}

/// Constant-time compare of the presented enrollment secret against `REC_ENROLL_SECRET`.
/// FAIL-CLOSED: an unset/empty env var rejects every enrollment (a redeploy that forgets the
/// variable must not silently re-open the write path). Read per call so tests can flip it.
export function enrollOk(event) {
  const want = process.env.REC_ENROLL_SECRET || '';
  if (!want) return false;
  const h = event.headers || {};
  const got = h['x-pocketdj-enroll'] || h['X-PocketDJ-Enroll'] || '';
  if (typeof got !== 'string' || got.length !== want.length) return false;
  return timingSafeEqual(Buffer.from(got, 'utf8'), Buffer.from(want, 'utf8'));
}

/// Raw request-body size, BEFORE parsing (base64 bodies are 4/3 of their decoded length).
function bodyBytes(event) {
  if (!event.body) return 0;
  return event.isBase64Encoded
    ? Math.floor((event.body.length * 3) / 4)
    : Buffer.byteLength(event.body, 'utf8');
}

function parseBody(event) {
  if (!event.body) return {};
  const text = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body;
  return JSON.parse(text);
}

export async function handler(event) {
  const method = event.requestContext?.http?.method || 'GET';
  const path = (event.rawPath || '/').replace(/\/+$/, '') || '/';
  const qs = event.queryStringParameters || {};

  if (method === 'GET' && path === '/health') {
    return reply(200, { ok: true, service: 'rec-engine', version: 1 });
  }

  // ── WORKER ROUTES (the nightly audio-analysis job) ──────────────────────────────────────────
  // Authenticated by the ENROLLMENT SECRET ALONE, and placed AHEAD of `authOf` because they are
  // deliberately PROFILE-BLIND: the worker is a batch job on the owner's Mac, it holds no bearer
  // key, and it cannot derive the scoped profile id (that is `HMAC(profileId, bearerKey)` and the
  // key never leaves the device). So the queue route hands back OPAQUE PROFILE HASHES and the
  // worker relays them back verbatim — it learns nothing it did not already have the standing to
  // learn by holding the secret, and no profile id is invented, guessed or transmitted.
  //
  // The secret is the same capability token the enrollment path uses, with the same caveat (it
  // ships in the app binary, so it is rotatable rather than secret-forever) and the same
  // fail-closed behaviour: `enrollOk` returns false when REC_ENROLL_SECRET is unset, so a
  // deployment that forgets the variable exposes nothing.
  try {
    if (method === 'GET' && path === '/audio/queue') {
      if (!enrollOk(event)) return reply(403, { error: 'enrollment-required' });
      const hashes = await listProfileHashes();
      const profiles = [];
      for (const p of hashes) {
        const read = await readState(p);
        const ids = Array.isArray(read?.state?.audioQueue) ? read.state.audioQueue : [];
        if (ids.length) profiles.push({ p, songIds: ids });
      }
      return reply(200, { v: 1, timbreVersion: TIMBRE_VERSION, profiles });
    }

    if (method === 'POST' && path === '/audio/features') {
      if (!enrollOk(event)) return reply(403, { error: 'enrollment-required' });
      if (bodyBytes(event) > MAX_BODY_BYTES) return reply(413, { error: 'body-too-large', max: MAX_BODY_BYTES });
      let body;
      try { body = parseBody(event); } catch { return reply(400, { error: 'bad-request' }); }
      const p = typeof body.p === 'string' && /^[0-9a-f]{64}$/.test(body.p) ? body.p : null;
      if (!p) return reply(400, { error: 'bad-request' });

      const { doc, accepted } = mergeAudioFeatures(await readAudio(p), body.features);
      if (accepted) await writeAudio(p, doc);

      // DRAIN THE QUEUE for everything the worker reported on — including ids it reported as
      // UNANALYSABLE (`done`, no vector). A song with no local audio and no way to get any would
      // otherwise sit at the head of the queue forever and every night would retry it first,
      // which is how a resumable job turns into a stuck one.
      const reported = new Set([
        ...(Array.isArray(body.features) ? body.features.map((r) => r?.songId) : []),
        ...(Array.isArray(body.done) ? body.done : []),
      ].filter((s) => typeof s === 'string' && s));
      let drained = 0;
      if (reported.size) {
        for (let attempt = 0; attempt < 3; attempt++) {
          const read = await readState(p);
          if (!read) break;
          const before = Array.isArray(read.state.audioQueue) ? read.state.audioQueue : [];
          const after = before.filter((id) => !reported.has(id));
          drained = before.length - after.length;
          if (!drained) break;
          read.state.audioQueue = after;
          try { await writeState(p, read.state, { ifMatch: read.etag }); } catch (e) {
            if (e instanceof Precondition) continue;   // an /events call raced us — re-read
            throw e;
          }
          break;
        }
      }
      return reply(200, { ok: true, accepted, drained, stored: Object.keys(doc.songs).length });
    }
  } catch (e) {
    const status = e.statusCode && e.statusCode >= 400 && e.statusCode < 600 ? e.statusCode : 502;
    return reply(status, { error: e.message || 'internal' });
  }

  const auth = authOf(event);
  if (auth.fail) return auth.fail;
  const allowRebind = process.env.REC_ALLOW_REBIND === '1';

  try {
    if (method === 'POST' && path === '/events') {
      if (bodyBytes(event) > MAX_BODY_BYTES) {
        return reply(413, { error: 'body-too-large', max: MAX_BODY_BYTES });
      }
      let batch;
      try { batch = parseBody(event); } catch { return reply(400, { error: 'bad-request' }); }
      const total = (batch.plays?.length || 0) + (batch.favorites?.length || 0)
        + (batch.activity?.length || 0) + (batch.puzzle?.length || 0)
        + (batch.feedback?.length || 0);
      if (total > MAX_BATCH_EVENTS) return reply(400, { error: 'batch-too-large', max: MAX_BATCH_EVENTS });

      // Read-merge-write with ETag-conditional puts: on a 412 re-read + re-merge (max 3), then 503
      // (the client keeps its cursors and simply retries next flush — cursors only advance on 2xx).
      for (let attempt = 0; attempt < 3; attempt++) {
        const read = await readState(auth.profileHash);
        const state = read ? read.state : freshState(auth.profileId);
        if (!state.keyHash) {
          // CREATING state for this profile — the enrollment gate (see the header). An
          // already-bound profile never reaches this branch, so a legitimate device that
          // enrolled under an older build keeps uploading with its key alone.
          if (!allowRebind && !enrollOk(event)) return reply(403, { error: 'enrollment-required' });
          // …and the flood cap, for the day the in-binary secret leaks. Counted here and only
          // here: one LIST on the rare request that would create an object, none on the steady
          // upload path, and existing profiles are never re-checked.
          const maxProfiles = defaultMaxProfiles();
          if (!allowRebind && await countProfiles(maxProfiles) >= maxProfiles) {
            return reply(403, { error: 'profile-cap-reached', max: maxProfiles });
          }
          state.keyHash = auth.keyHash;   // trust-on-first-use bind
        } else if (state.keyHash !== auth.keyHash && !allowRebind) {
          return reply(403, { error: 'key-mismatch' });
        } else if (allowRebind) {
          state.keyHash = auth.keyHash;
        }
        const { accepted } = mergeBatch(state, batch);
        try {
          await writeState(auth.profileHash, state, { ifMatch: read?.etag });
        } catch (e) {
          if (e instanceof Precondition) continue;
          throw e;
        }
        return reply(200, {
          ok: true, accepted,
          totals: {
            plays: state.plays.length, activity: state.activity.length,
            puzzle: state.puzzle.length, feedback: (state.feedback || []).length,
            favorites: Object.keys(state.favorites).length,
            collections: state.collections?.list?.length || 0,
            playCounts: Object.keys(state.playCounts?.counts || {}).length,
          },
        });
      }
      return reply(503, { error: 'conflict-retry' });
    }

    if (method === 'GET' && path === '/recs/songs') {
      const read = await readState(auth.profileHash);
      if (!read) return reply(200, { v: 1, generatedAtMs: Date.now(), seeds: [], songs: [] });
      if (read.state.keyHash && read.state.keyHash !== auth.keyHash) return reply(403, { error: 'key-mismatch' });
      const features = await loadFeatures();
      const limit = parseInt(qs.limit || '50', 10) || 50;
      return reply(200, scoreForYou(read.state, features.byId, { limit }));
    }

    if (method === 'GET' && path === '/recs/similar') {
      const ids = String(qs.collectionIds || '').split(',').map((s) => s.trim()).filter(Boolean).slice(0, 3);
      if (!ids.length) return reply(400, { error: 'bad-request' });
      const read = await readState(auth.profileHash);
      if (!read) return reply(200, { v: 1, generatedAtMs: Date.now(), songs: [] });
      if (read.state.keyHash && read.state.keyHash !== auth.keyHash) return reply(403, { error: 'key-mismatch' });
      const features = await loadFeatures();
      const limit = Math.min(parseInt(qs.limit || '200', 10) || 200, 500);
      return reply(200, scoreSimilarToCollections(read.state, features.byId, ids, { limit }));
    }

    if (method === 'GET' && path === '/recs/collections') {
      const songId = qs.songId;
      if (!songId) return reply(400, { error: 'bad-request' });
      const read = await readState(auth.profileHash);
      if (!read) return reply(200, { v: 1, songId, suggestions: [] });
      if (read.state.keyHash && read.state.keyHash !== auth.keyHash) return reply(403, { error: 'key-mismatch' });
      const features = await loadFeatures();
      const threshold = Number(process.env.REC_COLLECTION_THRESHOLD) || 0.8;
      return reply(200, scoreCollections(read.state, features.byId, songId, { threshold }));
    }

    if (method === 'DELETE' && path === '/state') {
      const read = await readState(auth.profileHash);
      if (!read) return reply(200, { deleted: true });
      // Deletion accepts the bound key OR the enrollment secret. That second door is what makes
      // the in-app "Delete cloud data" a REAL recovery from a wedged key (it used to 403 too,
      // so the app's own advice was a dead end); deletion is destructive-only and profile-scoped,
      // and re-binding afterwards still requires the same enrollment secret.
      if (read.state.keyHash && read.state.keyHash !== auth.keyHash
          && !allowRebind && !enrollOk(event)) {
        return reply(403, { error: 'key-mismatch' });
      }
      await deleteState(auth.profileHash);
      return reply(200, { deleted: true });
    }

    return reply(404, { error: 'not-found' });
  } catch (e) {
    const status = e.statusCode && e.statusCode >= 400 && e.statusCode < 600 ? e.statusCode : 502;
    return reply(status, { error: e.message || 'internal' });
  }
}
