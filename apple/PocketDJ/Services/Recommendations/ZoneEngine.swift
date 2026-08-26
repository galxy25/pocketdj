import Foundation

/// The ranking behind the For You tiles: **In Da Zone** (what to play right now, from recent
/// activity) and **collection suggestions** (what to add to a playlist/pocket).
///
/// ── WHY THIS IS PURE, LOCAL, AND OFF THE NETWORK ─────────────────────────────────────────────
/// The cloud rec engine (`RecommendationService`) is OPT-IN and default-OFF, so anything that
/// depends on it is invisible for most launches. These two tiles rank the owner's OWN catalog
/// against his OWN play history, which is entirely on-device data — so they work with the engine
/// off, with no network, and on first launch. `ReleaseFeedService` is the only part of For You
/// that talks to Apple, and it is a different tile ("New").
///
/// Everything here is a static function over value types: no actor, no store, no I/O. That is
/// what lets the whole ranking be unit-tested with a handful of literals, and it keeps the engine
/// callable from a background task (ranking ~96k tracks is not main-actor work).
///
/// ── WHY RECENCY IS EXPONENTIAL, NOT A WINDOW ─────────────────────────────────────────────────
/// "Recent activity" with a hard cutoff makes the feed lurch: the artist you played on day 29 is
/// worth exactly as much as the one you played this morning, and then at midnight it is worth
/// nothing. A half-life decay makes the zone drift the way listening actually does. Seven days is
/// the default: a week ago counts half, a month ago counts about a sixteenth.
///
/// ── WHY PLAY EVENTS AND NOT `Library.xml` ────────────────────────────────────────────────────
/// The library XML's "Play Date UTC" keeps only the LAST play per track, which collapses repeat
/// listening — the exact signal "recent activity" is made of — into one timestamp per song. The
/// per-event log (`PlayHistoryStore.events`) is the only source that preserves it.
enum ZoneEngine {

    // ========================================================================
    // MARK: - Inputs (projections, so the engine never sees a store or a view)
    // ========================================================================

    /// The catalog projection the ranking needs. Built by the caller from `IndexSong` + its
    /// album's genre, so the engine has no opinion about how a genre is resolved.
    struct Track: Hashable, Sendable {
        let songId: String
        /// `IndexArtist.normalize(artist)` — the same key the artist table joins on.
        let artistKey: String
        let artistName: String
        /// Top-tier genre category, or nil when the album carries none.
        let genre: String?
        /// Release year / tempo / Camelot code — the fields families B and C are made of. All
        /// OPTIONAL and all defaulted, because coverage on the real catalog is 99.2% / 10.4% /
        /// 10.4% respectively: a projection that required them would silently drop 90% of the
        /// library. Absent tempo/key is imputed, never zeroed — see `SimilarityFamilies`.
        let year: Int?
        let bpm: Double?
        let camelot: String?
        /// Apple Music catalog store id (`IndexSong.appleMusicId`), when the crawl resolved one.
        ///
        /// NOT a ranking signal — it is here purely for IDENTITY. It is what lets `suggestions`
        /// recognise that the candidate `sng_…` it is about to offer is the SAME RECORDING as the
        /// `amrec_<storeId>` row the listener already filed into this collection (see
        /// `RecMembership`). Absent on most of the catalog and defaulted, so no call site or
        /// fixture has to say anything about it.
        let appleMusicId: String?

        /// The song's title — carried for VERSION identity (`RecVersionIdentity`), which is how a
        /// suggestion is recognised as the Deluxe/Bonus/remix/extended cut of something already in
        /// the crate. Like `appleMusicId` it is NOT a ranking signal.
        ///
        /// STORED RAW, deliberately un-parsed. See `ZoneEngine.versionKeys` for where the parse
        /// happens and why it may not happen here.
        let title: String?

        /// The recording's length in milliseconds (`IndexSong.length`). Like `appleMusicId` and
        /// `title` it is NOT a ranking signal — it is the CORROBORATOR the one-recording-one-row
        /// collapse requires before it fuses two rows on their text (`RecRecordingIdentity`): an
        /// unlabelled live take and the studio cut share an artist and a title and differ only in
        /// how long they run. Optional and defaulted, so no fixture has to say anything about it.
        let lengthMs: Int?

        /// The album's RAW genre label — "Hip-Hop/Rap", "Neo-Soul", "Disco" — as opposed to
        /// `genre`, which is the 16-bucket `Genre.category` the similarity families join on.
        ///
        /// NOT a ranking signal, and deliberately not folded into `genre`: it exists for the two
        /// places that must count VARIETY rather than measure SIMILARITY — the diversity floor
        /// (`RecComposition.Diversity`) and the sound quota's skew caps (`RecSoundAdmit`). Both
        /// numbers the audit measured — 6.47 distinct genres per 25 rows, 29.17% new-genre share
        /// — were measured on raw labels, and a category has so few values that a tile can hold
        /// seven of them while sounding like one record. Absent and defaulted, so the ~37 test
        /// and preview construction sites say nothing about it and every one keeps compiling.
        let genreRaw: String?

        init(songId: String, artistKey: String, artistName: String, genre: String?,
             year: Int? = nil, bpm: Double? = nil, camelot: String? = nil,
             appleMusicId: String? = nil, title: String? = nil, lengthMs: Int? = nil,
             genreRaw: String? = nil) {
            self.songId = songId
            self.artistKey = artistKey
            self.artistName = artistName
            self.genre = genre
            self.year = year
            self.bpm = bpm
            self.camelot = camelot
            self.appleMusicId = appleMusicId
            self.title = title
            self.lengthMs = lengthMs
            self.genreRaw = genreRaw
        }
    }

    /// **THE VERSION PARSE, DONE ONCE.** song id ⇒ its comparable version identity.
    ///
    /// ── WHY THIS IS A SEPARATE PASS AND NOT A FIELD ON `Track` ───────────────────────────────
    /// Two constraints pull in opposite directions and only this shape satisfies both.
    ///
    ///  1. It cannot happen inside `suggestions`, which sweeps the catalog ONCE PER COLLECTION:
    ///     ~96k rows × ~40 crates is ~4M parses per refresh.
    ///  2. It cannot happen in `AppModel.zoneTracks` either, tempting as that is — that projection
    ///     is built ON THE MAIN ACTOR. MEASURED on the owner's real 96k-row catalog: 0.16 s of
    ///     artist keys + 0.23 s of titles = ~0.39 s of main-actor stall added to a projection that
    ///     already does a full-catalog map. This app has already had to move Browse search and the
    ///     catalog load off the main actor for exactly this; adding a new stall there would be
    ///     undoing that lesson to save one function.
    ///
    /// So the parse rides with the RANKING, which already runs `Task.detached`
    /// (`ForYouFeedBuilder.build`, and the on-demand fallback in `ForYouDetailViews`): derived once
    /// per refresh, off the main actor, and handed to every crate.
    ///
    /// The artist keys are memoized because they REPEAT — 96,022 songs share 12,697 artists on the
    /// real catalog, and memoizing that half alone takes it from 0.156 s to 0.037 s.
    static func versionKeys(_ tracks: [Track]) -> [String: RecVersionIdentity.Key] {
        var out: [String: RecVersionIdentity.Key] = [:]
        out.reserveCapacity(tracks.count)
        var artistKeys: [String: String] = [:]
        for t in tracks {
            guard let title = t.title else { continue }
            let ak: String
            if let k = artistKeys[t.artistName] { ak = k }
            else {
                ak = RecVersionIdentity.artistKey(t.artistName)
                artistKeys[t.artistName] = ak
            }
            if let key = RecVersionIdentity.key(title: title, artistKey: ak) { out[t.songId] = key }
        }
        return out
    }

    /// **THE ZONE'S HALF OF THE RECORDING IDENTITY** — `RecRecordingIdentity.identity` for a
    /// catalog row, with the artist half of the version parse memoized in `artistKeys`.
    ///
    /// Memoized for the same reason `versionKeys` memoizes it: the real catalog holds ~12.7k
    /// artists across ~96k rows, and In Da Zone's last-resort fallback pool can be most of the
    /// library. An id the snapshot cannot resolve falls back to ID EQUALITY ON THE BASE ID — the
    /// same fail-open posture every other join in this file takes, and the same answer
    /// `RecRecordingIdentity` gives, because two answers to "is this the same recording" is the
    /// exact failure this file exists to remove.
    ///
    /// Written once and shared by both `interleave` callers — two copies of an identity rule is
    /// how the answers start disagreeing.
    private static func identity(_ id: String, in songsById: [String: IndexSong],
                                 artistKeys: inout [String: String]) -> RecRecordingIdentity.Identity {
        guard let s = songsById[id] else {
            return RecRecordingIdentity.Identity(baseId: SongVariant.baseId(id))
        }
        let ak: String
        if let k = artistKeys[s.artist] { ak = k }
        else {
            ak = RecVersionIdentity.artistKey(s.artist)
            artistKeys[s.artist] = ak
        }
        return RecRecordingIdentity.identity(
            songId: id, appleMusicId: s.appleMusicId,
            version: RecVersionIdentity.key(title: s.name, artistKey: ak),
            lengthMs: s.length)
    }

    /// One play from the append-only history log.
    struct Play: Hashable, Sendable {
        let songId: String
        let playedAtMs: Double

        init(songId: String, playedAtMs: Double) {
            self.songId = songId
            self.playedAtMs = playedAtMs
        }
    }

    /// Every knob in one place so a test can pin them and the call sites don't grow parameters.
    struct Tuning: Sendable {
        /// Days at which a play counts half as much toward the zone.
        var halfLifeDays: Double = 7

        /// ── THE DEFINITION OF "NOT PLAYED RECENTLY" ──────────────────────────────────────────
        /// This ONE constant does two jobs, and that identity is the design rather than an
        /// accident: it is both the window whose plays BUILD the taste profile and the gate that
        /// admits a song to the rediscovery pool. Because it is one number, the two pools are
        /// exactly complementary — every song is either inside the window (FAMILIAR) or outside
        /// it (REDISCOVERY), with no song in both and none in a gap between them. "Not played
        /// recently" therefore means precisely "not part of what defined this zone", which is the
        /// only definition that cannot drift away from the thing it is contrasted with.
        ///
        /// ── WHY THE GATE ALONE CANNOT BE THE FEATURE ─────────────────────────────────────────
        /// On the owner's real library the gate barely filters: the median song was last played
        /// 5.8 years ago and only 485 of 96,021 songs (0.5%) fall inside 30 days, so ANY
        /// short-horizon cutoff — 30 days or this 60 — leaves ~99.5% of the catalog eligible. A
        /// boolean "not in the last 30 days" is thus nearly the whole library and discriminates
        /// nothing. It is kept anyway because it is the CORRECTNESS half — it is what guarantees
        /// pool B never hands back something he is already bumping — but the DISCRIMINATION comes
        /// from two gradients layered on top of it: similarity to the taste profile (the ranking
        /// proper) and `dormancyWeight` below, which prefers the longer-buried of two equally
        /// similar songs. At `PlayRecency`'s 730-day half-life dormancy runs 0.58 (p90 recent)
        /// → 0.87 (median) → 1.0 (never played), i.e. a live gradient across exactly the bulk of
        /// the library where a 30-day cliff scores everything an identical zero.
        var rediscoveryQuietDays: Double = 60

        /// A song played inside this window is EXCLUDED — "what to play next" should not hand
        /// back what is still ringing in your ears.
        var cooldownHours: Double = 6
        /// The owner's cap: at most this many songs by one artist, ACROSS BOTH POOLS.
        var maxPerArtist = 3
        /// Target floor. Honoured unless the per-artist cap or the catalog itself makes it
        /// unreachable — the cap is non-negotiable and therefore outranks this.
        var minSongs = 30
        /// Hard ceiling.
        var maxSongs = 90

        /// ── THE BLEND ────────────────────────────────────────────────────────────────────────
        /// Minimum share of the queue that must come from the REDISCOVERY pool. The owner's words:
        /// the zone "should have at least a 50% mix of songs you havent played recently". A FLOOR,
        /// not a target — when pool A runs dry the share rises above it, and only a catalog that
        /// cannot supply rediscoveries at all pushes it below (see `degradesToFamiliar`).
        var rediscoveryFloor: Double = 0.5

        /// Weight on "you have played this particular song a lot" INSIDE POOL A — the tiebreak
        /// between two equally-hot songs. (Pool B's buried-favourite preference is
        /// `auxFamiliarityWeight` below; the collection tiles' is `suggestionFamiliarityWeight`.
        /// They were one constant and are now three, because they turned out to be three different
        /// decisions: a tiebreak, a feature, and the thing the owner reported.)
        var familiarityWeight: Double = 0.30

        /// How far the auxiliary signals (dormancy · familiarity) may lift a rediscovery
        /// candidate, as a multiplier on its similarity: `sim × (1 + auxGain × aux)`.
        ///
        /// MULTIPLICATIVE, never additive, and that is load-bearing. Added on, these terms could
        /// float a song with no artist/genre/year relationship whatsoever above a genuine match —
        /// the pool would stop being "similar to what you've been bumping" and start being "old
        /// stuff you used to like". As a multiplier the guarantee is exact and testable: a song
        /// can never outrank another whose similarity is more than `1 + auxGain` times its own.
        /// At 0.6 that is a 1.6× band — wide enough to reorder within a tier of comparable
        /// matches, far too narrow to cross tiers.
        var auxGain: Double = 0.6
        /// Relative pull of the two auxiliary signals inside `aux` (they are renormalized over
        /// whichever ones the profile can actually speak, so these are ratios, not a partition).
        ///
        /// bpm/camelot used to be a THIRD aux signal here, capped at a ≤1.6× nudge. It is no
        /// longer: the owner asked for tempo/key to be a first-class similarity FAMILY, not a
        /// tiebreak, so it moved into `SimilarityFamilies` (family C) and reaches the score at
        /// full weight through `balance` below. Leaving a copy here would double-count it.
        var dormancyWeight: Double = 0.40
        var auxFamiliarityWeight: Double = 0.30
        /// ARTIST-level novelty inside pool B's aux — "an artist you don't play" (see `RecNovelty`).
        ///
        /// Deliberately EQUAL to `auxFamiliarityWeight` rather than above it. This is the
        /// REDISCOVERY pool: its stated job is to hand back music he owns and forgot, so
        /// "you used to love this" is a feature here, not the defect the owner reported. Parity
        /// puts the two in honest tension — an unknown artist and a buried favourite compete —
        /// without inverting the pool into a discovery feed.
        ///
        /// Being ARTIST-level is what makes it safe to add here at all: it is constant across a
        /// discography, so it cannot reorder two songs by the same artist and the pinned
        /// `testABuriedFavouriteOutranksANeverPlayedSong` still holds exactly. It only ever
        /// re-decides which ARTIST the pool reaches for next.
        var auxNoveltyWeight: Double = 0.30

