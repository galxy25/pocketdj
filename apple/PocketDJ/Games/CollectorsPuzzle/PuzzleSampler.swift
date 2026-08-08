import Foundation

/// Pure weighted sampler behind the Collectors Puzzle queue. No stores, no main-actor —
/// callers snapshot inputs on the main actor (cheap: COW arrays + sets) and run the
/// sampling in a detached task (the Browse off-main doctrine; the pool can be ~100k songs).
enum PuzzleSampler {

    /// What the MAIN ACTOR is allowed to hand over: raw COW containers only, no derived
    /// work. `Inputs(raw:)` builds the ~96k-entry genre map and the membership Sets from
    /// it OFF the main actor — the caller pays only retain/release here, so a debounced
    /// settings keystroke (and the ticker's mid-round top-up) never walks the catalog on
    /// the main thread.
    struct RawInputs {
        var songs: [IndexSong]
        var albumsById: [String: IndexAlbum]
        var favoriteIds: Set<String>
        var playCounts: [String: Int]
        /// Member ids of each `settings.membershipCollectionIds` collection…
        var membershipCollections: [[String]]
        /// …and of each `settings.targetCollectionIds` collection.
        var targetCollections: [[String]]
        /// The rip manifest — songs whose mp3 already sits in S3. Passed as the raw COW
        /// dictionary so the id Set is built OFF the main actor (it can hold thousands).
        var ripManifest: [String: RipsStore.ManifestEntry] = [:]
        /// Songs with a burned file ready ON THIS DEVICE (the user's downloads — small).
        var burnedIds: Set<String> = []
        /// Can Apple Music stream right now (enabled + authorized)? A song carrying an
        /// `appleMusicId` is then playable too.
        var canStreamAppleMusic: Bool = false

        // ── Similarity inputs (all default-empty: a bare sampler behaves exactly as before) ──

        /// EVERY collection's membership as flat id arrays — the "shared with another
        /// collection" similarity signal. Passed as raw COW arrays; `CollectionsStore`
        /// memoizes it on its membership revision so the 0.25 s ticker's top-up never walks
        /// 300 playlist node trees on the main actor.
        var allCollections: [[String]] = []
        /// The play log, raw. Mapped to (songId, atMs) OFF the main actor in `Inputs(raw:)` —
        /// handing over the COW array itself costs the caller one retain.
        var plays: [PlayHistoryStore.PlayEvent] = []
        /// songId → 0…1 cloud similarity rank, fetched ONCE per round (never in the ticker).
        /// Empty is the default and the normal case — the rec engine is off by default.
        var cloudRanks: [String: Double] = [:]
        /// Skip the (catalog-walking) profile build entirely when the round can't use it —
        /// no targets, or similarity off.
        var buildSimilarityProfile: Bool = true
    }

    struct Inputs {
        /// `AppModel.songs` snapshot.
        var songs: [IndexSong]
        /// songId → `Genre.category` (built from the albums snapshot; songs get their
        /// genre from the owning album).
        var genreBySongId: [String: String]
        var favoriteIds: Set<String>
        /// `PlayStatsStore.playCountsSnapshot()`.
        var playCounts: [String: Int]
        /// Union of songIds in `settings.membershipCollectionIds`.
        var membershipUnion: Set<String>
        /// Existing membership of EACH target collection — a song already in ALL of
        /// them has nothing left to assign and never samples.
        var perTargetMembership: [Set<String>]
        /// Songs whose audio can START NOW with no capture: an already-ripped S3 mp3 or a
        /// burned local file. (Rip-ON-DEMAND is deliberately excluded — see `pool`.)
        var playableNowIds: Set<String> = []
        /// Apple Music can stream right now, so any song with an `appleMusicId` is playable.
        var canStreamAppleMusic: Bool = false
        /// What the target collections LOOK like — the similarity ranker's whole input. Empty
        /// (`isEmpty`) whenever there are no targets, so similarity is a no-op there.
        var similarityProfile = PuzzleSimilarity.TargetProfile()
        /// songId → 0…1 cloud rank bonus. Empty by default (the engine is off by default).
        var cloudRanks: [String: Double] = [:]

        init(songs: [IndexSong], genreBySongId: [String: String], favoriteIds: Set<String>,
             playCounts: [String: Int], membershipUnion: Set<String>,
             perTargetMembership: [Set<String>],
             playableNowIds: Set<String> = [], canStreamAppleMusic: Bool = false,
             similarityProfile: PuzzleSimilarity.TargetProfile = .init(),
             cloudRanks: [String: Double] = [:]) {
            self.songs = songs
            self.genreBySongId = genreBySongId
            self.favoriteIds = favoriteIds
            self.playCounts = playCounts
            self.membershipUnion = membershipUnion
            self.perTargetMembership = perTargetMembership
            self.playableNowIds = playableNowIds
            self.canStreamAppleMusic = canStreamAppleMusic
            self.similarityProfile = similarityProfile
            self.cloudRanks = cloudRanks
        }

