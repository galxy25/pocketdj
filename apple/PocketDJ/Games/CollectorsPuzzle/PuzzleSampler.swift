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

        init(songs: [IndexSong], genreBySongId: [String: String], favoriteIds: Set<String>,
             playCounts: [String: Int], membershipUnion: Set<String>,
             perTargetMembership: [Set<String>],
             playableNowIds: Set<String> = [], canStreamAppleMusic: Bool = false) {
            self.songs = songs
            self.genreBySongId = genreBySongId
            self.favoriteIds = favoriteIds
            self.playCounts = playCounts
            self.membershipUnion = membershipUnion
            self.perTargetMembership = perTargetMembership
            self.playableNowIds = playableNowIds
            self.canStreamAppleMusic = canStreamAppleMusic
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
            for song in raw.songs {
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
            self.init(songs: raw.songs, genreBySongId: genreBySongId,
                      favoriteIds: raw.favoriteIds, playCounts: raw.playCounts,
                      membershipUnion: membershipUnion,
                      perTargetMembership: raw.targetCollections.map(Set.init),
                      playableNowIds: playable,
                      canStreamAppleMusic: raw.canStreamAppleMusic)
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
    static func pool(settings: PuzzleSettings, inputs: Inputs,
                     excluding: Set<String> = []) -> [(song: IndexSong, weight: Double)] {
        let playable = pool(settings: settings, inputs: inputs, excluding: excluding,
                            playableOnly: true)
        if !playable.isEmpty { return playable }
        return pool(settings: settings, inputs: inputs, excluding: excluding, playableOnly: false)
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
        var candidates = pool(settings: settings, inputs: inputs, excluding: excluding)
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