        /// ── THE THREE-FAMILY BALANCE (the owner's rebalance) ─────────────────────────────────
        /// ON by default HERE and nowhere else. In Da Zone is a PLAY QUEUE built from a taste
        /// profile — exactly the surface the owner was describing — while Gem Collector passes
        /// nil and keeps the ranking its scoreboard history was recorded under. See
        /// `SimilarityFamilies` for the measured weights and why "evenly" is by weight.
        var balance: SimilarityFamilies.Balance? = .even

        /// ── FEEDBACK ─────────────────────────────────────────────────────────────────────────
        /// How hard a 👎 pushes back. The rejected songs themselves are always removed outright;
        /// this is the strength of the SHAPE they leave behind (their artists, genres, era and
        /// tempo), scored as a second profile and SUBTRACTED: `sim = max(0, positive − w·negative)`.
        ///
        /// 0.5 rather than 1.0 deliberately. At 1.0 a single thumbs-down on a song by an artist
        /// the listener otherwise plays constantly would cancel that artist out of the queue
        /// entirely — "I didn't want THAT song" read as "never play this artist". At 0.5 a
        /// candidate that matches the rejected shape as strongly as it matches the taste profile
        /// still scores half, so a rejection reorders the queue rather than censoring it, and it
        /// takes a consistent pattern of rejections to actually remove a region of the library.
        var rejectionWeight: Double = 0.5

        /// How hard a fully-saturated skip signal can demote a candidate, as a bounded
        /// multiplier: `score × (1 − skipPenaltyWeight × penalty)` with penalty ∈ 0…1 (the
        /// dampened plays-vs-skips ratio — `Feedback.skipPenalties`). 0.35 for the
        /// `rejectionWeight` reason: one signal must never cancel a song. Even a song skipped
        /// EVERY time keeps 65% of its score — skips reorder, they never censor.
        var skipPenaltyWeight: Double = 0.35
        /// How many rejections of one artist (or genre) make the collection-tile penalty FULL
        /// strength. Applies to `suggestions()`, which tallies rejections per artist/genre;
        /// `inDaZone` instead scores similarity to the rejected SET through the same profile
        /// machinery as the positive one, which is coherent at any set size and needs no
        /// saturation constant. Two representations, two mechanisms, one meaning.
        static let rejectionSaturation: Double = 3
        /// A 👍 is evidence of taste even though the song was never played, so accepted songs join
        /// the profile the queue is built FROM at this weight (1.0 = as much as one full-strength
        /// recent play). They do NOT join the familiar pool — the listener has not heard them yet,
        /// which is the whole point — so this only shapes what "similar" means.
        var acceptedSeedWeight: Double = 1.0

        /// ── HARD BOUND ON HOW MANY SONGS REACH THE EXPENSIVE SCORER ──────────────────────────
        /// The queue is at most 90 songs; nothing justifies running the full similarity scorer
        /// over a 96,000-row catalog to choose them. Candidates are shortlisted by a CHEAP
        /// prescore (artist hit · genre hit · dormancy/familiarity — all dictionary lookups) and
        /// only the best `shortlistCap` are scored properly.
        ///
        /// Why a cap and not just the artist/genre gate: `Genre.category` has ~12 buckets, so on
        /// a real library "shares a genre with something I played this month" is most of the
        /// catalog. The gate alone leaves the cost proportional to library size; this makes it
        /// constant.
        ///
        /// 6,000 is ~66× the 90-song ceiling and ~2,000× the per-artist cap, so the final queue
        /// is chosen from a pool orders of magnitude deeper than it needs — the cap cannot
        /// realistically change which songs win, only how many losers get scored. It binds only
        /// above ~6k eligible candidates; below that every candidate is scored exactly as before.
        var shortlistCap = 6_000

        /// ── COLLECTION SUGGESTIONS ONLY ──────────────────────────────────────────────────────
        /// `suggestions()` deliberately does NOT use the two-pool model above. A playlist is a
        /// SET, not a timeline: there is no "recently", so there is nothing for a rediscovery
        /// pool to be complementary to, and dormancy is meaningless as a preference.
        ///
        /// It DOES use `balance` — the same three families, so "not just artist based" is true of
        /// the collection tiles too. The two standalone `artistWeight` / `genreWeight` knobs it
        /// used to carry (1.0 / 0.45 — artist-dominant by a factor of two, and blind to year and
        /// tempo entirely) are gone rather than left as dead defaults: two places to describe
        /// "similar" is exactly how the app ends up with two different answers to it.
        ///
        /// ── THE OWNER'S NOVELTY REBALANCE — THIS IS THE SURFACE HE REPORTED ───────────────────
        /// "It is biasing too much on play count so each tile is recommending multiple Drake
        /// songs." Measured over 40 real collections (`scripts/measure-rec-report.mjs`), the
        /// shipped tiles were: 11.9 distinct artists in 25 rows, an artist taking the full 3 slots
        /// in 40/40 tiles, and **99.1% of picked rows had play history against a 52.2% base rate**
        /// — the tile essentially never proposed anything he had not already played, which is what
        /// made a 👍 redundant.
        ///
        /// The play term used to arrive here as `+ fam × 0.30`, ADDED ON TOP of a family score
        /// whose four terms are normalized to sum to 1.0. That made it 0.30/1.30 = 23% of the
        /// maximum achievable score — a larger weight than the ENTIRE artist family's 0.25 — while
        /// being described as a tiebreak. Measured share of all SEPARATION at the head of the
        /// ranking: artist 42.4% · **play count 32.6%** · year 20.7% · genre 4.3%.
        ///
        /// It is now the same MULTIPLICATIVE, BOUNDED shape In Da Zone's pool B uses, which the
        /// measurement identified as the least-broken surface for exactly this reason.
        ///
        /// How far the aux mix (novelty · lifetime familiarity) may lift a candidate:
        /// `sim × (1 + suggestionAuxGain × aux)`.
        ///
        /// 0.40 is MEASURED, not chosen — and measured over ALL 131 of his real collections rather
        /// than a sample, because the answer turned out to depend on collection size (a big
        /// playlist has more member artists, so the artist term fires more often and known artists
        /// score higher). It is the value at which the never-played share of the picks lands on the
        /// library's own base rate, which is the honest calibration target: a suggestion tile
        /// should reflect what he OWNS, not what he has already worn out.
        ///
        ///     gain    never-played picks   distinct artists/tile   mean similarity (rel.)
        ///     BEFORE (+fam×0.30)  1.2%             11.8                   100%
        ///     0.30               39.7%             13.4                   102%
        ///     0.35               43.8%             14.0                   101%
        ///   **0.40               49.0%             14.6                   100%**  ← base rate 47.8%
        ///     0.45               52.2%             15.0                   100%
        ///
        /// Note the third column: relevance does not go DOWN. The play term was actively FIGHTING
        /// the similarity score — pulling well-played songs over better-matching ones — so bounding
        /// it costs the tile nothing in match quality while taking the never-played share from 1.2%
        /// to the base rate. That is the strongest evidence this was a defect rather than a trade.
        ///
        /// The band is therefore 1.40×, and that is the number the "novelty is not randomness"
        /// guarantee is stated in: nothing can outrank a candidate more than 1.40× more similar.
        var suggestionAuxGain: Double = 0.40
        /// Novelty's pull inside the collection tiles' aux. THREE TIMES familiarity's, which is the
        /// owner's instruction ("value novelty over similarity … to build a second reliable signal
        /// source apart from pure play count") expressed as a ratio. Familiarity is not zero: it is
        /// what still breaks the tie between two equally unknown artists, and dropping it entirely
        /// overshot the base rate to 65%+.
        var suggestionNoveltyWeight: Double = 0.75
        var suggestionFamiliarityWeight: Double = 0.25

        /// ── THE OWNER'S 50% INCUMBENT CAP (collection tiles only) ────────────────────────────
        /// Owner, verbatim: *"cap our for you per collection at max 50% of suggestions for
        /// artists that are already in the pocket, that way we can learn the features of related
        /// artists to make our recommendations more novel and collection expanding vs model
        /// collapse."*
        ///
        /// A COMPOSITION constraint, not a scoring one — the ranking above is untouched, and the
        /// final list is composed by `RecComposition.compose` so INCUMBENT rows (an artist the
        /// collection already holds, by CREDIT identity — see the incumbent set in
        /// `suggestions`) take at most this share, rounding odd counts in the newcomers' favor
        /// and FAILING OPEN from incumbents when the newcomer pool runs dry. Measured before
        /// (scripts/measure-incumbent-share.mjs, his real pockets): 57.9% of all rows incumbent,
        /// 52/86 collections over 50%, 13 pockets at 100%. `≥ 1` disables the floor.
        var suggestionIncumbentMaxShare: Double = 0.5

        /// ── TIMBRE (audio-similarity v2) ─────────────────────────────────────────────────────
        /// How far a candidate's timbre fit to the profile's sound may lift it:
        /// `net × (1 + timbreGain × fit)` — the same BOUNDED MULTIPLIER shape as `auxGain` /
        /// `suggestionAuxGain`, and for the same reason: added on, a timbre term at the bottom of
        /// the admitted similarity range is a multi-fold swing, which turns "this kind of sound"
        /// into noise. As a multiplier the guarantee is exact: nothing can outrank a candidate
        /// more than `1 + timbreGain` (1.35×) more similar on the metadata families.
        ///
        /// 0.35 puts the term's maximum influence between the era sub-term and the genre term —
        /// deliberately below the 1.40× aux band, because timbre's measured separation against
        /// same-genre songs is real but modest (AUC 0.56 — see `SimilarityFamilies`'s timbre
        /// section), and a signal that modest must reorder within tiers, not decide them.
        ///
        /// The FIT ITSELF fails open (`SimilarityFamilies.timbreFit(_:positive:negative:…)`): an
        /// unanalysed candidate scores the round's measured neutral, so at ~14% corpus coverage
        /// the analysed and unanalysed halves of the catalog stay comparable — the exact
        /// incomparability that deferred this term at 1.75% coverage. A profile with fewer than
        /// `SimilarityFamilies.timbreMinVectors` analysed members produces NO profile and the
        /// multiplier drops entirely (ranking-neutral by construction — a multiplicative term
        /// needs no denominator renormalization).
        var timbreGain: Double = 0.35

        /// ── THE SOUND QUOTA (audio-similarity v3) ────────────────────────────────────────────
        /// How much of a collection tile may be seated on AUDIO ALONE — candidates sharing
        /// NEITHER an artist NOR a genre category with the crate, which the admission gate
        /// (`guard a > 0 || g > 0`) rejects outright and which the timbre multiplier therefore
        /// never had a chance to speak about. See `RecSoundAdmit` for the measurement that says
        /// this is where the sound signal actually lives.
        ///
        /// 0.12 of 25 rows is ⌊3⌋ — three rows, and `soundAdmitHardCap` says three is also the
        /// ceiling on a longer list. Small on purpose, and the two constants are BOTH here on
        /// purpose: the share is what keeps a SHORT tile from being mostly guesses (a 9-row
        /// crate seats one), the hard cap is what keeps a LONG one from being flooded. Three is
        /// the largest quota the skew guard can still hold, because its bucket caps admit at most
        /// one row per decade, per raw genre and per artist — a quota of three therefore FORCES
        /// three distinct decades and three distinct genres, while a quota of six would start
        /// scraping the pool for rows those caps have to reject and hand the seats back to the
        /// best-covered corner of the corpus by default.
        ///
        /// `0` disables the quota entirely and the ranking is byte-identical to audio-similarity
        /// v2 — the same posture every term here has taken.
        var soundAdmitMaxShare: Double = 0.12
        var soundAdmitHardCap: Int = 3

        /// ── THE DIVERSITY FLOOR ──────────────────────────────────────────────────────────────
        /// Minimum share of the emitted list that must be DISTINCT RAW GENRES (⌈limit × share⌉),
        /// and how many swaps the floor may spend reaching it. 0.25 of 25 is 7, which is the
        /// distinct-genre count the tile measured WITHOUT the timbre term (7.33 per 25 rows,
        /// against 6.47 with it): the floor's job is to hold the line the sound term was measured
        /// to cost, not to invent variety the ranking never had. `maxSwaps` at ⌊limit / 5⌋ = 5
        /// bounds the disturbance — beyond that the floor would stop being a floor and start
        /// being the ranking.
        ///
        /// `0` on either constant disables the phase; so does a catalog projection that carries
        /// no raw genres at all (every row's `genreRaw` nil ⇒ no swap can ever raise the count ⇒
        /// the walk fails open on its first iteration and the list is exactly today's).
        var suggestionMinRawGenreShare: Double = 0.25
        var suggestionDiversityMaxSwapShare: Double = 0.2

        public init() {}
    }

    // ========================================================================
    // MARK: - The queue
    // ========================================================================

    /// Which pool a pick came from. The queue carries this per song so the blend is an
    /// OBSERVABLE property of the result rather than a claim in a comment — every test about the
    /// 50% floor reads it directly.
    enum Pool: String, Hashable, Sendable {
        /// Surfaced from recent activity: the owner played this inside the zone window.
        case familiar
        /// Owned but dormant, chosen for similarity to what pool A shows he has been bumping.
        case rediscovery
    }

    struct Pick: Hashable, Sendable {
        let songId: String
        let pool: Pool
    }