        /// Can THIS song make sound right now?
        func isPlayableNow(_ song: IndexSong) -> Bool {
            if playableNowIds.contains(song.id) { return true }
            return canStreamAppleMusic && song.appleMusicId != nil
        }

        /// Build the derived structures from a main-actor `RawInputs` snapshot. CALL THIS
        /// OFF THE MAIN ACTOR — it walks every song in the catalog (~96k).
        init(raw: RawInputs) {
            var genreBySongId: [String: String] = [:]
            genreBySongId.reserveCapacity(raw.songs.count)
            // Genre lives on the ALBUM; category once per album, then fan out.
            var categoryByAlbum: [String: String] = [:]
            // The similarity profile needs to resolve its members' rows; built in the SAME
            // walk so the catalog is traversed once, and only when a profile is actually
            // wanted (targets selected + similarity on).
            let wantsProfile = raw.buildSimilarityProfile && !raw.targetCollections.isEmpty
            var songsById: [String: IndexSong] = [:]
            if wantsProfile { songsById.reserveCapacity(raw.songs.count) }
            for song in raw.songs {
                if wantsProfile { songsById[song.id] = song }
                guard let albumId = song.albumId else { continue }
                let cat = categoryByAlbum[albumId] ?? Genre.category(raw.albumsById[albumId]?.genre)
                categoryByAlbum[albumId] = cat
                genreBySongId[song.id] = cat
            }
            var membershipUnion = Set<String>()
            for ids in raw.membershipCollections { membershipUnion.formUnion(ids) }
            // Built HERE (off the main actor): the manifest can hold thousands of ids and
            // this runs on every debounced settings keystroke + the mid-round top-up.
            var playable = Set(raw.ripManifest.keys)
            playable.formUnion(raw.burnedIds)
            let profile = wantsProfile
                ? PuzzleSimilarity.profile(targetMemberIds: raw.targetCollections,
                                           songsById: songsById,
                                           genreBySongId: genreBySongId,
                                           otherCollections: raw.allCollections,
                                           plays: raw.plays.map { (songId: $0.songId, atMs: $0.playedAt) })
                : PuzzleSimilarity.TargetProfile()
            self.init(songs: raw.songs, genreBySongId: genreBySongId,
                      favoriteIds: raw.favoriteIds, playCounts: raw.playCounts,
                      membershipUnion: membershipUnion,
                      perTargetMembership: raw.targetCollections.map(Set.init),
                      playableNowIds: playable,
                      canStreamAppleMusic: raw.canStreamAppleMusic,
                      similarityProfile: profile,
                      cloudRanks: raw.cloudRanks)
        }
    }

    /// The filtered pool with per-song weights (hard filters applied; soft biases as
    /// multiplicative weights over base 1.0).
    ///
    /// PLAYABILITY ("if it's on screen you hear it") is preferred, not absolute: the pool is
    /// built from playable-now songs, and ONLY if that comes back empty is it rebuilt over
    /// everything. Why the filter exists: a round used to sample the whole catalog, so most
    /// cards had audio no backend could start — and in cloud mode each unresolvable track
    /// makes the shared sequencer advance immediately, so a queue of them burned itself down
    /// to `stop()` within a frame and the round played out in total silence. Why the fallback
    /// is on the RESULT and not on the inputs: "Apple Music can stream" is true on a device
    /// whose catalog carries no catalog ids, so an input-shaped test would enforce a filter
    /// that matches nothing, leave 0 songs, and disable Start forever — the very defect this
    /// change is fixing. A silent round beats an unstartable one.
    ///
    /// SIMILARITY (Levi 2026-08) runs INSIDE this structure, never around it: playability is
    /// the OUTER gate and similarity is the INNER ranker, so a similarity pick that cannot
    /// play is never produced. It can only ever reorder and subset a set that already passed
    /// the playable-now filter, and its starvation guard means it can never empty the pool.
    static func pool(settings: PuzzleSettings, inputs: Inputs,
                     excluding: Set<String> = [],
                     wanted: Int = 60) -> [(song: IndexSong, weight: Double)] {
        let playable = pool(settings: settings, inputs: inputs, excluding: excluding,
                            playableOnly: true)
        if !playable.isEmpty { return similar(playable, settings: settings, inputs: inputs, wanted: wanted) }
        let all = pool(settings: settings, inputs: inputs, excluding: excluding, playableOnly: false)
        return similar(all, settings: settings, inputs: inputs, wanted: wanted)
    }

    /// The similarity re-rank applied to ONE pass's result (see `pool`).
    private static func similar(_ candidates: [(song: IndexSong, weight: Double)],
                                settings: PuzzleSettings, inputs: Inputs,
                                wanted: Int) -> [(song: IndexSong, weight: Double)] {
        PuzzleSimilarity.shortlist(candidates, profile: inputs.similarityProfile,
                                   genreBySongId: inputs.genreBySongId,
                                   cloudRanks: inputs.cloudRanks,
                                   mode: settings.similarity, wanted: wanted)
    }

