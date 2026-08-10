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

        init(songId: String, artistKey: String, artistName: String, genre: String?) {
            self.songId = songId
            self.artistKey = artistKey
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
        /// Plays older than this contribute nothing (and are not even scanned).
        var lookbackDays: Double = 60
        /// A song played inside this window is EXCLUDED — "what to play next" should not hand
        /// back what is still ringing in your ears.
        var cooldownHours: Double = 6
        /// The owner's cap: at most this many songs by one artist.
        var maxPerArtist = 3
        /// Target floor. When the zone itself is thinner than this, the remainder is filled with
        /// the owner's most-played songs (still under the per-artist cap) so a cold or narrow
        /// history still produces a usable set rather than four rows.
        var minSongs = 30
        /// Hard ceiling.
        var maxSongs = 90

        /// Weight on "you have been playing this artist".
        var artistWeight: Double = 1.0
        /// Weight on "you have been playing this genre". Lower than artist on purpose — genre is
        /// a much coarser signal, and at parity it floods the list with one big category.
        var genreWeight: Double = 0.45
        /// Weight on "you have played this particular song a lot". Keeps the set listenable
        /// instead of turning it into a deep-cuts generator.
        var familiarityWeight: Double = 0.30

        public init() {}
    }

    // ========================================================================
    // MARK: - Affinity
    // ========================================================================

    /// Recency-weighted affinity for artists and genres, each normalized to its own max so the
    /// two are comparable before weighting.
    ///
    /// Normalizing by the MAX (not the sum) is deliberate: sum-normalizing would make a listener
    /// with a broad history score every artist near zero and a listener with a narrow one score
    /// their single artist near one, so the same weights would mean different things per user.
    /// Max-normalizing makes "your top artist" = 1.0 for everyone.
    struct Affinity: Sendable {
        var artists: [String: Double] = [:]
        var genres: [String: Double] = [:]
        /// True when there was no usable recent activity at all.
        var isEmpty: Bool { artists.isEmpty && genres.isEmpty }
    }

    static func affinity(plays: [Play],
                         trackById: [String: Track],
                         nowMs: Double,
                         tuning: Tuning = Tuning()) -> Affinity {
        var artists: [String: Double] = [:]
        var genres: [String: Double] = [:]
        let halfLifeMs = tuning.halfLifeDays * 86_400_000
        let horizonMs = tuning.lookbackDays * 86_400_000

        for p in plays {
            let age = nowMs - p.playedAtMs
            // A future-dated play (clock skew, a restored log from another device) is treated as
            // "now" rather than discarded — clamping is safer than dropping real activity.
            guard age <= horizonMs else { continue }
            guard let t = trackById[p.songId] else { continue }
            let w = pow(2.0, -max(0, age) / halfLifeMs)
            artists[t.artistKey, default: 0] += w
            if let g = t.genre, !g.isEmpty { genres[g, default: 0] += w }
        }

        if let maxA = artists.values.max(), maxA > 0 {
            for (k, v) in artists { artists[k] = v / maxA }
        }
        if let maxG = genres.values.max(), maxG > 0 {
            for (k, v) in genres { genres[k] = v / maxG }
        }
        return Affinity(artists: artists, genres: genres)
    }

    // ========================================================================
    // MARK: - In Da Zone
    // ========================================================================

    /// Top songs to play right now, given recent activity.
    ///
    /// Returns song ids, best first, with **at most `maxPerArtist` per artist** and **at most
    /// `maxSongs`** overall — the owner's two hard constraints. Falls back to most-played when
    /// the zone is thin, so the result reaches `minSongs` whenever the library can supply it.
    ///
    /// - Parameters:
    ///   - tracks: the whole candidate catalog (already filtered to what this install can play).
    ///   - plays: recent play events, any order.
    ///   - playCount: lifetime play count per song id — familiarity, not recency.
    static func inDaZone(tracks: [Track],
                         plays: [Play],
                         playCount: (String) -> Int,
                         nowMs: Double,
                         tuning: Tuning = Tuning()) -> [String] {
        guard !tracks.isEmpty else { return [] }
        let trackById = Dictionary(tracks.map { ($0.songId, $0) }, uniquingKeysWith: { a, _ in a })
        let aff = affinity(plays: plays, trackById: trackById, nowMs: nowMs, tuning: tuning)

        // Songs still in cooldown — just played, so not offered back.
        let cooldownMs = tuning.cooldownHours * 3_600_000
        var onCooldown = Set<String>()
        for p in plays where nowMs - p.playedAtMs < cooldownMs { onCooldown.insert(p.songId) }

        // Familiarity is log-scaled for the same reason the release-feed TTL is: play counts are
        // heavy-tailed, and a linear term would let one 2,000-play song outweigh every zone signal.
        let maxPlays = tracks.reduce(0) { max($0, playCount($1.songId)) }
        let famDenom = log2(1 + Double(max(maxPlays, 1)))
        func familiarity(_ id: String) -> Double {
            let n = playCount(id)
            guard n > 0, famDenom > 0 else { return 0 }
            return log2(1 + Double(n)) / famDenom
        }

        var scored: [(id: String, artist: String, score: Double)] = []
        scored.reserveCapacity(min(tracks.count, 4096))
        for t in tracks where !onCooldown.contains(t.songId) {
            let a = aff.artists[t.artistKey] ?? 0
            let g = t.genre.flatMap { aff.genres[$0] } ?? 0
            // Require SOME zone signal: a song whose artist and genre are both cold is not "in
            // the zone" no matter how often it has been played. Familiarity only ranks inside
            // the zone; it never admits anything to it. (The fill pass below is what covers a
            // history too thin to produce a zone at all.)
            guard a > 0 || g > 0 else { continue }
            let score = a * tuning.artistWeight
                      + g * tuning.genreWeight
                      + familiarity(t.songId) * tuning.familiarityWeight
            scored.append((t.songId, t.artistKey, score))
        }

        // Deterministic: ties break on song id so the tile is stable between renders and tests
        // are not order-flaky.
        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.id < $1.id) }

        var perArtist: [String: Int] = [:]
        var out: [String] = []
        for c in scored {
            guard out.count < tuning.maxSongs else { break }
            let n = perArtist[c.artist] ?? 0
            guard n < tuning.maxPerArtist else { continue }
            perArtist[c.artist] = n + 1
            out.append(c.id)
        }

        // Fill to the floor from most-played, honoring the same per-artist cap. This is what
        // makes the tile useful on a fresh install (no history ⇒ no zone ⇒ empty without it).
        if out.count < tuning.minSongs {
            let taken = Set(out)
            // Written as an explicit loop rather than filter/map/sorted: the chained form is a
            // type-checker timeout on this tuple shape (`error: unable to type-check this
            // expression in reasonable time`), not merely slow to compile.
            var rest: [(id: String, artist: String, n: Int)] = []
            rest.reserveCapacity(tracks.count)
            for t in tracks {
                if taken.contains(t.songId) || onCooldown.contains(t.songId) { continue }
                rest.append((id: t.songId, artist: t.artistKey, n: playCount(t.songId)))
            }
            rest.sort { a, b in a.n > b.n || (a.n == b.n && a.id < b.id) }
            for c in rest {
                guard out.count < tuning.minSongs else { break }
                let n = perArtist[c.artist] ?? 0
                guard n < tuning.maxPerArtist else { continue }
                perArtist[c.artist] = n + 1
                out.append(c.id)
            }
        }
        return out
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
    /// should turn into one artist's discography.
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