    /// The listener's 👍 / 👎, projected out of `RecFeedbackStore`.
    ///
    /// A PROJECTION, not the store: this engine is a pure function over value types and must stay
    /// callable off the main actor, so the view layer snapshots the store into this and hands it
    /// over. All three empty ⇒ every ranking below is exactly what it was before feedback existed,
    /// which is what makes the feature safe to add to a shipped ranking.
    ///
    /// ── TWO MECHANISMS, AND THEY ARE NOT THE SAME MECHANISM ──────────────────────────────────
    /// This split is the whole design of the reject feature, so it is worth stating plainly:
    ///
    ///  · `rejected` is TASTE. Global, decaying over years, and it only ever SUBTRACTS score — it
    ///    can never remove a song. "I didn't want that one" is evidence about a region of the
    ///    library, and evidence should shape every list.
    ///  · `suppressed` is SUPPRESSION. The songs the listener thumbed down IN THE LIST BEING
    ///    RANKED, still inside their seven-day tombstone. Scoped and expiring, resolved by the
    ///    caller from `RecFeedbackStore.activeTombstones(scope:)`, because this engine has no idea
    ///    which tile it is building.
    ///
    /// A reject in one crate therefore never silences the song in another crate, in the zone, or
    /// forever — and the shape it leaves behind still teaches every list. The songs in
    /// `suppressed` are dropped from the RANKING and re-injected at the BOTTOM by the view (see
    /// `RecFeedbackStore.rankedIds`), which is what keeps the control that undoes a mis-tap
    /// reachable for exactly as long as the mis-tap lasts.
    struct Feedback: Sendable, Equatable {
        /// songId → decayed weight of a 👍. Joins the taste profile; never the familiar pool.
        var accepted: [String: Double] = [:]
        /// songId → decayed weight of a 👎. Builds the subtracted negative profile. NEVER a filter.
        var rejected: [String: Double] = [:]
        /// Songs tombstoned in THIS list right now. The only thing here that removes a row.
        var suppressed: Set<String> = []
        /// songId → PRE-DAMPENED skip pressure in 0…1 (see `skipPenalties`). Applied as a
        /// bounded DEMOTION multiplier (`× (1 − skipPenaltyWeight × penalty)`) — never a
        /// filter: a heavily-skipped song ranks lower, it is never removed. Empty ⇒ every
        /// ranking is byte-identical to pre-skip-tracking (the struct's standing contract).
        var skipPenalty: [String: Double] = [:]
        var isEmpty: Bool {
            accepted.isEmpty && rejected.isEmpty && suppressed.isEmpty && skipPenalty.isEmpty
        }

        public init(accepted: [String: Double] = [:], rejected: [String: Double] = [:],
                    suppressed: Set<String> = [], skipPenalty: [String: Double] = [:]) {
            self.accepted = accepted
            self.rejected = rejected
            self.suppressed = suppressed
            self.skipPenalty = skipPenalty
        }

        /// The DAMPENED plays-vs-skips ratio — the one formula behind the skip signal.
        ///
        /// `plays` = lifetime playback STARTS (skipped ones included — `notePlayed` fires at
        /// track start), so skips ≤ plays in practice. The `k`-count Laplace prior is the
        /// dampener the owner asked for: ONE skip must never bury a song.
        ///   1 skip / 1 play   → 1/4  = 0.25
        ///   1 skip / 20 plays → 1/23 ≈ 0.043
        ///   10 skips / 10 plays → 10/13 ≈ 0.77
        /// Max demotion = `skipPenaltyWeight` × penalty ≤ 0.35 — a song is NEVER zeroed or
        /// removed, it reorders within its band. Songs with zero skips get no entry at all
        /// (the empty-map ⇒ identical-ranking contract stays cheap to honor).
        static func skipPenalties(plays: [String: Int], skips: [String: Int],
                                  k: Double = 3) -> [String: Double] {
            var out: [String: Double] = [:]
            out.reserveCapacity(skips.count)
            for (id, s) in skips where s > 0 {
                // A skip implies a play start, so the denominator never trusts a plays map
                // that lags the skip count (a fresh device before its baseline lands).
                let p = max(Double(plays[id] ?? 0), Double(s))
                out[id] = min(1, Double(s) / (p + k))
            }
            return out
        }
    }

    struct Queue: Equatable, Sendable {
        var picks: [Pick] = []

        var songIds: [String] { picks.map(\.songId) }
        var isEmpty: Bool { picks.isEmpty }
        var count: Int { picks.count }
        func count(_ pool: Pool) -> Int { picks.reduce(0) { $1.pool == pool ? $0 + 1 : $0 } }
        /// Share of the queue that is rediscovery — the number the owner's floor is about.
        var rediscoveryShare: Double {
            picks.isEmpty ? 0 : Double(count(.rediscovery)) / Double(picks.count)
        }
        /// True when the rediscovery pool could not fill its share and familiar songs took the
        /// slack. Surfaced (not hidden) because it is the honest signal that the library, not the
        /// ranking, is the limit.
        var degradesToFamiliar: Bool { !picks.isEmpty && rediscoveryShare < 0.5 }
    }

    // ========================================================================
    // MARK: - Musical metadata (bpm + camelot)
    // ========================================================================

    /// WHERE THE TEMPO/KEY IMPLEMENTATION LIVES: `SimilarityFamilies`. Tempo/key is family C of the
    /// owner's three-family balance and reaches the score through `PuzzleSimilarity`'s optional
    /// `balance:` parameter, at full weight, for every candidate. There is deliberately no second
    /// copy of the wheel or of the tempo kernel in this file — one implementation, not two that can
    /// drift. `MusicalProfile` is re-exported so call sites and tests can name it without importing
    /// the families type directly.
    ///
    /// It is still deliberately NOT in `PuzzleSimilarity`'s DEFAULT term list. Gem Collector ranks
    /// songs for a COLLECTION — "does this belong in the same crate" — where tempo is irrelevant,
    /// and its scoreboard history was recorded under the shipped weights; In Da Zone ranks them for
    /// a PLAY QUEUE, where a 78-bpm ballad between two 140-bpm tracks is what breaks a zone. So the
    /// signal is opt-in per caller (`Tuning.balance`), on here, nil there.
    typealias MusicalProfile = SimilarityFamilies.MusicalProfile

    // ========================================================================
    // MARK: - In Da Zone
    // ========================================================================

