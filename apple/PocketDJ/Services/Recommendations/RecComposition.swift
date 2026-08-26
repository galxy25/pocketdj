import Foundation

/// **THE OWNER'S 50% NEWCOMER FLOOR, AS A PURE COMPOSITION FUNCTION.**
///
/// Owner, verbatim: *"the recommendations are so biased on artist similarity, we should cap our
/// for you per collection at max 50% of suggestions for artists that are already in the pocket,
/// that way we can learn the features of related artists to make our recommendations more novel
/// and collection expanding vs model collapse."*
///
/// ── A COMPOSITION CONSTRAINT, NOT A SCORING CHANGE ───────────────────────────────────────────
/// `ZoneEngine.suggestions` ranks exactly as it always has (genre / era / timbre / novelty — none
/// of that moves); THIS composes the final list so rows whose artist is ALREADY IN the collection
/// (INCUMBENT) take at most `incumbentMaxShare` of it. Measured on the owner's real pockets
/// before the floor (scripts/measure-incumbent-share.mjs): **57.9% of all suggestion rows were
/// incumbent-artist rows, 52 of 86 collections sat over 50%, and 13 pockets were 100% incumbent**
/// — a tile that only ever proposes artists a crate already holds cannot expand it, which is the
/// model collapse the owner named.
///
/// ── THE SHAPE: THE 3-PER-ARTIST CAP IDIOM, WITH A FAIL-OPEN REFILL ───────────────────────────
///  1. The list is SIZED first (`n`) — exactly what the plain artist-capped walk would return, so
///     the floor may reorder a list but can never shorten one.
///  2. The ranking is walked IN ORDER, taking every row the artist budget allows EXCEPT incumbents
///     beyond `⌊n · incumbentMaxShare⌋`, which SPILL — newcomers deeper in the ranking are pulled
///     up, and relative order is preserved within each pool.
///  3. FAIL OPEN: when the newcomer pool runs dry (a tiny catalog, heavy filters), the spilled
///     incumbents refill the remainder in order. The floor is a target, never a hole.
///
/// `⌊·⌋` rounds odd counts in the NEWCOMERS' favor (a 5-row list seats at most 2 incumbents), and
/// a list already at or under the cap is untouched — the budget never binds, so the walk is the
/// identical walk.
///
/// ── MIRRORED IN THE LAMBDA ───────────────────────────────────────────────────────────────────
/// `composeIncumbentCap` in `scripts/lambda/rec-engine/index.mjs` is this function in JS (its
/// incumbent question is the transpose — "does this crate already hold the song's artist" — but
/// the compose is one algorithm). `apple/Tests/Fixtures/newcomer-parity.json`, generated through
/// the Lambda's own export, pins the two to identical output — the same fixture-is-the-law
/// arrangement the timbre math lives under.
enum RecComposition {

    /// One ranked candidate, as the compose sees it: identity, the per-artist budget key
    /// (`RecNovelty.primaryArtistKey`; "" ⇒ uncapped), and the incumbent verdict — which the
    /// CALLER settles, via credit identity (`RecVersionIdentity.creditArtistKeys`), because only
    /// the caller knows what "already in the pocket" means for its surface.
    struct Row: Equatable, Sendable {
        let id: String
        let capKey: String
        let isIncumbent: Bool
        /// The RAW genre label this row carries (normalised by `RecSoundAdmit.genreBucket`), or
        /// nil when it has none.
        ///
        /// RAW, never the 15 collapsed categories, and that is the whole reason the field exists.
        /// The variety cost the sound term was measured to impose — new-genre share 29.17% with
        /// the term on against 34.44% with it off (−5.28pp, significant), distinct genres 6.47
        /// against 7.33 per 25 rows — was measured on raw labels. A floor defended in category
        /// space would optimise a number nobody measured, and a category has ~15 values across a
        /// whole catalog, so a 25-row tile can satisfy it while showing one sound.
        let rawGenre: String?
        /// Is this row's raw genre ABSENT from the crate's own members? The replacement order
        /// prefers these, which is how the same one mechanism raises BOTH measured numbers —
        /// distinct-genre count and new-genre share — instead of two constraints failing apart.
        let isNewGenre: Bool

