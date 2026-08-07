import Foundation

/// Pure weighted sampler behind the Collectors Puzzle queue. No stores, no main-actor —
/// callers snapshot inputs on the main actor (cheap: COW arrays + sets) and run the
/// sampling in a detached task (the Browse off-main doctrine; the pool can be ~100k songs).
enum PuzzleSampler {

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
    }

    /// The filtered pool with per-song weights (hard filters applied; soft biases as
    /// multiplicative weights over base 1.0).
    static func pool(settings: PuzzleSettings, inputs: Inputs,
                     excluding: Set<String> = []) -> [(song: IndexSong, weight: Double)] {
        var out: [(IndexSong, Double)] = []
        out.reserveCapacity(inputs.songs.count / 2)
        let hasYearBound = settings.yearMin != nil || settings.yearMax != nil
        for song in inputs.songs {
            if excluding.contains(song.id) { continue }
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