    /// What to play right now: a **blend of two pools**, not a replay of the last week.
    ///
    /// ── THE TWO POOLS ────────────────────────────────────────────────────────────────────────
    ///  • **FAMILIAR** — songs the owner actually played inside `rediscoveryQuietDays`, ranked by
    ///    recency-decayed play weight. This is the zone he is already in.
    ///  • **REDISCOVERY** — songs he OWNS but has not touched in that window, ranked by
    ///    `PuzzleSimilarity` against a taste profile built FROM pool A, then nudged by dormancy,
    ///    buried-favourite familiarity, and tempo/key fit.
    ///
    /// The pools are exactly complementary (see `Tuning.rediscoveryQuietDays`), so every song in
    /// the catalog is a candidate for exactly one of them and nothing falls in a gap.
    ///
    /// ── WHY REDISCOVERY IS AT LEAST HALF ─────────────────────────────────────────────────────
    /// The owner's rule. A queue made only of what he just played is a history tab, not a zone;
    /// the point of the tile is to sit in a mood, and half of sitting in a mood is being reminded
    /// of things you own and forgot. `rediscoveryFloor` is a FLOOR — the share goes UP when pool A
    /// is thin, and only drops below when the library genuinely cannot supply rediscoveries, in
    /// which case the queue degrades by taking more FAMILIAR rather than coming back short.
    ///
    /// ── WHY THIS IS NOT THE "NEW" TILE ───────────────────────────────────────────────────────
    /// Every id returned is a song the owner already has. The New tile is the opposite motion —
    /// releases he does NOT own, off the network. They share no ranking code for that reason.
    ///
    /// - Parameters:
    ///   - songs: the whole candidate catalog (already filtered to what this install can play).
    ///   - genreBySongId: song → `Genre.category`, the same map Gem Collector builds.
    ///   - otherCollections: every collection's membership — the "shared crate" similarity signal.
    ///   - plays: play EVENTS, any order. Not `Library.xml` last-played: that keeps only the last
    ///     play per track and so erases the repeat listening this whole feature is made of.
    ///   - playCount: lifetime plays per song id — familiarity, a different axis from recency.
    ///   - lastPlayedMs: combined (Apple baseline + local) last-played stamps. Needed because the
    ///     event log only knows what was played THROUGH this app: without it, a song he plays
    ///     daily in Music.app would look dormant and get offered back as a "rediscovery".
    ///   - feedback: the listener's 👍/👎 (`RecFeedbackStore`). A rejected song is removed from the
    ///     queue outright AND its shape becomes a second, subtracted profile; an accepted song
    ///     joins the taste profile without joining the familiar pool. Empty ⇒ this function is
    ///     exactly what it was before feedback existed.
    ///   - timbre: song id → 14-axis timbre vector (`TimbreCatalog.vectors()`). Empty ⇒ the
    ///     timbre term is dead and the ranking is byte-identical to pre-v2.
    static func inDaZone(songs: [IndexSong],
                         genreBySongId: [String: String] = [:],
                         otherCollections: [[String]] = [],
                         plays: [Play],
                         playCount: (String) -> Int,
                         lastPlayedMs: [String: Double] = [:],
                         feedback: Feedback = Feedback(),
                         timbre: [String: SimilarityFamilies.TimbreVector] = [:],
                         nowMs: Double,
                         tuning: Tuning = Tuning()) -> Queue {
        guard !songs.isEmpty else { return Queue() }
        let songsById = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let windowMs = tuning.rediscoveryQuietDays * 86_400_000
        let cooldownMs = tuning.cooldownHours * 3_600_000
        let halfLifeMs = tuning.halfLifeDays * 86_400_000

        // ── 1. Recent activity → seed weights ────────────────────────────────────────────────
        // A future-dated play (clock skew, a log restored from a device a few hours ahead) clamps
        // to "now" rather than being dropped: discarding real activity is the worse failure.
        var seedWeight: [String: Double] = [:]
        var onCooldown = Set<String>()
        for p in plays {
            let age = nowMs - p.playedAtMs
            if age < cooldownMs { onCooldown.insert(p.songId) }
            guard age <= windowMs, songsById[p.songId] != nil else { continue }
            seedWeight[p.songId, default: 0] += pow(2.0, -max(0, age) / halfLifeMs)
        }

        // ── 2. The taste profile ─────────────────────────────────────────────────────────────
        // Reusing `PuzzleSimilarity` rather than inventing a fourth similarity scheme: it already
        // computes artist / genre / year / co-membership / lyrics similarity with the
        // PROFILE-level renormalization this codebase deliberately chose (a per-song denominator
        // rewards songs with missing metadata — the sparse-feature bug, and there is a test
        // pinning it). The only generalization it needed was weighted members, since a play log
        // is not a set.
        //
        // `plays: []` is passed deliberately. The co-play term links songs played within 30
        // minutes of a MEMBER play, and every member here is by construction a recent play — so
        // every co-play edge lands on another recent song, i.e. inside pool A and ineligible for
        // pool B. Feeding it would put a term in the denominator that no candidate can ever score,
        // deflating every rediscovery uniformly for nothing.
        //
        // `hasRecency: false` likewise: `wRecency` rewards a candidate for having been played
        // LATELY, which is precisely backwards for a rediscovery pool. Dormancy below is the same
        // fact with the sign the feature actually wants.
        //
        // ACCEPTED songs join the profile the queue is built FROM (a 👍 is taste evidence even
        // though the song was never played) but deliberately NOT `seedWeight` — that map is what
        // partitions the pools, and an accepted-but-unheard song belongs in REDISCOVERY, not in
        // "what you have been bumping".
        var tasteWeight = seedWeight
        for (id, w) in feedback.accepted where songsById[id] != nil {
            tasteWeight[id, default: 0] += w * tuning.acceptedSeedWeight
        }
        var taste = PuzzleSimilarity.profile(targetMemberIds: [Array(tasteWeight.keys)],
                                             songsById: songsById,
                                             genreBySongId: genreBySongId,
                                             otherCollections: otherCollections,
                                             plays: [],
                                             hasRecency: false,
                                             memberWeights: tasteWeight,
                                             balance: tuning.balance,
                                             nowMs: nowMs)
        // ROUND-LEVEL CALIBRATION of the musical term's neutral, measured over the pool that is
        // about to be ranked. One number, one pass, applied identically to every candidate — see
        // `SimilarityFamilies`' missing-metadata rule for why this is not a per-song denominator.
        taste.calibrate(against: songs)
        // ── THE NEGATIVE PROFILE ─────────────────────────────────────────────────────────────
        // Rejections are not just a blocklist. "Not this" is information about a REGION of the
        // library — this artist, this era, this tempo — so it is scored with the SAME machinery
        // as the positive one and subtracted, which is what makes a 👎 tune the engine rather
        // than only hide one row. Built only when there is something to build it from, so a
        // listener who has never rejected anything gets a byte-identical ranking.
        //
        // `otherCollections: []` on purpose: co-membership says "you filed these together", which
        // is a statement about the listener's own crates and cannot be evidence of DISLIKE.
        var distaste: PuzzleSimilarity.TargetProfile? = feedback.rejected.isEmpty ? nil
            : PuzzleSimilarity.profile(targetMemberIds: [Array(feedback.rejected.keys)],
                                       songsById: songsById,
                                       genreBySongId: genreBySongId,
                                       otherCollections: [],
                                       plays: [],
                                       hasRecency: false,
                                       memberWeights: feedback.rejected,
                                       balance: tuning.balance,
                                       nowMs: nowMs)
        // Calibrated against the SAME pool as the positive profile, so the two scores subtract on
        // one scale. Calibrating them separately would make the difference meaningless.
        distaste?.calibrate(against: songs)

        // ── THE TASTE'S SOUND (audio-similarity v2) ──────────────────────────────────────────
        // The weighted timbre centroid of the seed set — recent plays at their recency weight,
        // PLUS the 👍'd songs `tasteWeight` already folded in, so an accepted analysed song
        // shifts the centroid exactly as F10 intended ("a 👍 can carry I like this kind of
        // sound"). The rejected songs' vectors form the negative sound, subtracted inside the
        // fit — the same two-profile shape as `taste`/`distaste`, on the timbre axis. Fewer than
        // `timbreMinVectors` analysed seeds ⇒ no profile ⇒ the multiplier below drops for the
        // whole round (fail open, ranking-neutral — a multiplicative term needs no denominator).
        let timbreProfile = SimilarityFamilies.timbreProfile(
            tasteWeight.compactMap { id, w in timbre[id].map { (vector: $0, weight: w) } })
        let negTimbreProfile = timbreProfile == nil ? nil : SimilarityFamilies.timbreProfile(
            feedback.rejected.compactMap { id, w in timbre[id].map { (vector: $0, weight: w) } },
            minVectors: 1)
        // The round neutral an UNANALYSED candidate scores — measured over the pool about to be
        // ranked, the `MusicalCalibration` mechanism. At ~14% coverage this constant is what
        // keeps a candidate without a vector comparable to one with a poor fit, instead of
        // structurally buried below every analysed row.
        let timbreCal = timbreProfile.map { pos in
            SimilarityFamilies.timbreCalibrate(songs.lazy.map { timbre[$0.id] },
                                               positive: pos, negative: negTimbreProfile,
                                               rejectionWeight: tuning.rejectionWeight)
        }

        // ── 3. Familiarity, log-scaled ───────────────────────────────────────────────────────
        // Play counts are heavy-tailed; a linear term would let one 2,000-play song outweigh
        // every other signal in the ranking.
        //
        // ONE PASS, THREE PRODUCTS. The loop that finds `maxPlays` also folds the per-artist play
        // totals the novelty axis needs and memoizes the primary-artist CAP key, so neither
        // addition costs the ranking a second walk over ~96k rows. The cap key is memoized on the
        // similarity artist key rather than recomputed per song because a catalog that size holds
        // only ~20k distinct artists — the splitter runs once per artist, not once per track.
        var maxPlays = 0
        var capKeyByArtist: [String: String] = [:]
        var artistPlays: [String: Int] = [:]
        for s in songs {
            let n = playCount(s.id)
            maxPlays = max(maxPlays, n)
            let ak = PuzzleSimilarity.artistKey(s.artist)
            let cap: String
            if let k = capKeyByArtist[ak] { cap = k }
            else {
                cap = RecNovelty.primaryArtistKey(s.artist)
                capKeyByArtist[ak] = cap
            }
            // Totals roll up to the PRIMARY artist deliberately: keyed on the raw credit, a
            // "Drake & Future" row would be an artist with almost no plays and therefore score as
            // NOVEL — which would reintroduce exactly the concentration this term exists to break,
            // through the collaboration door.
            if n > 0 { artistPlays[cap, default: 0] += n }
        }
        let famDenom = log2(1 + Double(max(maxPlays, 1)))
        func familiarity(_ id: String) -> Double {
            let n = playCount(id)
            guard n > 0, famDenom > 0, maxPlays > 0 else { return 0 }
            return log2(1 + Double(n)) / famDenom
        }
        // The skip signal's bounded demotion multiplier (1.0 for a never-skipped song — the
        // empty-map contract). Clamped so a malformed penalty can neither zero a song nor lift it.
        func skipFactor(_ id: String) -> Double {
            guard let p = feedback.skipPenalty[id] else { return 1 }
            return 1 - tuning.skipPenaltyWeight * min(1, max(0, p))
        }

        // Which auxiliary signals this run can speak at all — renormalized over exactly those,
        // so a device with no last-played data does not silently deflate every score.
        let hasDormancy = !lastPlayedMs.isEmpty
        let hasFamiliarity = maxPlays > 0
        // ARTIST-level novelty (see `RecNovelty`), from the totals the pass above folded. `isLive`
        // is false on a device with no play counts at all, and then the term leaves the
        // denominator entirely rather than scoring every song an identical 1.0.
        let artistFam = RecNovelty.ArtistFamiliarity(artistPlays: artistPlays)
        let hasNovelty = artistFam.isLive

        // ── 4. Partition + score ─────────────────────────────────────────────────────────────
        var familiarPool: [(id: String, capKey: String, score: Double)] = []
        var rediscoveryPool: [(id: String, capKey: String, score: Double)] = []
        /// Dormant songs that are NOT neighbours of the taste profile. Never used while the real
        /// pools can still fill the queue — only to reach `minSongs`. See the gate below.
        var fallbackPool: [(id: String, capKey: String, score: Double)] = []
        rediscoveryPool.reserveCapacity(min(songs.count, 8192))

        /// Dormancy + buried-favourite familiarity + ARTIST novelty, renormalized over whichever of
        /// the three this run can speak. The similarity-free half of the rediscovery score, used on
        /// its own for the cold-start path and for `fallbackPool`.
        ///
        /// Novelty joins as a THIRD signal rather than replacing familiarity because this pool's
        /// job really is rediscovery — "you used to love this" is the feature here. What it fixes
        /// is the pool's reach: the shipped queue drew 93.3% of its picks from songs with play
        /// history, so it kept circling the artists he already plays. Being artist-level, it can
        /// only ever re-decide which ARTIST the pool reaches for; two songs by one artist stay
        /// ordered by dormancy and lifetime plays exactly as before.
        func auxOnly(_ id: String, _ capKey: String) -> Double {
            var num = 0.0, den = 0.0
            if hasDormancy {
                num += tuning.dormancyWeight
                    * (1 - PlayRecency.score(lastPlayedMs: lastPlayedMs[id], nowMs: nowMs))
                den += tuning.dormancyWeight
            }
            if hasFamiliarity {
                num += tuning.auxFamiliarityWeight * familiarity(id)
                den += tuning.auxFamiliarityWeight
            }
            if hasNovelty {
                num += tuning.auxNoveltyWeight * artistFam.novelty(capKey)
                den += tuning.auxNoveltyWeight
            }
            return den > 0 ? num / den : 0
        }

        // PASS 1 — CHEAP. Partition the catalog and give every rediscovery candidate a prescore
        // built only from dictionary lookups. Nothing here calls `PuzzleSimilarity.score`.
        // Artist outranks genre in the prescore because it outranks it in the real scorer too
        // (0.30 vs 0.25) and because it is the far narrower signal; `aux` (< 1) only ever breaks
        // ties inside a tier, so the shortlist is ordered artist-hits, then genre-hits, then the
        // rest by dormancy/familiarity.
        var prescored: [(idx: Int, capKey: String, pre: Double)] = []
        prescored.reserveCapacity(min(songs.count, 16_384))

        for (idx, song) in songs.enumerated() {
            let id = song.id
            if onCooldown.contains(id) { continue }
            // TOMBSTONED IN THIS LIST ⇒ out of the ranking. Note what this is NOT: it is not
            // `feedback.rejected`, the global taste signal — a song thumbed down in some other
            // crate still ranks normally here, and its shape is handled by `distaste` below. Only
            // the scoped, seven-day tombstone the caller resolved removes a row, and the view
            // re-injects those rows at the BOTTOM so the undo control stays reachable. (Nothing
            // here touches playback — the queue this builds is the NEXT one.)
            if feedback.suppressed.contains(id) { continue }
            // TWO artist keys, and the split is load-bearing. `artist` is the SIMILARITY key — it
            // has to match how the taste profile was built, so it stays the raw credit's key.
            // `cap` is the PRIMARY artist, and it is what the per-artist budget and the novelty
            // axis are keyed on, so neither can be walked around by a collaboration credit.
            let artist = PuzzleSimilarity.artistKey(song.artist)
            let cap = capKeyByArtist[artist] ?? artist

            if let w = seedWeight[id] {
                // FAMILIAR — how hard he has been leaning on this exact song lately, with
                // lifetime plays as the tiebreak between two equally-hot ones. The skip
                // penalty applies HERE too (a recently-skipped song is by definition recent,
                // so this is the pool it lands in): bounded demotion, never removal.
                familiarPool.append((id, cap, (w + familiarity(id) * tuning.familiarityWeight)
                    * skipFactor(id)))
                continue
            }
            // A song played recently OUTSIDE this app (Apple's baseline knows, the event log does
            // not) is not dormant, so it is not a rediscovery — and it is not what "recent
            // activity" surfaced either, so it is not pool A. It simply sits this queue out.
            if let lp = lastPlayedMs[id], nowMs - lp < windowMs { continue }

            // ── CHEAP ADMISSION GATE, BEFORE THE EXPENSIVE SCORER ────────────────────────────
            // `PuzzleSimilarity.score` is ~6 dictionary lookups, an exp() and a keyword set
            // intersection. Running it on all ~96k catalog rows to choose 90 songs would put a
            // heavyweight pass where the old engine had two dictionary lookups — and this app has
            // already paid once for derivations that size sitting near a render path.
            //
            // So candidates must first clear the same admission rule the previous ranking used:
            // SOME real zone signal — the artist, the genre, or a shared crate. Year is
            // deliberately NOT an admitting signal; it is ~99% covered and would admit the entire
            // catalog, which is exactly the case this gate exists to prevent. Everything the gate
            // drops would have scored on the year term alone and could never have reached a
            // 90-song queue anyway, so this costs no ranking quality.
            let genre = genreBySongId[id]
            let artistHit = taste.artistShare[artist] != nil
            let genreHit = genre.map { taste.genreShare[$0] != nil } ?? false
            let related = artistHit || genreHit || taste.coMemberIds.contains(id)
            if !taste.isEmpty && !related {
                // Not a neighbour — but still a dormant song he owns, so it is held as LAST-RESORT
                // filler rather than discarded. A narrow profile (one artist on repeat, in a genre
                // nothing else shares) otherwise yields a 3-song queue: the artist cap allows 3
                // and there is nothing else the gate will admit. Ranked on the auxiliary signals
                // only — no similarity to speak of, and no `musicalFit` either, since tempo/key
                // agreement with a profile this song does not otherwise resemble is noise.
                fallbackPool.append((id, cap, auxOnly(id, cap)))
                continue
            }

            prescored.append((idx, cap,
                              (artistHit ? 2 : 0) + (genreHit ? 1 : 0) + auxOnly(id, cap)))
        }

        // PASS 2 — EXPENSIVE, but only over the shortlist. Everything below this line runs at most
        // `shortlistCap` times regardless of how big the library is.
        prescored.sort {
            $0.pre > $1.pre || ($0.pre == $1.pre && songs[$0.idx].id < songs[$1.idx].id)
        }

        // ── THE SHORTLIST IS ARTIST-DIVERSE, NOT JUST TOP-N ──────────────────────────────────
        // Taking a flat top-N looks right and is quietly wrong: prescores TIE constantly (every
        // song by a played artist scores the same 2 + aux when play counts are uniform), the tie
        // breaks on song id, and song ids cluster by artist — so a flat top-N is one artist's
        // discography, then the next artist's. The selector downstream can only use 3 songs per
        // artist, so such a shortlist spends its whole budget on songs that can never be picked
        // and the rediscovery pool starves. Measured: at a 200-song cap it dropped the buried
        // share to 0.35, straight through the owner's 50% floor.
        //
        // A per-artist quota fixes it for one dictionary lookup per candidate. The quota is 3×
        // the per-artist cap, so every artist keeps enough depth to survive the `sim > 0` filter
        // and still fill its three slots, while no artist can crowd the list.
        let perArtistQuota = max(4, tuning.maxPerArtist * 3)
        var quota: [String: Int] = [:]
        var shortlist: [(idx: Int, capKey: String, pre: Double)] = []
        shortlist.reserveCapacity(min(prescored.count, tuning.shortlistCap))
        for c in prescored {
            if shortlist.count >= tuning.shortlistCap { break }
            let n = quota[c.capKey] ?? 0
            if n >= perArtistQuota { continue }
            quota[c.capKey] = n + 1
            shortlist.append(c)
        }
        prescored = shortlist

        let auxBaseDen = tuning.dormancyWeight * (hasDormancy ? 1 : 0)
                       + tuning.auxFamiliarityWeight * (hasFamiliarity ? 1 : 0)
                       + tuning.auxNoveltyWeight * (hasNovelty ? 1 : 0)
        for c in prescored {
            let song = songs[c.idx]
            let id = song.id
            let sim = taste.isEmpty
                // COLD START: no recent activity ⇒ no profile ⇒ nothing to be similar TO. Rather
                // than score every song a flat zero and fall through to the id tiebreak (which
                // would return the alphabet), similarity goes uniform and the auxiliary signals
                // become the whole ranking — i.e. the owner's most-played, longest-buried songs.
                // Those are still genuinely "not played recently", so the pool label stays honest.
                // This path never calls the expensive scorer at all.
                ? 1.0
                : PuzzleSimilarity.score(song, profile: taste, genre: genreBySongId[id],
                                         cloudRank: 0, recency: 0)
            // SUBTRACT the rejected shape. Same scorer, same profile-level renormalization, so
            // the two numbers are on one scale and the subtraction means something. Floored at 0
            // (never negative) so a heavily-rejected region simply stops competing rather than
            // sorting BELOW songs the profile has no opinion about at all.
            let penalty = distaste.map {
                tuning.rejectionWeight * PuzzleSimilarity.score(song, profile: $0,
                                                               genre: genreBySongId[id],
                                                               cloudRank: 0, recency: 0)
            } ?? 0
            let net = max(0, sim - penalty)
            guard net > 0 else { continue }

            // Dormancy ("the longer buried, the better") + buried-favourite familiarity ("you used
            // to love this" beats "you never played this" — rediscovery, not discovery) + artist
            // novelty (which of the artists he owns has he never actually reached for). Tempo/key
            // is NOT here any more: it is family C of the similarity score itself, at full weight,
            // rather than a ≤1.6× nudge on top of it.
            let aux = auxBaseDen > 0 ? auxOnly(id, c.capKey) : 0
            var lifted = net * (1 + tuning.auxGain * aux)
            // ── THE TIMBRE MULTIPLIER (audio-similarity v2) ──────────────────────────────────
            // Rediscovery only — the FAMILIAR pool is ranked by how hard he has been leaning on
            // each exact song, which is not a similarity question. Bounded at 1.35× like every
            // aux signal: sound reorders within a tier, similarity still decides the tier. An
            // unanalysed candidate gets the round-neutral multiplier — never structurally buried.
            if let timbreProfile, let timbreCal {
                let fit = SimilarityFamilies.timbreFit(timbre[id], positive: timbreProfile,
                                                       negative: negTimbreProfile,
                                                       rejectionWeight: tuning.rejectionWeight,
                                                       calibration: timbreCal)
                lifted *= 1 + tuning.timbreGain * fit
            }
            // Skip demotion — same bounded-multiplier doctrine as every aux signal above:
            // similarity gates, skips reorder within the band, nothing is removed.
            lifted *= skipFactor(id)
            rediscoveryPool.append((id, c.capKey, lifted))
        }

        // Ties break on song id so the tile is stable between renders and tests are not flaky.
        let byScore: ((id: String, capKey: String, score: Double),
                      (id: String, capKey: String, score: Double)) -> Bool = {
            $0.score > $1.score || ($0.score == $1.score && $0.id < $1.id)
        }
        familiarPool.sort(by: byScore)
        rediscoveryPool.sort(by: byScore)
        fallbackPool.sort(by: byScore)

        // ── THE LAST-RESORT POOL STAYS BOUNDED ───────────────────────────────────────────────
        // "Everything below this line runs at most `shortlistCap` times regardless of how big the
        // library is" is the invariant stated at the top of pass 2, and this pool is the one
        // collection that can break it: a NARROW taste profile (one artist on repeat, in a genre
        // nothing else shares) sends every row the admission gate rejects here, which on a 96k-row
        // catalog is most of the library. The walk below only reaches this pool after both real
        // pools are exhausted, takes at most `minSongs` picks from it, and spends them under a
        // per-artist cap — so past the shortlist bound it is unreachable material that the
        // identity pass would nevertheless parse a title for, row by row. Sorted already, so the
        // bound keeps the best of it.
        if fallbackPool.count > tuning.shortlistCap {
            fallbackPool.removeSubrange(tuning.shortlistCap...)
        }

        // ── 5. Size the queue ────────────────────────────────────────────────────────────────
        // Length tracks the BREADTH of the zone, which is the only property of his listening that
        // says how much material there honestly is: `maxPerArtist × distinct recent artists` is
        // "room for every artist you have been playing, up to the cap" — the two owner constraints
        // expressed as one number. A 5-artist binge clamps up to 30 (a 15-song queue is a snack);
        // a wide week clamps down to 90.
        var recentArtists = Set<String>()
        for (id, _) in seedWeight {
            if let s = songsById[id] { recentArtists.insert(PuzzleSimilarity.artistKey(s.artist)) }
        }
        let target = min(tuning.maxSongs,
                         max(tuning.minSongs, tuning.maxPerArtist * recentArtists.count))

        // The identity inputs for the collapse inside `interleave` — one memo for the whole
        // queue, so the version parse's artist half runs once per ARTIST (see `identity(_:in:)`).
        var artistKeyMemo: [String: String] = [:]
        func recordingIdentity(_ id: String) -> RecRecordingIdentity.Identity {
            Self.identity(id, in: songsById, artistKeys: &artistKeyMemo)
        }
        return interleave(familiar: familiarPool, rediscovery: rediscoveryPool,
                          fallback: fallbackPool, target: target, tuning: tuning,
                          identity: recordingIdentity,
                          playable: { RecRecordingIdentity.resolvesToStreamableAudio(
                              appleMusicId: songsById[$0]?.appleMusicId) })
    }

