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
        /// THE definition of "same artist" for this engine — `PuzzleSimilarity.artistKey`:
        /// diacritic- and case-folded, trimmed, leading "the " stripped.
        ///
        /// ── WHY IT IS DERIVED HERE AND NOT PASSED IN (load-bearing) ──────────────────────────
        /// The owner's 3-per-artist cap is one rule, and it is applied in two places: `inDaZone`
        /// (which keys on `PuzzleSimilarity.artistKey`) and `suggestions` (which keyed on
        /// whatever the caller put in this field — `IndexArtist.normalize`, i.e. trim + lowercase
        /// + collapse whitespace, and NOTHING else). Two notions of "same artist" for one rule
        /// meant every SPELLING got its own three-song budget in a collection tile.
        ///
        /// That is not theoretical on this catalog. Measured over all 96,021 rows of
        /// public/apple-music-index.json: 12,656 normalize-keys vs 12,636 artistKeys, 20 artists
        /// split across the two, **17 of which could exceed the cap and 7 could reach six slots**
        /// — Jay-Z (138 songs as "jaÿ-z" + 15 as "jay-z"), Janelle Monáe (66 + 19), Sinéad
        /// Harnett (48 + 8), Emeli Sandé (96 + 1), The Game (82 + 2), The Alchemist (52 + 1),
        /// Gang Starr, Luiz Bonfá, Andrés, Thủy.
        ///
        /// Deriving it in the initializer — rather than accepting it as a parameter — is what
        /// makes the two call sites incapable of drifting apart again. It is computed once per
        /// catalog load (`AppModel.zoneTracks`), not per suggestion pass, so it costs nothing.
        let artistKey: String
        let artistName: String
        /// Top-tier genre category, or nil when the album carries none.
        let genre: String?

        init(songId: String, artistName: String, genre: String?) {
            self.songId = songId
            self.artistKey = PuzzleSimilarity.artistKey(artistName)
            self.artistName = artistName
            self.genre = genre
        }
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

        /// Weight on "you have played this particular song a lot" — inside pool A it is the
        /// tiebreak between two equally-hot songs; inside pool B it is what makes a buried
        /// FAVOURITE beat a record he has never once played.
        var familiarityWeight: Double = 0.30

        /// How far the auxiliary signals (dormancy · familiarity · tempo/key fit) may lift a
        /// rediscovery candidate, as a multiplier on its similarity: `sim × (1 + auxGain × aux)`.
        ///
        /// MULTIPLICATIVE, never additive, and that is load-bearing. Added on, these terms could
        /// float a song with no artist/genre/year relationship whatsoever above a genuine match —
        /// the pool would stop being "similar to what you've been bumping" and start being "old
        /// stuff you used to like". As a multiplier the guarantee is exact and testable: a song
        /// can never outrank another whose similarity is more than `1 + auxGain` times its own.
        /// At 0.6 that is a 1.6× band — wide enough to reorder within a tier of comparable
        /// matches, far too narrow to cross tiers.
        var auxGain: Double = 0.6
        /// Relative pull of the three auxiliary signals inside `aux` (they are renormalized over
        /// whichever ones the profile can actually speak, so these are ratios, not a partition).
        var dormancyWeight: Double = 0.40
        var auxFamiliarityWeight: Double = 0.30
        /// bpm + camelot fit — the "musical metadata" half of the owner's similarity brief.
        var musicalWeight: Double = 0.30

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
        /// pool to be complementary to, and dormancy is meaningless as a preference. It keeps the
        /// linear artist/genre match these two weights parameterize.
        ///
        /// Genre is deliberately the lighter of the two — it is a much coarser signal, and at
        /// parity with artist it floods a collection's tile with one big category.
        var artistWeight: Double = 1.0
        var genreWeight: Double = 0.45

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

    /// The tempo/key shape of what the owner has been bumping.
    ///
    /// This is the one similarity signal `PuzzleSimilarity` does not carry, and it is deliberately
    /// NOT added there. Gem Collector ranks songs for a COLLECTION — "does this belong in the same
    /// crate" — where tempo and key are irrelevant; In Da Zone ranks them for a PLAY QUEUE, where a
    /// 78-bpm ballad landing between two 140-bpm tracks is exactly the thing that breaks a zone.
    /// Adding `wBpm`/`wKey` to the shared scorer would also move every shipped puzzle ranking and
    /// break the tests that pin it, to buy the puzzle a signal it has no use for.
    struct MusicalProfile: Sendable {
        var bpmMean: Double?
        /// Floored when scoring for the same reason `yearSigma` is: a listener on a metronome
        /// must not make every other tempo score exactly zero.
        var bpmSigma: Double = 8
        /// Camelot codes present in the seed set, uppercased (e.g. "8A").
        var camelots: Set<String> = []
        var isEmpty: Bool { bpmMean == nil && camelots.isEmpty }
    }

    /// Harmonic distance on the Camelot wheel, 0…1.
    ///
    /// The wheel is the DJ convention this app already speaks (`camelot` is a burned artifact of
    /// the beat-grid pass): same code is a perfect mix, same number with the other letter is the
    /// relative major/minor, and ±1 around the twelve-hour face is the classic one-step move.
    /// Anything else is not a harmonic neighbour and scores zero rather than a small number —
    /// a wrong key is wrong, not slightly right.
    static func camelotAffinity(_ code: String?, to set: Set<String>) -> Double {
        guard let raw = code?.uppercased(), !set.isEmpty else { return 0 }
        guard let letter = raw.last, letter == "A" || letter == "B",
              let number = Int(raw.dropLast()), (1...12).contains(number) else { return 0 }
        if set.contains(raw) { return 1.0 }
        let other = "\(number)\(letter == "A" ? "B" : "A")"
        if set.contains(other) { return 0.75 }
        let up = number % 12 + 1
        let down = (number + 10) % 12 + 1
        if set.contains("\(up)\(letter)") || set.contains("\(down)\(letter)") { return 0.6 }
        return 0
    }

    /// 0…1 tempo/key fit, or nil when neither the profile nor the song can speak — nil DROPS the
    /// term from the auxiliary blend instead of scoring it zero, which is the same profile-level
    /// availability rule `PuzzleSimilarity.availableWeight` uses. Scoring an absent field zero
    /// would systematically punish the ~unanalysed part of the catalog for missing metadata.
    static func musicalFit(bpm: Double?, camelot: String?, profile: MusicalProfile) -> Double? {
        var terms: [Double] = []
        if let mean = profile.bpmMean, let bpm, bpm > 0 {
            terms.append(exp(-abs(bpm - mean) / max(6, profile.bpmSigma)))
        }
        if !profile.camelots.isEmpty, camelot != nil {
            terms.append(camelotAffinity(camelot, to: profile.camelots))
        }
        guard !terms.isEmpty else { return nil }
        return terms.reduce(0, +) / Double(terms.count)
    }

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
    static func inDaZone(songs: [IndexSong],
                         genreBySongId: [String: String] = [:],
                         otherCollections: [[String]] = [],
                         plays: [Play],
                         playCount: (String) -> Int,
                         lastPlayedMs: [String: Double] = [:],
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
        let taste = PuzzleSimilarity.profile(targetMemberIds: [Array(seedWeight.keys)],
                                             songsById: songsById,
                                             genreBySongId: genreBySongId,
                                             otherCollections: otherCollections,
                                             plays: [],
                                             hasRecency: false,
                                             memberWeights: seedWeight,
                                             nowMs: nowMs)
        let musical = musicalProfile(seedWeight: seedWeight, songsById: songsById)

        // ── 3. Familiarity, log-scaled ───────────────────────────────────────────────────────
        // Play counts are heavy-tailed; a linear term would let one 2,000-play song outweigh
        // every other signal in the ranking.
        var maxPlays = 0
        for s in songs { maxPlays = max(maxPlays, playCount(s.id)) }
        let famDenom = log2(1 + Double(max(maxPlays, 1)))
        func familiarity(_ id: String) -> Double {
            let n = playCount(id)
            guard n > 0, famDenom > 0, maxPlays > 0 else { return 0 }
            return log2(1 + Double(n)) / famDenom
        }

        // Which auxiliary signals this run can speak at all — renormalized over exactly those,
        // so a device with no last-played data does not silently deflate every score.
        let hasDormancy = !lastPlayedMs.isEmpty
        let hasFamiliarity = maxPlays > 0
        let hasMusical = !musical.isEmpty

        // ── 4. Partition + score ─────────────────────────────────────────────────────────────
        var familiarPool: [(id: String, artist: String, score: Double)] = []
        var rediscoveryPool: [(id: String, artist: String, score: Double)] = []
        /// Dormant songs that are NOT neighbours of the taste profile. Never used while the real
        /// pools can still fill the queue — only to reach `minSongs`. See the gate below.
        var fallbackPool: [(id: String, artist: String, score: Double)] = []
        rediscoveryPool.reserveCapacity(min(songs.count, 8192))

        /// Dormancy + buried-favourite familiarity, renormalized over whichever of the two this
        /// run can speak. The similarity-free half of the rediscovery score, used on its own for
        /// the cold-start path and for `fallbackPool`.
        func auxOnly(_ id: String) -> Double {
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
            return den > 0 ? num / den : 0
        }

        // PASS 1 — CHEAP. Partition the catalog and give every rediscovery candidate a prescore
        // built only from dictionary lookups. Nothing here calls `PuzzleSimilarity.score`.
        // Artist outranks genre in the prescore because it outranks it in the real scorer too
        // (0.30 vs 0.25) and because it is the far narrower signal; `aux` (< 1) only ever breaks
        // ties inside a tier, so the shortlist is ordered artist-hits, then genre-hits, then the
        // rest by dormancy/familiarity.
        var prescored: [(idx: Int, artist: String, pre: Double)] = []
        prescored.reserveCapacity(min(songs.count, 16_384))

        for (idx, song) in songs.enumerated() {
            let id = song.id
            if onCooldown.contains(id) { continue }
            let artist = PuzzleSimilarity.artistKey(song.artist)

            if let w = seedWeight[id] {
                // FAMILIAR — how hard he has been leaning on this exact song lately, with
                // lifetime plays as the tiebreak between two equally-hot ones.
                familiarPool.append((id, artist, w + familiarity(id) * tuning.familiarityWeight))
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
                fallbackPool.append((id, artist, auxOnly(id)))
                continue
            }

            prescored.append((idx, artist,
                              (artistHit ? 2 : 0) + (genreHit ? 1 : 0) + auxOnly(id)))
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
        var shortlist: [(idx: Int, artist: String, pre: Double)] = []
        shortlist.reserveCapacity(min(prescored.count, tuning.shortlistCap))
        for c in prescored {
            if shortlist.count >= tuning.shortlistCap { break }
            let n = quota[c.artist] ?? 0
            if n >= perArtistQuota { continue }
            quota[c.artist] = n + 1
            shortlist.append(c)
        }
        prescored = shortlist

        let auxBaseDen = tuning.dormancyWeight * (hasDormancy ? 1 : 0)
                       + tuning.auxFamiliarityWeight * (hasFamiliarity ? 1 : 0)
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
            guard sim > 0 else { continue }

            // Dormancy ("the longer buried, the better") + buried-favourite familiarity ("you used
            // to love this" beats "you never played this" — rediscovery, not discovery), plus the
            // tempo/key term, which only a neighbour is eligible for.
            var auxNum = auxOnly(id) * auxBaseDen
            var auxDen = auxBaseDen
            if hasMusical, let fit = musicalFit(bpm: song.bpm, camelot: song.camelot,
                                                profile: musical) {
                auxNum += tuning.musicalWeight * fit
                auxDen += tuning.musicalWeight
            }
            let aux = auxDen > 0 ? auxNum / auxDen : 0
            rediscoveryPool.append((id, c.artist, sim * (1 + tuning.auxGain * aux)))
        }

        // Ties break on song id so the tile is stable between renders and tests are not flaky.
        let byScore: ((id: String, artist: String, score: Double),
                      (id: String, artist: String, score: Double)) -> Bool = {
            $0.score > $1.score || ($0.score == $1.score && $0.id < $1.id)
        }
        familiarPool.sort(by: byScore)
        rediscoveryPool.sort(by: byScore)
        fallbackPool.sort(by: byScore)

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

        return interleave(familiar: familiarPool, rediscovery: rediscoveryPool,
                          fallback: fallbackPool, target: target, tuning: tuning)
    }

    /// Weighted tempo/key shape of the seed set.
    private static func musicalProfile(seedWeight: [String: Double],
                                       songsById: [String: IndexSong]) -> MusicalProfile {
        var p = MusicalProfile()
        var bpms: [(v: Double, w: Double)] = []
        for (id, w) in seedWeight {
            guard let s = songsById[id] else { continue }
            if let b = s.bpm, b > 0 { bpms.append((b, w)) }
            if let c = s.camelot?.uppercased(), !c.isEmpty { p.camelots.insert(c) }
        }
        if !bpms.isEmpty {
            let wSum = bpms.reduce(0) { $0 + $1.w }
            let mean = bpms.reduce(0) { $0 + $1.v * $1.w } / wSum
            p.bpmMean = mean
            let variance = bpms.reduce(0) { $0 + $1.w * ($1.v - mean) * ($1.v - mean) } / wSum
            p.bpmSigma = max(8, variance.squareRoot())
        }
        return p
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
    private static func interleave(familiar: [(id: String, artist: String, score: Double)],
                                   rediscovery: [(id: String, artist: String, score: Double)],
                                   fallback: [(id: String, artist: String, score: Double)],
                                   target: Int,
                                   tuning: Tuning) -> Queue {
        var perArtist: [String: Int] = [:]
        var fi = 0, ri = 0
        var picks: [Pick] = []
        var rediscoveryCount = 0

        /// Next candidate in `pool` that is still under the artist budget, advancing the cursor
        /// past everything it rejects. Consuming a rejected candidate is safe because the budget
        /// only ever grows: a song skipped for a capped artist could never become eligible later.
        func take(_ pool: [(id: String, artist: String, score: Double)],
                  _ cursor: inout Int) -> String? {
            while cursor < pool.count {
                let c = pool[cursor]
                cursor += 1
                if (perArtist[c.artist] ?? 0) < tuning.maxPerArtist {
                    perArtist[c.artist, default: 0] += 1
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
    /// The collection's own membership is the profile — the artists and genres already in it,
    /// weighted uniformly (a playlist is a set, not a timeline, so recency has no meaning here).
    /// Candidates are everything not already a member; a candidate must match the collection on
    /// artist or genre to be offered at all, which is what keeps a tile from appearing for every
    /// collection with a generic "here is more music" list.
    ///
    /// The per-artist cap is the same rule the owner set for In Da Zone: no collection tile
    /// should turn into one artist's discography. Literally the same rule AND literally the same
    /// key — `Track.artistKey` is derived, not supplied, so "same artist" cannot mean one thing
    /// here and another in `inDaZone` (see the note on `Track.artistKey`).
    ///
    /// ── WHAT THE CAP DELIBERATELY DOES *NOT* SPLIT ───────────────────────────────────────────
    /// It keys on the whole credit string, so "Future & Metro Boomin" is a different act from
    /// "Metro Boomin", and each gets its own three. That is a decision, not an oversight. On this
    /// catalog 5,216 of 12,636 artist keys (41%) contain "&" or "," — splitting on them would
    /// shred "Earth, Wind & Fire" and "Sly & the Family Stone" into fragments. Stripping
    /// "featuring"/"feat." is no safer: only 131 of 96,021 songs carry a marker at all, and the
    /// two biggest of those are "Maze featuring Frankie Beverly" and "Rufus featuring Chaka Khan"
    /// — canonical BAND names, whose bare forms ("maze", "rufus") are also both real, distinct
    /// artists in this same catalog. Stripping would merge them wrongly for exactly the rows it
    /// would most affect.
    ///
    /// It is also partly self-limiting: `PuzzleSimilarity`'s artist term uses the same full
    /// string, so a collaboration only competes for slots when its own credit actually matches
    /// the collection.
    static func suggestions(memberSongIds: [String],
                            tracks: [Track],
                            playCount: (String) -> Int,
                            limit: Int = 25,
                            tuning: Tuning = Tuning()) -> [String] {
        let members = Set(memberSongIds)
        guard !members.isEmpty, !tracks.isEmpty else { return [] }
        let trackById = Dictionary(tracks.map { ($0.songId, $0) }, uniquingKeysWith: { a, _ in a })

        var artists: [String: Double] = [:]
        var genres: [String: Double] = [:]
        for id in members {
            guard let t = trackById[id] else { continue }
            artists[t.artistKey, default: 0] += 1
            if let g = t.genre, !g.isEmpty { genres[g, default: 0] += 1 }
        }
        guard !artists.isEmpty || !genres.isEmpty else { return [] }
        if let maxA = artists.values.max(), maxA > 0 { for (k, v) in artists { artists[k] = v / maxA } }
        if let maxG = genres.values.max(), maxG > 0 { for (k, v) in genres { genres[k] = v / maxG } }

        let maxPlays = tracks.reduce(0) { max($0, playCount($1.songId)) }
        let famDenom = log2(1 + Double(max(maxPlays, 1)))

        var scored: [(id: String, artist: String, score: Double)] = []
        for t in tracks where !members.contains(t.songId) {
            let a = artists[t.artistKey] ?? 0
            let g = t.genre.flatMap { genres[$0] } ?? 0
            guard a > 0 || g > 0 else { continue }
            let n = playCount(t.songId)
            let fam = n > 0 && famDenom > 0 ? log2(1 + Double(n)) / famDenom : 0
            scored.append((t.songId, t.artistKey,
                           a * tuning.artistWeight + g * tuning.genreWeight
                             + fam * tuning.familiarityWeight))
        }
        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.id < $1.id) }

        var perArtist: [String: Int] = [:]
        var out: [String] = []
        for c in scored {
            guard out.count < limit else { break }
            let n = perArtist[c.artist] ?? 0
            guard n < tuning.maxPerArtist else { continue }
            perArtist[c.artist] = n + 1
            out.append(c.id)
        }
        return out
    }
}