        init(id: String, capKey: String, isIncumbent: Bool,
             rawGenre: String? = nil, isNewGenre: Bool = false) {
            self.id = id
            self.capKey = capKey
            self.isIncumbent = isIncumbent
            self.rawGenre = rawGenre
            self.isNewGenre = isNewGenre
        }
    }

    /// The SOUND-ADMITTED rows and their quota — the rows `RecSoundAdmit` chose, which did not
    /// come through the ranking at all and therefore cannot be composed by it.
    ///
    /// RESERVED SLOTS, not a merge: an admitted row is not comparable to a ranked one (it has no
    /// metadata score — that is the definition of being admitted on sound), so it is SEATED, at
    /// fixed positions, under a hard quota. `nil` ⇒ the phase does not run and the composition is
    /// byte-identical to the one `newcomer-parity.json` pins against the Lambda.
    struct SoundAdmit: Equatable, Sendable {
        var rows: [Row]
        /// Share of the emitted list the quota may take (⌊n · maxShare⌋).
        var maxShare: Double
        /// …and an absolute ceiling regardless of list length.
        var hardCap: Int
        /// Where the first admitted row sits, and how far apart they are. Never index 0: the top
        /// row of a crate's suggestions is the strongest metadata match the engine found, and a
        /// sound guess must not displace it.
        var firstIndex: Int = 4
        var stride: Int = 5

        init(rows: [Row], maxShare: Double, hardCap: Int, firstIndex: Int = 4, stride: Int = 5) {
            self.rows = rows
            self.maxShare = maxShare
            self.hardCap = hardCap
            self.firstIndex = firstIndex
            self.stride = stride
        }
    }

    /// **THE DIVERSITY FLOOR** — a minimum number of distinct RAW genres on the emitted tile.
    ///
    /// Why a floor at all, when the sound term is supposed to be the discovery feature: because
    /// measured on the shipped 25-row tile (artist cap and 50% newcomer floor in force,
    /// permutation-controlled) turning timbre on made the tile MORE faithful to existing labels
    /// and LESS various — 6.47 distinct raw genres against 7.33, and 29.17% new-genre rows
    /// against 34.44%. A term that predicts genre (it does; audio→genre is a 2.9× lift at K=1)
    /// applied inside a pool the gate already restricted to the crate's genres can only sharpen
    /// what is there. The admit quota is the discovery half; THIS is the guard that the re-rank
    /// half does not quietly spend the tile's variety paying for it.
    ///
    /// FAILS OPEN, exactly like the newcomer floor: when no swap can raise the count — a
    /// single-genre catalog, an artist budget in the way — the walk stops and the list stands.
    /// The floor is a target, never a hole, and never a shorter list.
    struct Diversity: Equatable, Sendable {
        var minDistinctRawGenres: Int
        /// A bound on the work AND on the disturbance: each swap moves a row the ranking earned
        /// out of the tile, so the floor is allowed to reshape the list only at its margins.
        var maxSwaps: Int
        /// How deep into the ranking a REPLACEMENT may be drawn from. Two jobs, one number.
        ///
        /// It is a bound on MEANING first: pulling candidate #40,000 into a 25-row tile is not a
        /// diversity floor, it is a random song wearing one — the rows worth promoting are the
        /// near-misses, and past the near-miss region "carries a genre the tile lacks" stops
        /// being evidence of anything. And it is a bound on WORK second: `rows` here is the whole
        /// scored candidate list (tens of thousands on a real catalog) and this walk runs once
        /// per crate, ~40 crates a refresh.
        var searchDepth: Int