    // ========================================================================
    // MARK: - In Da Zone, ranked ELSEWHERE (the cloud engine)
    // ========================================================================

    /// Shape a ranking this engine did NOT produce — the cloud recommendation engine's ordered
    /// song ids — into an In Da Zone queue that obeys every local rule.
    ///
    /// ── THE DIVISION OF LABOUR ───────────────────────────────────────────────────────────────
    /// The server RANKS; the device SHAPES. Owner, verbatim: *"new and in da zone should use the
    /// recommendation engine if available, only doing on device when not enabled."* That makes the
    /// cloud the source of the ORDER, and it does not make it the source of the tile's contract:
    /// the tile is still "≤3 songs per artist, a blend that is at least half rediscovery, and
    /// nothing the listener thumbed down". The server knows none of those (it does not hold the
    /// scoped tombstones, it caps nothing per artist, and it has no notion of this device's two
    /// pools), so a server list handed straight to the grid would quietly drop all three.
    /// **A server list must never bypass client filtering.**
    ///
    /// So this is the one door a cloud ranking comes through, and it applies, in order:
    ///  1. **RESOLUTION** — an id this install's catalog cannot resolve is dropped. The server
    ///     ranks over a catalog snapshot that can outlive a source being toggled off here.
    ///  2. **SUPPRESSION** — a scoped 7-day tombstone removes the row from the RANKING, exactly as
    ///     it does on the device path. (The view re-injects sunk rows at the bottom, so the undo
    ///     control stays reachable — that is not this function's job.)
    ///  3. **COOLDOWN** — a song played in the last `cooldownHours` is out. The server excludes 72 h
    ///     of the plays IT KNOWS ABOUT, which is a strictly smaller set: a play made on a device
    ///     that has not flushed yet, or while the toggle was off, only exists here.
    ///  4. **POOLS + THE FLOOR + THE CAP** — every surviving row is labelled `.familiar` or
    ///     `.rediscovery` by the same `rediscoveryQuietDays` window the device path uses, and the
    ///     two are interleaved by the SAME `interleave` (so ≥50% rediscovery holds on every
    ///     prefix, and no artist exceeds `maxPerArtist`). The server's relative order is preserved
    ///     WITHIN each pool — it is the ranking, and nothing here re-scores it.
    ///
    /// Empty in ⇒ empty out, and an empty result is the caller's signal to keep its on-device
    /// ranking. That is the whole fallback story: unreachable, unenrolled, disabled and
    /// "answered with nothing usable" all arrive here as the same empty queue.
    ///
    /// - Parameters:
    ///   - songIds: the server's ranking, best first.
    ///   - songs: this install's playable catalog — the resolution + artist source.
    ///   - plays: recent play EVENTS (the cooldown + pool window; same projection `inDaZone` takes).
    ///   - lastPlayedMs: combined Apple + local last-played, so a song played only in Music.app is
    ///     not offered back as a "rediscovery".
    ///   - feedback: the listener's verdicts. Only `suppressed` filters here; the taste halves
    ///     (`accepted` / `rejected`) shaped the ranking that produced `songIds` server-side and
    ///     re-applying them locally would double-count a signal the server already spent.
    static func shapeCloudRanking(songIds: [String],
                                  songs: [IndexSong],
                                  plays: [Play] = [],
                                  lastPlayedMs: [String: Double] = [:],
                                  feedback: Feedback = Feedback(),
                                  nowMs: Double,
                                  tuning: Tuning = Tuning()) -> Queue {
        guard !songIds.isEmpty, !songs.isEmpty else { return Queue() }
        let songsById = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let windowMs = tuning.rediscoveryQuietDays * 86_400_000
        let cooldownMs = tuning.cooldownHours * 3_600_000

        // The two facts the local play log carries that the server's copy may not: what is still
        // ringing in the listener's ears, and what he touched inside the zone window.
        var onCooldown = Set<String>()
        var playedInWindow = Set<String>()
        for p in plays {
            let age = nowMs - p.playedAtMs
            if age < cooldownMs { onCooldown.insert(p.songId) }
            if age >= 0, age <= windowMs { playedInWindow.insert(p.songId) }
        }

        var familiar: [(id: String, capKey: String, score: Double)] = []
        var rediscovery: [(id: String, capKey: String, score: Double)] = []
        var seen = Set<String>()
        var capKeyByArtist: [String: String] = [:]

        for (rank, id) in songIds.enumerated() {
            guard let song = songsById[id], seen.insert(id).inserted else { continue }
            if feedback.suppressed.contains(id) { continue }
            let lastPlayed = lastPlayedMs[id]
            if onCooldown.contains(id) { continue }
            if let lp = lastPlayed, nowMs - lp < cooldownMs { continue }

            // The PRIMARY artist, memoized per credit — the key the per-artist budget is spent
            // against, so a collaboration credit cannot walk around the cap.
            let ak = PuzzleSimilarity.artistKey(song.artist)
            let capKey: String
            if let k = capKeyByArtist[ak] { capKey = k }
            else {
                capKey = RecNovelty.primaryArtistKey(song.artist)
                capKeyByArtist[ak] = capKey
            }

            // The server's order IS the score. Descending, so `interleave`'s pools walk best-first
            // exactly as the locally-ranked ones do.
            let score = Double(songIds.count - rank)
            let recentlyTouched = playedInWindow.contains(id)
                || (lastPlayed.map { nowMs - $0 < windowMs } ?? false)
            if recentlyTouched { familiar.append((id, capKey, score)) }
            else { rediscovery.append((id, capKey, score)) }
        }

        guard !familiar.isEmpty || !rediscovery.isEmpty else { return Queue() }
        // The ceiling, not the breadth-derived target the local path computes: that target is a
        // function of how many artists the SEED SET held, and there is no seed set here — the
        // server did the seeding. The pools are already short (the client asks for ~200 ids), so
        // the honest bound is "as much as the cap and the pools allow, up to the tile's maximum".
        // A SERVER LIST MUST NEVER BYPASS CLIENT FILTERING, and "one recording, one row" is now
        // one of those filters: the server dedups on its own ids and cannot know that two of them
        // name one recording in this install's catalog.
        var artistKeyMemo: [String: String] = [:]
        func recordingIdentity(_ id: String) -> RecRecordingIdentity.Identity {
            Self.identity(id, in: songsById, artistKeys: &artistKeyMemo)
        }
        return interleave(familiar: familiar, rediscovery: rediscovery, fallback: [],
                          target: tuning.maxSongs, tuning: tuning,
                          identity: recordingIdentity,
                          playable: { RecRecordingIdentity.resolvesToStreamableAudio(
                              appleMusicId: songsById[$0]?.appleMusicId) })
    }

    /// Weighted tempo/key shape of a seed set — built from the same fields `PuzzleSimilarity` reads
    /// in balanced mode. Kept for callers that want the profile on its own (and for the tests that
    /// pin the wheel); the ranking above gets tempo/key through family C rather than through this.
    static func musicalProfile(seedWeight: [String: Double],
                               songsById: [String: IndexSong]) -> MusicalProfile {
        SimilarityFamilies.musicalProfile(seedWeight.compactMap { id, w in
            guard let s = songsById[id], s.bpm != nil || s.camelot != nil else { return nil }
            return (bpm: s.bpm, camelot: s.camelot, weight: w)
        })
    }

    /// Alternate the two pools into one queue under a single per-artist budget.
    ///
    /// ── WHY ALTERNATE, AND WHY THE FLOOR IS CHECKED EVERY SLOT ───────────────────────────────
    /// Concatenating would play 45 familiar songs and then 45 rediscoveries, which is two queues
    /// glued together, not a zone. So the pool for each slot is chosen by asking whether taking a
    /// FAMILIAR song here would drop the rediscovery share below `rediscoveryFloor` — a greedy
    /// check, evaluated at every position.
    ///
    /// That is stronger than a fixed 1:1 pattern in two ways that both matter. It makes the floor
    /// hold on every PREFIX, not just on the finished queue — someone who plays the first ten
    /// songs and wanders off still got five rediscoveries, which a back-loaded queue would not
    /// give them. And it derives the pattern from the constant instead of hard-coding one that
    /// happens to match it, so the floor is a real knob rather than a comment.
    ///
    /// At the shipped 0.5 it emits R, F, R, F, … — rediscovery first. That is arithmetic, not
    /// taste: leading with familiar yields ⌊n/2⌋ rediscoveries, which at an odd length like 31 is
    /// 48.4% and misses the floor. Leading with rediscovery yields ⌈n/2⌉ and holds at every length.
    ///
    /// ── WHY CAPPING CANNOT SHORTEN THE QUEUE ─────────────────────────────────────────────────
    /// The cap SKIPS a candidate and keeps scanning that pool rather than stopping — so an artist
    /// hitting their third song costs the queue nothing, it just moves to the next eligible song.
    /// A pool only stops contributing when it is genuinely exhausted, and then the other pool
    /// takes the remaining slots.
    ///
    /// ── ONE RECORDING, ONE ROW ───────────────────────────────────────────────────────────────
    /// THE choke point for both zone surfaces (the on-device ranking and the cloud-shaped one —
    /// they are the only two callers, and neither can reach a queue except through here). The
    /// collapse runs ACROSS the three pools, which is not optional: two ids for one recording can
    /// land in DIFFERENT pools — one played inside the window (familiar), its twin dormant
    /// (rediscovery) — and a per-pool dedup would take both. Ahead of the walk, so a dropped twin
    /// costs the queue nothing: the cursor simply moves to the next eligible song.
    ///
    /// - Parameters:
    ///   - identity: `RecRecordingIdentity.identity` for a pooled id, supplied by the caller
    ///     because only it holds the catalog rows.
    ///   - playable: `RecRecordingIdentity.resolvesToStreamableAudio` for a pooled id.
    private static func interleave(familiar: [(id: String, capKey: String, score: Double)],
                                   rediscovery: [(id: String, capKey: String, score: Double)],
                                   fallback: [(id: String, capKey: String, score: Double)],
                                   target: Int,
                                   tuning: Tuning,
                                   identity: (String) -> RecRecordingIdentity.Identity,
                                   playable: (String) -> Bool) -> Queue {
        // TIERS, not scores, decide a cross-pool twin: a familiar row's score is how hard he has
        // been leaning on that exact song and a rediscovery row's is a similarity, so the two
        // numbers are not on one scale and comparing them would be arithmetic theatre. The pool
        // IS the answer — a recording he has actually played recently is familiar, whichever of
        // its ids the play landed on.
        let pools = [(rows: familiar, tier: 2), (rows: rediscovery, tier: 1), (rows: fallback, tier: 0)]
        let keep = RecRecordingIdentity.keepMask(pools.flatMap { pool in
            pool.rows.map {
                RecRecordingIdentity.Candidate(id: $0.id, identity: identity($0.id),
                                               tier: pool.tier, score: $0.score,
                                               playable: playable($0.id))
            }
        })
        var cut = 0
        func surviving(_ rows: [(id: String, capKey: String, score: Double)])
        -> [(id: String, capKey: String, score: Double)] {
            defer { cut += rows.count }
            return rows.indices.compactMap { keep[cut + $0] ? rows[$0] : nil }
        }
        let familiar = surviving(familiar)
        let rediscovery = surviving(rediscovery)
        let fallback = surviving(fallback)

        var perArtist: [String: Int] = [:]
        var fi = 0, ri = 0
        var picks: [Pick] = []
        var rediscoveryCount = 0

        /// Next candidate in `pool` that is still under the artist budget, advancing the cursor
        /// past everything it rejects. Consuming a rejected candidate is safe because the budget
        /// only ever grows: a song skipped for a capped artist could never become eligible later.
        func take(_ pool: [(id: String, capKey: String, score: Double)],
                  _ cursor: inout Int) -> String? {
            while cursor < pool.count {
                let c = pool[cursor]
                cursor += 1
                if (perArtist[c.capKey] ?? 0) < tuning.maxPerArtist {
                    perArtist[c.capKey, default: 0] += 1
                    return c.id
                }
            }
            return nil
        }

        while picks.count < target {
            // Would this slot, taken as FAMILIAR, put the queue under the floor?
            let wantRediscovery =
                Double(rediscoveryCount) < tuning.rediscoveryFloor * Double(picks.count + 1)
            let first: Pool = wantRediscovery ? .rediscovery : .familiar
            var got = false
            // Try the pool whose turn it is, then the other — that second attempt IS the
            // degradation the owner asked for: a thin rediscovery pool yields MORE familiar
            // songs, never a short queue (and vice versa).
            for pool in [first, first == .rediscovery ? .familiar : .rediscovery] {
                guard let id = pool == .rediscovery ? take(rediscovery, &ri)
                                                    : take(familiar, &fi) else { continue }
                picks.append(Pick(songId: id, pool: pool))
                if pool == .rediscovery { rediscoveryCount += 1 }
                got = true
                break
            }
            // Both pools exhausted — every remaining song is either capped out or gone.
            if !got { break }
        }

        // ── LAST RESORT: reach the floor ────────────────────────────────────────────────────
        // Only runs when the two real pools together could not supply `minSongs`, which in
        // practice means a NARROW taste profile: one artist on repeat in a genre nothing else
        // shares admits ~nothing, and the artist cap then holds the queue to 3. Filling from
        // dormant non-neighbours is the lesser evil — a loosely-related 30-song queue beats a
        // perfectly-related 3-song one, and these are still songs he owns and has not played
        // recently, so the `.rediscovery` label stays true.
        var bi = 0
        while picks.count < tuning.minSongs, let id = take(fallback, &bi) {
            picks.append(Pick(songId: id, pool: .rediscovery))
            rediscoveryCount += 1
        }
        _ = rediscoveryCount

        // Still short ⇒ the catalog itself, or the per-artist cap, is the binding limit. The cap
        // is non-negotiable, so a queue below `minSongs` here is correct rather than a bug: a
        // library with three artists in it cannot produce thirty songs at three per artist.
        return Queue(picks: picks)
    }