    /// What the setup screen's readout needs: how many songs match the filters, and how many
    /// of them the similarity ranker actually shortlists. ONE walk, not two detached samples.
    struct PoolStats: Equatable {
        var matched: Int = 0
        /// nil ⇒ similarity is off or there is nothing to be similar to.
        var similar: Int?
    }

    static func poolStats(settings: PuzzleSettings, inputs: Inputs, wanted: Int = 60) -> PoolStats {
        var base = pool(settings: settings, inputs: inputs, excluding: [], playableOnly: true)
        if base.isEmpty {
            base = pool(settings: settings, inputs: inputs, excluding: [], playableOnly: false)
        }
        guard settings.similarity != .off, !inputs.similarityProfile.isEmpty else {
            return PoolStats(matched: base.count, similar: nil)
        }
        let short = similar(base, settings: settings, inputs: inputs, wanted: wanted)
        return PoolStats(matched: base.count, similar: short.count)
    }

    private static func pool(settings: PuzzleSettings, inputs: Inputs,
                             excluding: Set<String>,
                             playableOnly: Bool) -> [(song: IndexSong, weight: Double)] {
        var out: [(IndexSong, Double)] = []
        out.reserveCapacity(inputs.songs.count / 2)
        let hasYearBound = settings.yearMin != nil || settings.yearMax != nil
        for song in inputs.songs {
            if excluding.contains(song.id) { continue }
            // Rip-ON-DEMAND deliberately does NOT count as playable: a fresh capture runs in
            // real time (minutes), which is not audio for a timed rush.
            if playableOnly, !inputs.isPlayableNow(song) { continue }
            // Year: a bound set drops out-of-range songs; nil-year songs drop only
            // when any bound is set (an unbounded round keeps them).
            if hasYearBound {
                guard let year = song.year else { continue }
                if let lo = settings.yearMin, year < lo { continue }
                if let hi = settings.yearMax, year > hi { continue }
            }
            if !settings.genreCategories.isEmpty {
                let cat = inputs.genreBySongId[song.id] ?? Genre.other
                guard settings.genreCategories.contains(cat) else { continue }
            }
            switch settings.membershipMode {
            case .inAny:
                guard inputs.membershipUnion.contains(song.id) else { continue }
            case .notInAny:
                guard !inputs.membershipUnion.contains(song.id) else { continue }
            case .off:
                break
            }
            // Already in EVERY target ⇒ nothing left to assign.
            if !inputs.perTargetMembership.isEmpty,
               inputs.perTargetMembership.allSatisfy({ $0.contains(song.id) }) { continue }

            var weight = 1.0
            switch settings.favoriteBias {
            case .favor: weight *= inputs.favoriteIds.contains(song.id) ? 4.0 : 1.0
            case .avoid: weight *= inputs.favoriteIds.contains(song.id) ? 0.25 : 1.0
            case .off: break
            }
            switch settings.playCountBias {
            case .favor:
                let count = inputs.playCounts[song.id] ?? 0
                weight *= 1 + log2(1 + Double(count))
            case .avoid:
                let count = inputs.playCounts[song.id] ?? 0
                weight *= count == 0 ? 4.0 : 1 / (1 + log2(1 + Double(count)))
            case .off: break
            }
            out.append((song, weight))
        }
        return out
    }

    /// How many songs match the settings (the setup view's "N songs match" footer).
    static func poolCount(settings: PuzzleSettings, inputs: Inputs) -> Int {
        pool(settings: settings, inputs: inputs).count
    }

    /// Weighted sample WITHOUT replacement: n draws over a prefix-sum array with
    /// swap-remove + lazy rebuild. `rng` injected (`PRNG.seededRng` in tests).
    static func sample(_ n: Int, settings: PuzzleSettings, inputs: Inputs,
                       rng: () -> Double, excluding: Set<String> = []) -> [IndexSong] {
        var candidates = pool(settings: settings, inputs: inputs, excluding: excluding, wanted: n)
        guard !candidates.isEmpty else { return [] }
        var picked: [IndexSong] = []
        picked.reserveCapacity(min(n, candidates.count))
        var total = candidates.reduce(0.0) { $0 + $1.weight }
        while picked.count < n && !candidates.isEmpty && total > 0 {
            let target = rng() * total
            // Linear scan is fine at n ≤ ~300: each draw is O(|pool|) worst case, and
            // the whole sample stays well under a frame OFF the main actor.
            var acc = 0.0
            var hit = candidates.count - 1
            for (i, c) in candidates.enumerated() {
                acc += c.weight
                if target < acc { hit = i; break }
            }
            let chosen = candidates[hit]
            picked.append(chosen.song)
            total -= chosen.weight
            candidates.swapAt(hit, candidates.count - 1)
            candidates.removeLast()
        }
        return picked
    }
}