        init(minDistinctRawGenres: Int, maxSwaps: Int, searchDepth: Int = 200) {
            self.minDistinctRawGenres = minDistinctRawGenres
            self.maxSwaps = maxSwaps
            self.searchDepth = searchDepth
        }
    }

    /// Compose `rows` (already in final ranked order) into the emitted list.
    ///
    /// - Parameters:
    ///   - limit: the list ceiling (the tile's 25).
    ///   - maxPerArtist: the per-artist budget, applied to `capKey`. `nil` ⇒ no artist cap (the
    ///     Lambda's collection-suggestion rows have no artist to cap).
    ///   - incumbentMaxShare: the owner's cap — ≤ this share of the list may be incumbent rows.
    ///     `≥ 1` disables the floor (the walk is exactly today's); `≤ 0` seats incumbents only
    ///     through the fail-open refill.
    ///   - soundAdmit: rows admitted on AUDIO ALONE, seated at reserved positions under a quota.
    ///     `nil` (the default) ⇒ the phase does not run.
    ///   - diversity: the raw-genre floor. `nil` (the default) ⇒ the phase does not run.
    ///
    /// Both new phases default to `nil` deliberately: `apple/Tests/Fixtures/newcomer-parity.json`
    /// pins this function against the Lambda's `composeIncumbentCap` list-for-list, and the
    /// Lambda has neither phase. With both off the output is the identical walk.
    static func compose(_ rows: [Row], limit: Int, maxPerArtist: Int?,
                        incumbentMaxShare: Double,
                        soundAdmit: SoundAdmit? = nil,
                        diversity: Diversity? = nil) -> [String] {
        // A non-positive budget means UNCAPPED, exactly as the Lambda mirror reads it — the two
        // must agree on every input or the parity fixture is a lie.
        let cap = (maxPerArtist ?? 0) > 0 ? maxPerArtist! : Int.max

        // Phase 0 — the target size: what the plain artist-capped walk returns today. Sized
        // first so the floor cannot starve a list the catalog could fill.
        var n = 0
        var sizing: [String: Int] = [:]
        for r in rows {
            if n >= limit { break }
            if !r.capKey.isEmpty {
                let used = sizing[r.capKey] ?? 0
                if used >= cap { continue }
                sizing[r.capKey] = used + 1
            }
            n += 1
        }
        let incumbentCap = min(n, max(0, Int((Double(n) * incumbentMaxShare).rounded(.down))))

        var perArtist: [String: Int] = [:]
        var out: [Row] = []
        var spill: [Row] = []
        var incumbents = 0
        func blocked(_ r: Row) -> Bool {
            !r.capKey.isEmpty && (perArtist[r.capKey] ?? 0) >= cap
        }
        func take(_ r: Row) {
            if !r.capKey.isEmpty { perArtist[r.capKey, default: 0] += 1 }
            out.append(r)
        }
        // Phase A — the capped walk, incumbents budgeted. A skipped incumbent SPILLS rather than
        // dying: the budget is a deferral, not a filter.
        for r in rows {
            if out.count >= n { break }
            if blocked(r) { continue }
            if r.isIncumbent, incumbents >= incumbentCap { spill.append(r); continue }
            if r.isIncumbent { incumbents += 1 }
            take(r)
        }
        // Phase B — fail open: the newcomer pool ran dry, refill from the spilled incumbents in
        // order. (The artist budget still holds — it is non-negotiable and outranks the floor.)
        for r in spill {
            if out.count >= n { break }
            if blocked(r) { continue }
            take(r)
        }

        // Phase S — SEAT THE SOUND QUOTA. The admitted rows go in at fixed positions and the
        // list is truncated back to `n`, so the quota reorders a tile and can never lengthen or
        // shorten one; the rows it pushes off are the LOWEST-ranked, never the top match.
        var admitted: Set<String> = []
        if let s = soundAdmit, !s.rows.isEmpty, n > 0 {
            let quota = min(max(0, s.hardCap), s.rows.count,
                            max(0, Int((Double(n) * s.maxShare).rounded(.down))))
            var seated = 0
            for r in s.rows {
                if seated >= quota { break }
                if blocked(r) { continue }
                let idx = min(max(0, s.firstIndex + seated * max(1, s.stride)), out.count)
                out.insert(r, at: idx)
                if !r.capKey.isEmpty { perArtist[r.capKey, default: 0] += 1 }
                if r.isIncumbent { incumbents += 1 }
                admitted.insert(r.id)
                seated += 1
            }
            if out.count > n {
                for r in out[n...] {
                    if !r.capKey.isEmpty { perArtist[r.capKey, default: 0] -= 1 }
                    if r.isIncumbent { incumbents -= 1 }
                    admitted.remove(r.id)
                }
                out.removeSubrange(n...)
            }
        }

        // Phase D — THE DIVERSITY FLOOR. Swap the lowest-ranked row whose raw genre is already
        // represented (removing it costs the tile no genre) for the best unused row carrying a
        // genre the tile lacks. Bounded by `maxSwaps`, fails open the moment no such pair exists,
        // and never touches a sound-admitted row — those ARE the variety this is defending.
        if let d = diversity, d.minDistinctRawGenres > 0, d.maxSwaps > 0, !out.isEmpty {
            var seated = Set(out.map(\.id))
            var swaps = 0
            let reachable = rows.prefix(max(d.searchDepth, out.count))
            while swaps < d.maxSwaps {
                var counts: [String: Int] = [:]
                for r in out { if let g = r.rawGenre { counts[g, default: 0] += 1 } }
                if counts.count >= d.minDistinctRawGenres { break }
                // Replacements, best first: a genre the CRATE does not hold beats one it does,
                // then the ranking's own order. (`rows` is already in rank order.)
                let fresh = reachable.filter { r in
                    guard !seated.contains(r.id), let g = r.rawGenre else { return false }
                    return counts[g] == nil
                }
                let candidates = fresh.filter(\.isNewGenre) + fresh.filter { !$0.isNewGenre }
                // THE VICTIM IS CHOSEN FIRST, AND IT IS ALWAYS THE LOWEST-RANKED ROW THE TILE
                // DOES NOT NEED FOR ITS GENRE. Iterating candidates on the outside instead —
                // the obvious shape — lets a candidate whose ARTIST is at its budget walk up the
                // list hunting for a same-artist row to displace, and quietly evict a row from
                // the top of the tile to seat a genre. The floor is allowed to reshape the
                // margins of a ranking, never its head.
                var swapped = false
                victims: for i in stride(from: out.count - 1, through: 0, by: -1) {
                    let victim = out[i]
                    if admitted.contains(victim.id) { continue }
                    if let g = victim.rawGenre, (counts[g] ?? 0) <= 1 { continue }
                    for cand in candidates {
                        // The artist budget outranks the floor (as it outranks the newcomer
                        // floor), measured with the victim's own seat already released.
                        if !cand.capKey.isEmpty {
                            let held = (perArtist[cand.capKey] ?? 0)
                                - (victim.capKey == cand.capKey ? 1 : 0)
                            if held >= cap { continue }
                        }
                        // …and so does the newcomer floor: the floor may not buy variety by
                        // seating an incumbent over the cap.
                        let inc = incumbents - (victim.isIncumbent ? 1 : 0)
                        if cand.isIncumbent, inc >= incumbentCap { continue }
                        if !victim.capKey.isEmpty { perArtist[victim.capKey, default: 0] -= 1 }
                        if !cand.capKey.isEmpty { perArtist[cand.capKey, default: 0] += 1 }
                        incumbents = inc + (cand.isIncumbent ? 1 : 0)
                        seated.remove(victim.id)
                        seated.insert(cand.id)
                        out[i] = cand
                        swaps += 1
                        swapped = true
                        break victims
                    }
                }
                if !swapped { break }
            }
        }
        return out.map(\.id)
    }
}