    // ========================================================================
    // MARK: - Collection suggestions
    // ========================================================================

    /// Songs worth ADDING to a collection, best first.
    ///
    /// The collection's own membership is the profile — the artists, genres, years and tempo/key
    /// shape already in it, weighted uniformly (a playlist is a SET, not a timeline, so recency
    /// has no meaning here and there is nothing for a rediscovery pool to be complementary to).
    ///
    /// ── THE SAME THREE-FAMILY BALANCE THE ZONE USES ──────────────────────────────────────────
    /// This used to be `artistWeight 1.0 + genreWeight 0.45` — artist-dominant by a factor of two,
    /// and blind to year and tempo entirely. It now scores through `SimilarityFamilies` like every
    /// other recommendation surface, so "not just artist based" is true of the collection tiles as
    /// well, and there is ONE answer in the app to what "similar" means.
    ///
    /// The ADMISSION gate stays artist-or-genre: year alone admits ~99% of the catalog (it is a
    /// smooth gradient that is never quite zero), so admitting on it would turn every collection
    /// into a tile of the whole library ranked by era. Once admitted, all three families score.
    ///
    /// ── THE YEAR TERM IS THE COLLECTION'S ERA, NOT A MEAN ────────────────────────────────────
    /// Owner: *"also factor in year range for recommendation along with genre as a feature, eg
    /// some playlist like 808 & swinging is very new jack swing 88-94 r&b."* The year sub-term
    /// here scores against `SimilarityFamilies.eraWindow` — the p15–p85 (±2y) window of the
    /// members' own years — flat inside the window, decaying outside. A feature, not a filter,
    /// and it fails OPEN in both directions: an undated collection drops the term and
    /// `termWeights` renormalizes; an undated candidate scores the round's measured neutral
    /// (`EraCalibration`), never zero. See the era section of `SimilarityFamilies` for the
    /// measured windows on the real pockets, including why "808 and Swinging" honestly windows
    /// wider than the owner's remembered 88–94.
    ///
    /// The per-artist cap is the same rule the owner set for In Da Zone: no collection tile should
    /// turn into one artist's discography.
    ///
    /// ── NOTHING ALREADY IN THE COLLECTION, UNDER ANY OF ITS IDS ──────────────────────────────
    /// Owner, verbatim: *"don't recommend songs that are already in that collection for adding to
    /// a collection."* The exclusion runs through `RecMembership` rather than `Set(memberSongIds)`
    /// because one recording wears up to three different ids here (catalog · `_clean`/`_explicit`
    /// variant · `amrec_<storeId>` ad-hoc capture), and a raw string set treats them as three
    /// different songs — so the tile offers back exactly what the listener already filed, and the
    /// 👍 that "adds" it does nothing. See `RecMembership` for the identity rule.
    ///
    /// ── NOR A DIFFERENT VERSION OF WHAT IS ALREADY IN IT ─────────────────────────────────────
    /// Owner, verbatim: *"for collection and new recommendations don't recommend albums and songs
    /// we already have but that are a different version (e.g. deluxe or bonus album version,
    /// remixes or extended versions)."* `RecMembership` cannot see that — a Deluxe edition is a
    /// different catalog row with a different id, and comparing ids answers "no, that's new".
    /// `RecVersionIndex` compares the RECORDING (normalized artist + base title) and suppresses a
    /// candidate that differs from a member only by edition or reworking. A live/acoustic cut is
    /// NOT suppressed — see `RecVersionIdentity` for why that line sits where it does.
    ///
    /// This is the BUILD-time half. It cannot be the whole answer: the lists are frozen and
    /// membership moves on every add, so the same filter runs again at READ time over the frozen
    /// ids (`CollectionsStore.suggestionsExcludingMembers`).
    ///
    /// - Parameter versions: `ZoneEngine.versionKeys(tracks)`, derived ONCE by the caller and
    ///   shared across every crate. `nil` ⇒ derive it here, which is right for the single-crate
    ///   callers and ruinous for the multi-crate one — see `versionKeys`.
    /// - Parameter timbre: song id → 14-axis timbre vector (`TimbreCatalog.vectors()`), for the
    ///   members that have been analysed. Empty ⇒ the timbre term is dead everywhere and the
    ///   ranking is byte-identical to what it was before audio-similarity v2 — the same
    ///   default-argument posture every other new input here has taken.
    /// - Parameter packed: `SimilarityFamilies.pack(timbre)`, derived ONCE by the caller and
    ///   shared across every crate — the `versions:` arrangement, for the same reason. The SOUND
    ///   QUOTA's scan has to measure candidates the artist/genre gate rejects, so unlike the
    ///   ranking's timbre multiplier it cannot ride the gate's short-circuit; over ~96k rows ×
    ///   ~40 crates the dictionary form is ~100M string hashes a refresh. `nil` ⇒ pack here,
    ///   which is right for the single-crate callers and ruinous for the multi-crate one.
    static func suggestions(memberSongIds: [String],
                            tracks: [Track],
                            playCount: (String) -> Int,
                            feedback: Feedback = Feedback(),
                            limit: Int = 25,
                            tuning: Tuning = Tuning(),
                            versions: [String: RecVersionIdentity.Key]? = nil,
                            timbre: [String: SimilarityFamilies.TimbreVector] = [:],
                            packed: SimilarityFamilies.PackedCorpus? = nil) -> [String] {
        rank(memberSongIds: memberSongIds, tracks: tracks, playCount: playCount,
             feedback: feedback, limit: limit, tuning: tuning, versions: versions,
             timbre: timbre, packed: packed).ids
    }

    /// One ranking, with the facts about it the captions need.
    ///
    /// `suggestions` and `suggestionsExplained` MUST agree about which rows were sound-admitted —
    /// a badge on a row the ranking did not admit, or a missing badge on one it did, is a caption
    /// that lies about the engine. The explainer used to re-derive the crate's timbre profile
    /// from members alone while the ranking scored against members + 👍, an approximation that
    /// was harmless while timbre only reordered and is not once it ADMITS. So the ranking is
    /// computed ONCE, here, and both faces read the same answer. Nothing downstream re-derives
    /// the admitted set.
    struct Ranking: Sendable, Equatable {
        var ids: [String] = []
        /// Which of `ids` came through the SOUND DOOR rather than the artist/genre gate.
        var soundAdmitted: Set<String> = []
        /// The words this crate's sound can honestly be described in
        /// (`SimilarityFamilies.timbreAdjectives`), for the admitted rows' caption. `nil` when
        /// the crate has no live timbre profile.
        var soundWords: String? = nil
    }

