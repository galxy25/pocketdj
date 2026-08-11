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

        init(id: String, capKey: String, isIncumbent: Bool) {
            self.id = id
            self.capKey = capKey
            self.isIncumbent = isIncumbent
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
    static func compose(_ rows: [Row], limit: Int, maxPerArtist: Int?,
                        incumbentMaxShare: Double) -> [String] {
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
        var out: [String] = []
        var spill: [Row] = []
        var incumbents = 0
        func blocked(_ r: Row) -> Bool {
            !r.capKey.isEmpty && (perArtist[r.capKey] ?? 0) >= cap
        }
        func take(_ r: Row) {
            if !r.capKey.isEmpty { perArtist[r.capKey, default: 0] += 1 }
            out.append(r.id)
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
        return out
    }
}