    static func rank(memberSongIds: [String],
                     tracks: [Track],
                     playCount: (String) -> Int,
                     feedback: Feedback = Feedback(),
                     limit: Int = 25,
                     tuning: Tuning = Tuning(),
                     versions: [String: RecVersionIdentity.Key]? = nil,
                     timbre: [String: SimilarityFamilies.TimbreVector] = [:],
                     packed: SimilarityFamilies.PackedCorpus? = nil) -> Ranking {
        let members = Set(memberSongIds)
        guard !members.isEmpty, !tracks.isEmpty else { return Ranking() }
        let trackById = Dictionary(tracks.map { ($0.songId, $0) }, uniquingKeysWith: { a, _ in a })
        // Members resolve their store id through the catalog projection when they ARE in it (the
        // ordinary `sng_` member), which is what makes the ad-hoc join work in both directions.
        let membership = RecMembership(memberIds: memberSongIds,
                                       appleMusicId: { trackById[$0]?.appleMusicId })
        // The VERSION half of "already in here" (feature 6). Built from the members that resolve
        // in the catalog projection — a member the projection cannot place contributes no version
        // identity, which is the same fail-open posture the id join takes.
        let versionKeys = versions ?? Self.versionKeys(tracks)
        let ownedVersions = RecVersionIndex(owned: memberSongIds.compactMap { versionKeys[$0] })
        // ── THE FOURTH IDENTITY: TWO PLAIN `sng_` ROWS FOR ONE RECORDING ─────────────────────
        // `membership` folds the three ID forms and `ownedVersions` folds the EDITIONS — and
        // neither can see the case the Apple Music library actually produces most often: the same
        // recording filed twice under two ordinary catalog ids, byte-identical artist and title,
        // sometimes on the same album (measured: 4,344 such groups on the owner's 96k rows).
        // `ownedVersions.supersedes` is honest about refusing that pair — the signatures are
        // EQUAL, so it is not "a different version" — which is exactly why the ownership question
        // needs the recording key as well. Same key the emit-time collapse below dedups on, so a
        // song owned under one id can never be recommended under another.
        let ownedRecordings = Set(memberSongIds.compactMap {
            RecRecordingIdentity.recordingKey(versionKeys[$0])
        })

        // ── THE INCUMBENT SET (the owner's 50% newcomer floor) ───────────────────────────────
        // Which artists are ALREADY IN this collection — in CREDIT space, never raw strings.
        // `RecVersionIdentity.creditArtistKeys` splits a collaboration credit into every name on
        // it, so "Dinner Party, Terrace Martin, Robert Glasper, 9th Wonder & Kamasi Washington"
        // makes the pocket incumbent for a Terrace Martin candidate AND a collab candidate
        // sharing one credit with the pocket counts as incumbent — the raw-string join misses
        // both directions (that mismatch measured 149 of 161 release-feed misses; see
        // `creditArtistKeys`). Memoized per artist key: a catalog sweep meets ~12.7k distinct
        // artists across ~96k rows, so the splitter runs per ARTIST, not per track. Members the
        // projection cannot place contribute no keys — the same fail-open posture as above.
        var creditKeysByArtist: [String: [String]] = [:]
        func creditKeys(_ artistKey: String, _ artistName: String) -> [String] {
            if let k = creditKeysByArtist[artistKey] { return k }
            let k = RecVersionIdentity.creditArtistKeys(artistName)
            creditKeysByArtist[artistKey] = k
            return k
        }
        var memberCreditKeys: Set<String> = []
        for id in members {
            guard let t = trackById[id] else { continue }
            memberCreditKeys.formUnion(creditKeys(t.artistKey, t.artistName))
        }
        var incumbentByArtist: [String: Bool] = [:]
        func isIncumbent(_ t: Track) -> Bool {
            if let v = incumbentByArtist[t.artistKey] { return v }
            let v = !memberCreditKeys.isEmpty
                && creditKeys(t.artistKey, t.artistName).contains { memberCreditKeys.contains($0) }
            incumbentByArtist[t.artistKey] = v
            return v
        }

        // The profile: the collection's members, plus anything the listener has 👍'd for it (a
        // thumbs-up is a statement about what belongs here even before the add lands).
        var profileIds = members
        profileIds.formUnion(feedback.accepted.keys.filter { trackById[$0] != nil })

        var artists: [String: Double] = [:]
        var genres: [String: Double] = [:]
        var years: [Double] = []
        var musicalMembers: [(bpm: Double?, camelot: String?, weight: Double)] = []
        // The crate's RAW genre labels — what "a genre this collection does not already hold"
        // means to the diversity floor. Raw, not the 15 categories: see `Track.genreRaw`.
        var memberRawGenres: Set<String> = []
        for id in profileIds {
            guard let t = trackById[id] else { continue }
            artists[t.artistKey, default: 0] += 1
            if let rg = RecSoundAdmit.genreBucket(t.genreRaw) { memberRawGenres.insert(rg) }
            if let g = t.genre, !g.isEmpty { genres[g, default: 0] += 1 }
            if let y = t.year { years.append(Double(y)) }
            if t.bpm != nil || t.camelot != nil {
                musicalMembers.append((bpm: t.bpm, camelot: t.camelot, weight: 1))
            }
        }
        guard !artists.isEmpty || !genres.isEmpty else { return Ranking() }
        if let maxA = artists.values.max(), maxA > 0 { for (k, v) in artists { artists[k] = v / maxA } }
        if let maxG = genres.values.max(), maxG > 0 { for (k, v) in genres { genres[k] = v / maxG } }

        // THE COLLECTION'S ERA — the owner's year-range feature ("808 & swinging is very new jack
        // swing 88-94 r&b"): a percentile window over the members' own years, per
        // `SimilarityFamilies.eraWindow`. Replaces the old mean±sigma year fit HERE ONLY — the
        // zone's seed-proximity year term (`PuzzleSimilarity.yearMean`) is a different question
        // ("near what the listener plays", not "inside this crate's era") and keeps its shape.
        let era = SimilarityFamilies.eraWindow(years: years)
        let musical = SimilarityFamilies.musicalProfile(musicalMembers)

        // THE COLLECTION'S SOUND — audio-similarity v2: the member-vector centroid + the crate's
        // own spread (`SimilarityFamilies`'s timbre section: centroid over kNN by measurement,
        // AUC 0.557 vs 0.538 on the real pockets). The 👍 profile add above means an accepted
        // analysed song shifts this centroid too — F10's stated purpose ("a 👍 can carry I like
        // this kind of sound"). Fewer than `timbreMinVectors` analysed members ⇒ nil ⇒ the
        // multiplier below drops for the whole round (fail open, ranking-neutral).
        let timbreProfile = SimilarityFamilies.timbreProfile(
            profileIds.compactMap { id in timbre[id].map { (vector: $0, weight: 1.0) } })
        // …and the rejected sound, subtracted inside the fit — one 👎 on an analysed song is
        // already a sound to drift from, hence `minVectors: 1` (every verdict is deliberate).
        let negTimbreProfile = timbreProfile == nil ? nil : SimilarityFamilies.timbreProfile(
            feedback.rejected.compactMap { id, w in timbre[id].map { (vector: $0, weight: w) } },
            minVectors: 1)

        // ROUND-level renormalization: a collection whose members carry no year at all, or no
        // tempo/key at all, simply loses that family — the weight redistributes over the ones it
        // CAN speak instead of every candidate scoring an identical zero on a dead term.
        let terms = SimilarityFamilies.termWeights(tuning.balance ?? .even,
                                                   hasGenre: !genres.isEmpty,
                                                   hasYear: era != nil,
                                                   hasMusical: !musical.isEmpty,
                                                   scaledTo: 1.0)
        // …and the same ROUND-level neutral the zone uses, measured over the candidate pool this
        // tile is actually drawn from rather than baked in as a constant.
        let musicalCal = SimilarityFamilies.calibrate(
            tracks.lazy.map { (bpm: $0.bpm, camelot: $0.camelot) }, profile: musical)
        // The era term's round neutral — what an UNDATED candidate scores. Fail open, same
        // mechanism as `musicalCal`: at 99.2% year coverage a zero here would bury the odd
        // untagged song for its tag, not its fit.
        let eraCal = era.map {
            SimilarityFamilies.eraCalibrate(tracks.lazy.map { $0.year.map(Double.init) }, window: $0)
        }
        // …and the timbre term's, measured over the same candidate pool. At ~14% coverage this is
        // the constant that keeps the analysed and unanalysed halves of the catalog COMPARABLE —
        // an unanalysed candidate scores the mean of its analysed competitors, never zero.
        let timbreCal = timbreProfile.map { pos in
            SimilarityFamilies.timbreCalibrate(tracks.lazy.map { timbre[$0.songId] },
                                               positive: pos, negative: negTimbreProfile,
                                               rejectionWeight: tuning.rejectionWeight)
        }

        // ── THE SOUND DOOR'S PRECONDITIONS, SETTLED ONCE PER CRATE ───────────────────────────
        // Evaluated BEFORE the candidate loop, deliberately: most crates fail here (too few
        // vectors, too little of the crate analysed, a spread as wide as random) and a crate that
        // fails pays nothing at all — no packing, no distances, not one extra branch taken in the
        // 96k-row sweep beyond the one `admitEligible` test the compiler hoists into a constant.
        // See `RecSoundAdmit` for what each bar is and the measurement behind it.
        let admitQuota = min(max(0, tuning.soundAdmitHardCap),
                             max(0, Int((Double(limit) * tuning.soundAdmitMaxShare).rounded(.down))))
        let admitEligible = admitQuota > 0
            && SimilarityFamilies.timbreProfileAdmits(timbreProfile, profileSize: profileIds.count)
        // Packed ONLY when the door is open — the whole point of the precondition order.
        let packedCorpus: SimilarityFamilies.PackedCorpus? = admitEligible
            ? (packed ?? SimilarityFamilies.pack(timbre)) : nil
        let packedCentroid = admitEligible ? timbreProfile.map { SimilarityFamilies.pack($0.centroid) } : nil
        let packedNegCentroid = admitEligible ? negTimbreProfile.map { SimilarityFamilies.pack($0.centroid) } : nil
        let admitRadius = timbreProfile.map { SimilarityFamilies.soundAdmitRadius(spread: $0.spread) } ?? 0
        var admitPool: [RecSoundAdmit.Candidate] = []

        // ONE PASS over `tracks`: the play-count ceiling, the primary-artist CAP key (memoized per
        // artist, not per track), and the per-artist play totals the novelty axis is built from.
        // No new input reaches this function and no call site changes — the artist totals are
        // derivable from the play-count lookup the caller already supplies.
        //
        // The totals roll up to the PRIMARY artist deliberately. Keyed on the raw credit, a
        // "Drake & Future" row would look like an artist with almost no plays and therefore score
        // as NOVEL, which would let the concentration back in through the collaboration door.
        var maxPlays = 0
        var capKeyByArtist: [String: String] = [:]
        var artistPlays: [String: Int] = [:]
        for t in tracks {
            let n = playCount(t.songId)
            maxPlays = max(maxPlays, n)
            let cap: String
            if let k = capKeyByArtist[t.artistKey] { cap = k }
            else {
                cap = RecNovelty.primaryArtistKey(t.artistName)
                capKeyByArtist[t.artistKey] = cap
            }
            if n > 0 { artistPlays[cap, default: 0] += n }
        }
        let famDenom = log2(1 + Double(max(maxPlays, 1)))
        // ARTIST-level novelty — see `RecNovelty` for why the artist and not the song is the
        // informative axis, and why song-level novelty is algebraically the play term over again.
        let artistFam = RecNovelty.ArtistFamiliarity(artistPlays: artistPlays)

        // The rejected shape, subtracted — same construction as the zone's negative profile, so a
        // 👎 on a collection tile teaches that tile rather than only hiding one row.
        var negArtists: [String: Double] = [:]
        var negGenres: [String: Double] = [:]
        for (id, w) in feedback.rejected {
            guard let t = trackById[id] else { continue }
            negArtists[t.artistKey, default: 0] += w
            if let g = t.genre, !g.isEmpty { negGenres[g, default: 0] += w }
        }
        // SATURATION, not max-normalisation. Dividing by the largest observed rejection weight —
        // the obvious move — makes every penalty full strength whenever there is a single rejected
        // artist, which is the common case: one thumbs-down would then hit exactly as hard as ten,
        // and the age decay would cancel out of the ratio and do nothing at all. Saturating keeps
        // both properties real. Same constant, same reasoning as the server's FEEDBACK_SATURATION.
        for (k, v) in negArtists { negArtists[k] = min(1, v / Tuning.rejectionSaturation) }
        for (k, v) in negGenres { negGenres[k] = min(1, v / Tuning.rejectionSaturation) }

        var scored: [(id: String, artist: String, capKey: String, score: Double,
                      isIncumbent: Bool, rawGenre: String?, isNewGenre: Bool)] = []
        // `membership.contains`, NOT `members.contains` — a variant id or an ad-hoc capture of a
        // song already in here is the same song, and offering it is the defect this filter exists
        // to prevent.
        for t in tracks where !membership.contains(t.songId, appleMusicId: t.appleMusicId) {
            // ALREADY IN HERE UNDER ANOTHER CATALOG ID — same artist, same title, different
            // `sng_`. Asked HERE rather than through `membership` (which also knows this key)
            // because this `RecMembership` is built WITHOUT the `titleArtist` lookup — the
            // engine has the parse already, in `versionKeys`, and handing the same work to the
            // membership set would build one recording key per candidate TWICE over a sweep of
            // ~96k rows per crate. Skipped entirely on a crate whose members carry no text
            // identity.
            if !ownedRecordings.isEmpty,
               let rk = RecRecordingIdentity.recordingKey(versionKeys[t.songId]),
               ownedRecordings.contains(rk) { continue }
            // A DIFFERENT VERSION of something already filed here — the deluxe/bonus/remix/
            // extended case the ids cannot see. Cheap: one dictionary lookup against a pre-parsed
            // key, and skipped entirely on a crate whose members carry no version identity.
            if !ownedVersions.isEmpty, let v = versionKeys[t.songId],
               ownedVersions.supersedes(v) { continue }
            // Tombstoned IN THIS TILE ⇒ out of the ranking (the view re-injects it at the bottom).
            // Scoped and expiring — a 👎 given on another tile does not remove the row here; its
            // shape reaches the score through `negArtists`/`negGenres` below. See `inDaZone`.
            if feedback.suppressed.contains(t.songId) { continue }
            let a = artists[t.artistKey] ?? 0
            let g = t.genre.flatMap { genres[$0] } ?? 0
            // ── THE SOUND DOOR — the ONLY way past the artist/genre gate ─────────────────────
            // A candidate sharing neither an artist nor a genre category with the crate has no
            // metadata score to compute and never enters `scored`; it can only ever be SEATED
            // by the quota, and only if it is measurably inside the crate's own sound. This is
            // the `else` branch of the gate rather than a second sweep on purpose: the loop is
            // ~96k rows × ~40 crates, and a second pass would double the most expensive thing
            // For You does.
            if a <= 0 && g <= 0 {
                guard admitEligible, !isIncumbent(t),
                      let v = packedCorpus?[t.songId], let centroid = packedCentroid,
                      let d = SimilarityFamilies.timbreDistance(v, centroid),
                      // A MARGIN, in the instrument's own units — not merely "has a vector".
                      // The candidate must sit half a noise-floor INSIDE the crate's own radius,
                      // which on a typical crate (spread ~0.17) means d ≤ 0.11 against a
                      // random-pair median of ~0.22. Being analysed is not a qualification.
                      d <= admitRadius else { continue }
                // A 👎'd SOUND NEVER ADMITS. The row is inside the radius, so its positive fit is
                // 1.0 by construction and the rejected profile is the only thing left that can
                // disqualify it — the same subtract-the-negative shape the multiplier uses,
                // applied here as a veto because there is no score for it to shade.
                if let neg = negTimbreProfile, let nc = packedNegCentroid,
                   let dn = SimilarityFamilies.timbreDistance(v, nc) {
                    let negFit = dn <= neg.spread ? 1
                        : exp(-(dn - neg.spread) / SimilarityFamilies.timbreDecay)
                    guard 1 - tuning.rejectionWeight * negFit >= RecSoundAdmit.minNetFit else {
                        continue
                    }
                }
                admitPool.append(RecSoundAdmit.Candidate(
                    id: t.songId,
                    capKey: capKeyByArtist[t.artistKey] ?? t.artistKey,
                    decade: t.year.map { ($0 / 10) * 10 },
                    rawGenre: RecSoundAdmit.genreBucket(t.genreRaw),
                    distance: d))
                RecSoundAdmit.trimIfNeeded(&admitPool)
                continue
            }
            guard a > 0 || g > 0 else { continue }
            var score = terms.artist * a + terms.genre * g
            if let era, let eraCal {
                score += terms.year * SimilarityFamilies.eraFit(year: t.year.map(Double.init),
                                                                window: era, calibration: eraCal)
            }
            if terms.musical > 0 {
                score += terms.musical * SimilarityFamilies.musicalFit(
                    bpm: t.bpm, camelot: t.camelot, profile: musical, calibration: musicalCal)
            }
            let penalty = tuning.rejectionWeight
                * (terms.artist * (negArtists[t.artistKey] ?? 0)
                   + terms.genre * (t.genre.flatMap { negGenres[$0] } ?? 0))
            // ── SIMILARITY GATES, NOVELTY REORDERS ───────────────────────────────────────────
            // `sim` is everything above: the three families, minus the rejected shape, and it is
            // what the admission rule (`a > 0 || g > 0`, unchanged) already qualified. The aux mix
            // is applied as a BOUNDED MULTIPLIER on it rather than added to it, which makes the
            // boundary a theorem instead of a hope: a candidate can never outrank one whose
            // similarity is more than `1 + suggestionAuxGain` (1.40×) times its own. Added on, a
            // 0.20-ish novelty term is a 4× swing at the bottom of the admitted similarity range —
            // that is how "novelty" turns into "noise", and it is the failure this shape rules out.
            let sim = max(0, score - penalty)
            guard sim > 0 else { continue }
            let capKey = capKeyByArtist[t.artistKey] ?? t.artistKey
            let n = playCount(t.songId)
            let fam = n > 0 && famDenom > 0 ? log2(1 + Double(n)) / famDenom : 0
            let aux = RecNovelty.aux(novelty: artistFam.novelty(capKey),
                                     familiarity: fam,
                                     noveltyWeight: tuning.suggestionNoveltyWeight,
                                     familiarityWeight: tuning.suggestionFamiliarityWeight,
                                     isLive: artistFam.isLive)
            var net = sim * (1 + tuning.suggestionAuxGain * aux)
            // ── THE TIMBRE MULTIPLIER (audio-similarity v2) ──────────────────────────────────
            // Bounded exactly like the aux mix: similarity still gates, sound reorders inside a
            // 1.35× band. An unanalysed candidate gets the round-neutral multiplier — identical
            // across every unanalysed row, so no candidate is ever structurally buried for
            // lacking a vector (the fairness rule the tests assert on the real catalog).
            if let timbreProfile, let timbreCal {
                let fit = SimilarityFamilies.timbreFit(timbre[t.songId], positive: timbreProfile,
                                                       negative: negTimbreProfile,
                                                       rejectionWeight: tuning.rejectionWeight,
                                                       calibration: timbreCal)
                net *= 1 + tuning.timbreGain * fit
            }
            // Skip demotion — the same bounded multiplier the zone pools apply (see
            // `Tuning.skipPenaltyWeight`): a skipped song ranks lower, it is never removed.
            if let p = feedback.skipPenalty[t.songId] {
                net *= 1 - tuning.skipPenaltyWeight * min(1, max(0, p))
            }
            guard net > 0 else { continue }
            let rawGenre = RecSoundAdmit.genreBucket(t.genreRaw)
            scored.append((t.songId, t.artistKey, capKey, net, isIncumbent(t), rawGenre,
                           rawGenre.map { !memberRawGenres.contains($0) } ?? false))
        }
        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.id < $1.id) }

        // ── ONE RECORDING, ONE ROW ───────────────────────────────────────────────────────────
        // THE choke point for this surface, and it sits HERE — after the final sort so the
        // survivor is the highest-ranked instance, and BEFORE `compose` so the freed slot is
        // refilled from deeper in the ranking and the list never shrinks from 25 to 24.
        //
        // The ranking has always de-duplicated candidate-vs-MEMBER and never candidate-vs-
        // CANDIDATE, which is how "Expressway To Your Heart" reached one crate twice under two
        // catalog ids — carrying DIFFERENT feedback state, because they were two genuinely
        // different rows. See `RecRecordingIdentity` for the identity and its false-merge risk.
        //
        // ── ONE MASK OVER BOTH POOLS, NOT ONE PER POOL ───────────────────────────────────────
        // The sound door opened a SECOND way into the list, and a collapse that only sees the
        // scored pool cannot see across it. The gap is narrow but real: `RecSoundAdmit.select`'s
        // per-artist bucket cap already blocks the admitted-vs-admitted case, and a row whose
        // artist matches the crate is scored rather than admitted — but two catalog ids for ONE
        // recording whose credit strings normalise to DIFFERENT `artistKey`s ("X" and "X feat.
        // Y") put one instance in `scored` and the other in `admitPool`, and both would be
        // emitted. That is exactly the bug the collapse was landed to kill, arriving through the
        // new door.
        //
        // `keepMask` already has the mechanism — `tier`, "the highest-ranked POOL, asked FIRST",
        // whose doc says a caller with parallel pools slices ONE mask rather than running
        // collapses that cannot see each other. Scored rows take the higher tier: a row metadata
        // qualified is strictly better evidence than one admitted on sound alone, and the two
        // pools' numbers do not mean the same thing (a net score against an RMS distance), so
        // the POOL settles a cross-pool twin and never the two incomparable scores. Within the
        // admit pool `-distance` is the ranking, matching `select`'s closest-first order.
        let scoredCount = scored.count
        func identityCandidate(_ id: String, tier: Int, score: Double) -> RecRecordingIdentity.Candidate {
            let am = trackById[id]?.appleMusicId
            return RecRecordingIdentity.Candidate(
                id: id,
                identity: RecRecordingIdentity.identity(songId: id, appleMusicId: am,
                                                        version: versionKeys[id],
                                                        lengthMs: trackById[id]?.lengthMs),
                tier: tier,
                score: score,
                playable: RecRecordingIdentity.resolvesToStreamableAudio(appleMusicId: am))
        }
        let keep = RecRecordingIdentity.keepMask(
            scored.map { identityCandidate($0.id, tier: 1, score: $0.score) }
            + admitPool.map { identityCandidate($0.id, tier: 0, score: -$0.distance) })
        scored = zip(scored, keep.prefix(scoredCount)).compactMap { $1 ? $0 : nil }
        admitPool = zip(admitPool, keep.dropFirst(scoredCount)).compactMap { $1 ? $0 : nil }

        // ── THE CAP RUNS AFTER THE SORT, AND ON THE PRIMARY ARTIST ───────────────────────────
        // After, so no ranking change can defeat it — it is a property of the OUTPUT, not a
        // pressure on the score. And on `RecNovelty.primaryArtistKey` rather than the raw credit,
        // because a cap that "Drake & Future" walks around is not a cap: measured over 40 real
        // tiles, Drake held 25 rows under his own name plus 7 more through collaborations — 32
        // rows under a cap of 3 per tile.
        //
        // The walk itself is `RecComposition.compose` — the same artist-cap walk this loop used
        // to be, PLUS the owner's 50% incumbent cap: rows whose artist the collection already
        // holds take at most `suggestionIncumbentMaxShare` of the list, newcomers deeper in the
        // ranking are pulled up in their own order, and the floor fails OPEN from incumbents when
        // the newcomer pool runs dry. A list already under the cap comes back byte-identical.
        //
        // …and TWO more phases, both of which are no-ops on a crate that cannot earn them. The
        // SOUND QUOTA seats what the door admitted at reserved positions (never row 0, never
        // more than `soundAdmitHardCap`), and the DIVERSITY FLOOR holds the tile's raw-genre
        // count at the level it measured with the timbre term OFF — the variety the term was
        // measured to cost (−0.86 distinct genres, −5.28pp new-genre share per 25 rows).
        let admittedRows = RecSoundAdmit.select(admitPool, cap: admitQuota).map { c in
            RecComposition.Row(id: c.id, capKey: c.capKey, isIncumbent: false,
                               rawGenre: c.rawGenre,
                               // Admitted by definition means "shares no genre category with the
                               // crate", so its raw label is new to the crate too.
                               isNewGenre: true)
        }
        let minRawGenres = max(0, Int((Double(limit) * tuning.suggestionMinRawGenreShare)
                                        .rounded(.up)))
        let maxSwaps = max(0, Int((Double(limit) * tuning.suggestionDiversityMaxSwapShare)
                                    .rounded(.down)))
        let ids = RecComposition.compose(
            scored.map { RecComposition.Row(id: $0.id, capKey: $0.capKey,
                                            isIncumbent: $0.isIncumbent,
                                            rawGenre: $0.rawGenre, isNewGenre: $0.isNewGenre) },
            limit: limit, maxPerArtist: tuning.maxPerArtist,
            incumbentMaxShare: tuning.suggestionIncumbentMaxShare,
            soundAdmit: admittedRows.isEmpty ? nil
                : RecComposition.SoundAdmit(rows: admittedRows,
                                            maxShare: tuning.soundAdmitMaxShare,
                                            hardCap: tuning.soundAdmitHardCap),
            diversity: minRawGenres > 0 && maxSwaps > 0
                ? RecComposition.Diversity(minDistinctRawGenres: minRawGenres,
                                           maxSwaps: maxSwaps,
                                           searchDepth: max(limit * 8, 50)) : nil)
        // The admitted set is the intersection with what was actually EMITTED — the quota can be
        // trimmed by the artist budget or by the truncation back to `n`, and a badge on a row
        // that did not survive would be a caption about a row nobody can see.
        let emitted = Set(ids)
        return Ranking(ids: ids,
                       soundAdmitted: Set(admittedRows.map(\.id)).intersection(emitted),
                       soundWords: timbreProfile.map {
                           SimilarityFamilies.timbreAdjectives($0.centroid)
                               .joined(separator: ", ")
                       })
    }

    /// The same ranking, with the one-line WHY each row earned its place.
    ///
    /// A SIBLING rather than a new return type on `suggestions` so no call site has to change:
    /// the tiles keep taking `[String]`, and a view that wants to render the reason can move to
    /// this when it is ready. Explainability was a requirement of the rebalance — a novelty term
    /// that cannot be read off the row is indistinguishable from the engine being random — and the
    /// cloud tile has carried a `reasons` array all along, so this is the device's half of it.
    static func suggestionsExplained(memberSongIds: [String],
                                     tracks: [Track],
                                     playCount: (String) -> Int,
                                     feedback: Feedback = Feedback(),
                                     limit: Int = 25,
                                     tuning: Tuning = Tuning(),
                                     versions: [String: RecVersionIdentity.Key]? = nil,
                                     timbre: [String: SimilarityFamilies.TimbreVector] = [:],
                                     packed: SimilarityFamilies.PackedCorpus? = nil)
    -> [(songId: String, why: String)] {
        explainedSuggestions(memberSongIds: memberSongIds, tracks: tracks, playCount: playCount,
                             feedback: feedback, limit: limit, tuning: tuning, versions: versions,
                             timbre: timbre, packed: packed).rows
    }

    /// The explained ranking PLUS which rows came through the sound door — what a surface needs
    /// to render the "Sounds like" badge beside the caption.
    ///
    /// Two faces of one ranking, never two rankings: the badge set comes from `rank`, which is
    /// also what produced the ids, so the badge cannot disagree with the list it is drawn on.
    struct ExplainedRanking: Sendable {
        var rows: [(songId: String, why: String)] = []
        var soundAdmitted: Set<String> = []
    }

    static func explainedSuggestions(memberSongIds: [String],
                                     tracks: [Track],
                                     playCount: (String) -> Int,
                                     feedback: Feedback = Feedback(),
                                     limit: Int = 25,
                                     tuning: Tuning = Tuning(),
                                     versions: [String: RecVersionIdentity.Key]? = nil,
                                     timbre: [String: SimilarityFamilies.TimbreVector] = [:],
                                     packed: SimilarityFamilies.PackedCorpus? = nil)
    -> ExplainedRanking {
        let ranking = rank(memberSongIds: memberSongIds, tracks: tracks, playCount: playCount,
                           feedback: feedback, limit: limit, tuning: tuning, versions: versions,
                           timbre: timbre, packed: packed)
        let ids = ranking.ids
        guard !ids.isEmpty else { return ExplainedRanking() }
        let trackById = Dictionary(tracks.map { ($0.songId, $0) }, uniquingKeysWith: { a, _ in a })
        var maxPlays = 0
        var capKeyByArtist: [String: String] = [:]
        var artistPlays: [String: Int] = [:]
        for t in tracks {
            let n = playCount(t.songId)
            maxPlays = max(maxPlays, n)
            let cap = capKeyByArtist[t.artistKey]
                ?? { let k = RecNovelty.primaryArtistKey(t.artistName)
                     capKeyByArtist[t.artistKey] = k; return k }()
            if n > 0 { artistPlays[cap, default: 0] += n }
        }
        let artistFam = RecNovelty.ArtistFamiliarity(artistPlays: artistPlays)
        let members = Set(memberSongIds)
        let memberGenres = Set(memberSongIds.compactMap { trackById[$0]?.genre })
        // The SAME incumbent test `suggestions` composed under — credit identity, so the caption
        // "An artist already in here" is true of exactly the rows the floor counted as incumbent
        // (a Terrace Martin row against a crate filed under the five-name Dinner Party credit is
        // incumbent in both places, or the captions and the composition would disagree).
        var creditCache: [String: [String]] = [:]
        func creditKeys(_ t: ZoneEngine.Track) -> [String] {
            if let k = creditCache[t.artistKey] { return k }
            let k = RecVersionIdentity.creditArtistKeys(t.artistName)
            creditCache[t.artistKey] = k
            return k
        }
        var memberCreditKeys: Set<String> = []
        for id in members {
            guard let t = trackById[id] else { continue }
            memberCreditKeys.formUnion(creditKeys(t))
        }
        func isIncumbent(_ t: ZoneEngine.Track) -> Bool {
            !memberCreditKeys.isEmpty
                && creditKeys(t).contains { memberCreditKeys.contains($0) }
        }
        // The same era window `suggestions` scored against (members only — the 👍 profile add is
        // an approximation this explainer already makes for artists and genres).
        let era = SimilarityFamilies.eraWindow(
            years: memberSongIds.compactMap { trackById[$0]?.year.map(Double.init) })
        // The same timbre profile `suggestions` scored against (members only, same approximation)
        // and the words its sound can honestly be described in — "punchy, dark, dynamic".
        let timbreProfile = SimilarityFamilies.timbreProfile(
            memberSongIds.compactMap { id in timbre[id].map { (vector: $0, weight: 1.0) } })
        let timbreWords = timbreProfile.map {
            SimilarityFamilies.timbreAdjectives($0.centroid).joined(separator: ", ")
        }
        _ = members
        let rows: [(songId: String, why: String)] = ids.map { id in
            // ── THE SOUND DOOR SPEAKS FIRST, AND IT IS THE ONLY ROW THAT MAY ────────────────
            // An admitted row shares NEITHER an artist NOR a genre with this crate: every other
            // caption below would be false of it, and the strongest true one — "New artist for
            // this crate" — is true but hides the actual evidence, which is that the engine
            // measured it and it sounds like the crate. A suggestion made on sound has to be
            // legible AS a suggestion made on sound, or a 👎 on it is a verdict on the wrong
            // question. Same caption family the re-rank half already uses, so there is one
            // idiom for "this is about how it sounds", not two.
            if ranking.soundAdmitted.contains(id) {
                if let words = ranking.soundWords, !words.isEmpty {
                    return (id, "Sounds like this crate: \(words)")
                }
                return (id, "Sounds like this crate")
            }
            guard let t = trackById[id] else { return (id, "Fits this collection") }
            let cap = capKeyByArtist[t.artistKey] ?? t.artistKey
            let incumbent = isIncumbent(t)
            // NOVELTY FIRST when it is what set this row apart — that is the honest reading of a
            // ranking where novelty is the reordering signal, and it is what makes a 👍 on the row
            // legible as a verdict on an unknown rather than a nod at a favourite.
            if let why = artistFam.reason(cap), !incumbent {
                return (id, why)
            }
            if incumbent { return (id, "An artist already in here") }
            // TIMBRE speaks only when it was OBSERVED (the row has a vector) and the fit is real
            // (inside or near the crate's own spread) — never off the imputed neutral, and never
            // in words the adjective table cannot honestly produce. ABOVE genre in precedence,
            // deliberately: an admitted candidate matched the crate's artists or genres by
            // construction, so "Mostly soul, like this collection" is true of nearly every row
            // and says nothing — while a measured "sounds like the crate" is the sharpest claim
            // this explainer can make about THIS row, and it only ever fires on real evidence.
            if let timbreProfile, let words = timbreWords, !words.isEmpty,
               let v = timbre[id], let fit = SimilarityFamilies.timbreFit(v, profile: timbreProfile),
               fit >= 0.8 {
                return (id, "Sounds like this crate: \(words)")
            }
            if let g = t.genre, memberGenres.contains(g) { return (id, "Mostly \(g), like this collection") }
            if let era, let y = t.year, era.contains(Double(y)) {
                return (id, "From this collection's \(Int(era.lo))–\(Int(era.hi)) era")
            }
            // A NEWCOMER row's reason says so when nothing stronger exists — below timbre/genre/
            // era in precedence, deliberately: those are measured claims about THIS row, while
            // this is the composition's claim about the crate. Only when the crate has an artist
            // roster to be new TO (`memberCreditKeys` non-empty — an unresolvable membership must
            // not caption every row "new").
            if !memberCreditKeys.isEmpty, !incumbent { return (id, "New artist for this crate") }
            return (id, "Fits this collection")
        }
        return ExplainedRanking(rows: rows, soundAdmitted: ranking.soundAdmitted)
    }
}
