import Foundation

/// The PocketDJ selector (docs/design/np-dj-mode.md §4): re-orders a Now Playing session's own
/// upcoming rows into 10-BPM **tempo waves** and genre / year / collection **pockets**, using
/// whatever metadata exists and degrading to the queue's own order when there is none.
///
/// Pure and actor-free (no MainActor state, no randomness beyond the session seed): the same
/// `(current, upcoming, state, options)` always yields the same order.
///
/// ## How it plans
/// A greedy forward simulation, one slot at a time. A `fixed` row keeps its absolute position
/// (pins, hand-moved rows, jukebox inserts, and — marked by the caller — the buffered /
/// non-replaceable NEXT row). Every other slot takes the free candidate with the best score
/// (the §4 table, weights renormalized over the parts KNOWN for that candidate, plus a tiny
/// original-order bonus), and the wave + pocket state is advanced as if that song had played.
///
/// ## State
/// `plan` returns the state with `current` ACCOUNTED (its band / pocket counted) — not the
/// simulated end-of-queue state — so the caller persists it and passes it back on the next
/// re-plan. Accounting is idempotent per row uid (`lastAccountedUid`), so re-plans on queue
/// edits never double-count the playing song.
enum DJSetPlanner {

    // MARK: - Inputs

    /// One upcoming row.
    ///
    /// - `bpm`: RAW tempo; the planner folds it into 80–160 with `InThePocketScorer.foldBpm`.
    /// - `camelot`: a Camelot code ("8A"); anything unparseable counts as unknown.
    /// - `genre`: the tier-1 CATEGORY (`Genre.category(album.genre)`), not the raw label — the
    ///   planner compares it by case-insensitive equality. `Genre.other` / empty = unknown.
    ///   Use `candidate(...)` to build from a raw genre string.
    /// - `year`: song year, else album year.
    /// - `collections`: the ids of every collection the song belongs to (empty = unknown).
    /// - `fixed`: the row keeps its absolute position in the upcoming list.
    struct Candidate: Equatable, Sendable {
        var uid: UUID
        var songId: String
        var bpm: Double?
        var camelot: String?
        var genre: String?
        var year: Int?
        var collections: Set<String>
        var fixed: Bool
        /// AGING: how many earlier plans pushed this row later. Each deferral adds
        /// `agingBonus` to its score, so a poorly fitting row can't be deferred forever in a long
        /// queue (the caller also fixes it after `SetlistPlayer.djMaxDeferrals`).
        var deferrals = 0
        /// The LISTENER chose this song (the next-up slot — Levi 2026-11-09): the set re-anchors
        /// on it (`State.reanchor`) — the songs after it ease from ITS tempo / key / pocket back
        /// into the wave, instead of treating it as a wrong turn. Normally also `fixed`.
        var anchor = false

        init(uid: UUID = UUID(), songId: String, bpm: Double? = nil, camelot: String? = nil,
             genre: String? = nil, year: Int? = nil, collections: Set<String> = [],
             fixed: Bool = false) {
            self.uid = uid; self.songId = songId; self.bpm = bpm; self.camelot = camelot
            self.genre = genre; self.year = year; self.collections = collections; self.fixed = fixed
        }

        var features: Features { Features(self) }
    }

    /// Builds a `Candidate` from the app model's RAW values — the integration seam.
    ///
    /// Expected inputs: `bpm` = the song's detected tempo (raw, unfolded; nil/≤0 = unknown);
    /// `camelot` = the song's Camelot key; `rawGenre` = `album.genre` as stored (it is mapped
    /// through `Genre.category`, and "Other" becomes unknown); `year` = song year, else album
    /// year (≤0 = unknown); `collections` = the song's collection-membership ids
    /// (`CollectionFlattener` / `collectionsInput`); `fixed` = pinned / hand-moved / jukebox
    /// insert / the buffered next row.
    static func candidate(uid: UUID, songId: String, bpm: Double?, camelot: String?,
                          rawGenre: String?, year: Int?, collections: Set<String>,
                          fixed: Bool) -> Candidate {
        let cat = Genre.category(rawGenre)
        return Candidate(uid: uid, songId: songId, bpm: bpm, camelot: camelot,
                         genre: cat == Genre.other ? nil : cat,
                         year: (year ?? 0) > 0 ? year : nil,
                         collections: collections, fixed: fixed)
    }

    /// The normalized, all-optional features of one song.
    struct Features: Codable, Equatable, Sendable {
        /// Folded into [80, 160).
        var bpm: Double?
        /// Normalized ("8A"), nil when unparseable.
        var camelot: String?
        /// Lower-cased category, nil when unknown / "other".
        var genre: String?
        var year: Int?
        var collections: Set<String>

        init(bpm: Double? = nil, camelot: String? = nil, genre: String? = nil, year: Int? = nil,
             collections: Set<String> = []) {
            self.bpm = InThePocketScorer.foldBpm(bpm)
            self.camelot = camelot.flatMap(DJSetPlanner.normalizedCamelot)
            let g = genre?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.genre = (g?.isEmpty ?? true) || g == Genre.other.lowercased() ? nil : g
            self.year = (year ?? 0) > 0 ? year : nil
            self.collections = collections
        }

        init(_ c: Candidate) {
            self.init(bpm: c.bpm, camelot: c.camelot, genre: c.genre, year: c.year,
                      collections: c.collections)
        }

        /// The 10-BPM band's lower bound (`floor(bpm/10)*10`), nil without a tempo.
        var band: Int? { bpm.map { Int(($0 / 10).rounded(.down)) * 10 } }

        /// Has anything a pocket can compare.
        var hasPocketData: Bool { genre != nil || year != nil || !collections.isEmpty }
    }

    /// Mirrors the Settings ▸ DJ Mode selector toggles. All off ⇒ the queue's own order.
    struct Options: Equatable, Sendable {
        /// Tempo waves: band fit AND BPM closeness to the previous song.
        var tempoWaves = true
        /// Genre / year / collection pockets.
        var pockets = true
        /// Camelot key fit to the previous song.
        var key = true

        static let allOn = Options()
    }

    enum Direction: Int, Codable, Sendable { case up = 1, down = -1
        var flipped: Direction { self == .up ? .down : .up }
    }

    /// The session's wave + pocket position. Persist it with the session; start with
    /// `State(seed:)`.
    struct State: Codable, Equatable, Sendable {
        /// The session seed (wave + pocket lengths derive from it).
        var seed: UInt64
        /// The current band's lower bound; nil until a song with a tempo plays.
        var band: Int?
        /// Songs (with a tempo) played in `band` this visit — the ≥3 rule.
        var playedInBand = 0
        var direction: Direction = .up
        /// Band steps taken in the current wave direction.
        var bandSteps = 0
        /// Waves started so far (indexes the seeded wave length).
        var waveIndex = 0
        /// Band steps before this wave flips (2–3, seeded).
        var waveLength: Int
        /// The current pocket's anchor (its first song); nil until a song with pocket data plays.
        var pocketAnchor: Features?
        /// Songs (with pocket data) in the current pocket.
        var pocketCount = 0
        /// Pockets started so far (indexes the seeded pocket length).
        var pocketIndex = 0
        /// Songs in this pocket (3–4, seeded).
        var pocketLength: Int
        /// The last row uid accounted — makes re-accounting the playing song a no-op.
        var lastAccountedUid: UUID?

        init(seed: UInt64) {
            self.seed = seed
            waveLength = DJSetPlanner.waveLength(seed: seed, index: 0)
            pocketLength = DJSetPlanner.pocketLength(seed: seed, index: 0)
        }

        /// The pocket is full (or none yet) — the next song with pocket data anchors a new one.
        var needsNewPocket: Bool { pocketAnchor == nil || pocketCount >= pocketLength }
    }

    // MARK: - Constants

    static let bandWidth = 10
    static let minPerBand = 3
    static let weightBand = 0.35
    static let weightBpm = 0.2
    static let weightKey = 0.2
    static let weightPocket = 0.25
    static let orderBonus = 0.02
    /// Score added per deferral (aging): ~10 deferrals outweigh a full mismatch on one part.
    static let agingBonus = 0.03
    /// A candidate with NO known scoring part scores this (before the order bonus) — the
    /// renormalized score has no denominator, and 0 would count missing data against it.
    static let neutralScore = 0.5
    /// "Near adjacent" next-pocket anchor similarity window.
    static let nearAdjacent: ClosedRange<Double> = 0.3...0.8

    /// Band steps per wave (2 or 3) — deterministic per session seed + wave index.
    static func waveLength(seed: UInt64, index: Int) -> Int {
        2 + Int(hash(seed, 0x57A7E, index) % 2)
    }

    /// Songs per pocket (3 or 4) — deterministic per session seed + pocket index.
    static func pocketLength(seed: UInt64, index: Int) -> Int {
        3 + Int(hash(seed, 0x90C4E7, index) % 2)
    }

    // MARK: - Plan

    /// Re-orders `upcoming`. Returns every upcoming uid exactly once, `fixed` rows at their
    /// original indexes, plus `state` with `current` accounted (see the type doc).
    static func plan(current: Candidate?, upcoming: [Candidate], state: State,
                     options: Options) -> (order: [UUID], state: State) {
        var committed = state
        var prev: Features?
        if let current {
            if current.anchor {
                committed.reanchor(current.features, uid: current.uid, options: options)
            } else {
                committed.account(current.features, uid: current.uid, options: options)
            }
            prev = current.features
        }
        guard !upcoming.isEmpty else { return ([], committed) }

        let n = upcoming.count
        let feats = upcoming.map(\.features)
        let aged = upcoming.map(\.deferrals)
        var free = Set(upcoming.indices.filter { !upcoming[$0].fixed })
        var sim = committed
        var order: [UUID] = []
        order.reserveCapacity(n)

        for slot in 0..<n {
            let pick: Int
            if upcoming[slot].fixed {
                pick = slot
            } else {
                pick = best(free: free, feats: feats, aged: aged, n: n, prev: prev, sim: &sim, options: options)
                free.remove(pick)
            }
            order.append(upcoming[pick].uid)
            if upcoming[pick].anchor {
                sim.reanchor(feats[pick], uid: upcoming[pick].uid, options: options)
            } else {
                sim.account(feats[pick], uid: upcoming[pick].uid, options: options)
            }
            prev = carried(prev, feats[pick])
        }
        return (order, committed)
    }

    /// The "previous song" the next one is matched against: the placed song, with the last KNOWN
    /// tempo and key carried through songs that lack them (a no-BPM song never breaks the
    /// tempo / key chain).
    private static func carried(_ prev: Features?, _ f: Features) -> Features {
        var p = f
        if p.bpm == nil { p.bpm = prev?.bpm }
        if p.camelot == nil { p.camelot = prev?.camelot }
        return p
    }

    /// The best free candidate for the next slot (ties → earlier original index). May flip the
    /// simulated wave direction while resolving the target band.
    private static func best(free: Set<Int>, feats: [Features], aged: [Int], n: Int, prev: Features?,
                             sim: inout State, options: Options) -> Int {
        let target = options.tempoWaves ? sim.resolveTarget(freeBands: free.compactMap { feats[$0].band }) : nil

        // Pockets: inside a pocket score similarity to its anchor; at a pocket boundary prefer
        // a "near adjacent" anchor (similarity to the last pocket in [0.3, 0.8]) — if no free
        // candidate is near adjacent the pocket part drops out and the rest picks the best.
        var pocketMode: PocketMode = .off
        if options.pockets {
            if let anchor = sim.pocketAnchor {
                if sim.needsNewPocket {
                    let anyNear = free.contains { i in
                        similarity(feats[i], anchor).map { nearAdjacent.contains($0) } ?? false
                    }
                    pocketMode = anyNear ? .nearAdjacent(anchor) : .off
                } else {
                    pocketMode = .inPocket(anchor)
                }
            }
        }

        var bestIndex = -1
        var bestScore = -Double.infinity
        for i in free.sorted() {
            let s = score(feats[i], index: i, n: n, prev: prev, target: target,
                          pocket: pocketMode, options: options) + agingBonus * Double(max(0, aged[i]))
            if s > bestScore { bestScore = s; bestIndex = i }
        }
        return bestIndex
    }

    enum PocketMode { case off, inPocket(Features), nearAdjacent(Features) }

    /// The §4 next-song score: Σ wᵢ·partᵢ / Σ wᵢ over the KNOWN parts (neutral when none),
    /// plus the original-order bonus `0.02·(1 − i/n)`.
    static func score(_ f: Features, index: Int, n: Int, prev: Features?, target: Int?,
                      pocket: PocketMode, options: Options) -> Double {
        var sum = 0.0, weight = 0.0
        if options.tempoWaves {
            if let target, let b = f.band {
                let d = abs(b - target)
                sum += weightBand * (d == 0 ? 1 : d == bandWidth ? 0.4 : 0)
                weight += weightBand
            }
            if let a = prev?.bpm, let b = f.bpm {
                sum += weightBpm * exp(-abs(a - b) / 10)
                weight += weightBpm
            }
        }
        if options.key, let a = prev?.camelot, let b = f.camelot {
            sum += weightKey * SimilarityFamilies.camelotRelatedness(a, b)
            weight += weightKey
        }
        switch pocket {
        case .off: break
        case .inPocket(let anchor):
            if let s = similarity(f, anchor) { sum += weightPocket * s; weight += weightPocket }
        case .nearAdjacent(let anchor):
            if let s = similarity(f, anchor) {
                sum += weightPocket * (nearAdjacent.contains(s) ? 1 : 0)
                weight += weightPocket
            }
        }
        let base = weight > 0 ? sum / weight : neutralScore
        return base + orderBonus * (1 - Double(index) / Double(max(n, 1)))
    }

    /// Pocket similarity — genre (same category 1, else 0), year `exp(-|Δy|/6)`, collections
    /// Jaccard — averaged over the parts both songs know; nil when none.
    static func similarity(_ a: Features, _ b: Features) -> Double? {
        var sum = 0.0, count = 0.0
        if let x = a.genre, let y = b.genre { sum += x == y ? 1 : 0; count += 1 }
        if let x = a.year, let y = b.year { sum += exp(-Double(abs(x - y)) / 6); count += 1 }
        if !a.collections.isEmpty, !b.collections.isEmpty {
            let inter = a.collections.intersection(b.collections).count
            let union = a.collections.union(b.collections).count
            sum += Double(inter) / Double(union); count += 1
        }
        return count > 0 ? sum / count : nil
    }

    // MARK: - Helpers

    /// "8a" / " 08B " → "8A" / "8B"; nil when not a Camelot code.
    static func normalizedCamelot(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = s.last, letter == "A" || letter == "B",
              let n = Int(s.dropLast()), (1...12).contains(n) else { return nil }
        return "\(n)\(letter)"
    }

    /// SplitMix64 finalizer over (seed, salt, index) — the planner's only source of variety.
    static func hash(_ seed: UInt64, _ salt: UInt64, _ index: Int) -> UInt64 {
        var z = seed &+ salt &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(index)) &* 0xD6E8_FEB8_6659_FD93
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Wave / pocket state machine

extension DJSetPlanner.State {
    /// Advances the state as if a song with `f` had just played. Songs without a tempo leave
    /// the wave alone; songs without pocket data leave the pocket alone. Idempotent per uid.
    mutating func account(_ f: DJSetPlanner.Features, uid: UUID, options: DJSetPlanner.Options) {
        if let uid0 = lastAccountedUid, uid0 == uid { return }
        lastAccountedUid = uid

        if let b = f.band {
            if let cur = band, cur != b {
                let moved: DJSetPlanner.Direction = b > cur ? .up : .down
                if moved == direction {
                    bandSteps += 1
                } else {
                    // The song moved AGAINST the wave (a fixed row / a sparse fallback): that
                    // starts a new wave in the direction it moved.
                    startWave(moved)
                    bandSteps = 1
                }
                band = b
                playedInBand = 1
            } else {
                band = b
                playedInBand += 1
            }
        }

        if options.pockets, f.hasPocketData {
            if needsNewPocket {
                if pocketAnchor != nil {
                    pocketIndex += 1
                    pocketLength = DJSetPlanner.pocketLength(seed: seed, index: pocketIndex)
                }
                pocketAnchor = f
                pocketCount = 1
            } else {
                pocketCount += 1
            }
        }
    }

    /// A LISTENER-CHOSEN song plays (`Candidate.anchor`): the set re-anchors on it. Its band
    /// becomes the band (a fresh visit); a jump of ≥ 2 bands from where the set was starts a new
    /// wave heading BACK toward it (the next songs ease from the pick back into the wave rather
    /// than racing on past it); and it anchors a fresh pocket (what follows sounds like it).
    /// Missing parts leave that part of the state alone, as `account` does. Idempotent per uid.
    mutating func reanchor(_ f: DJSetPlanner.Features, uid: UUID, options: DJSetPlanner.Options) {
        if let uid0 = lastAccountedUid, uid0 == uid { return }
        lastAccountedUid = uid
        if let b = f.band {
            if let was = band, abs(b - was) >= 2 * DJSetPlanner.bandWidth {
                startWave(b > was ? .down : .up)
            }
            band = b
            playedInBand = 1
        }
        if options.pockets, f.hasPocketData {
            if pocketAnchor != nil {
                pocketIndex += 1
                pocketLength = DJSetPlanner.pocketLength(seed: seed, index: pocketIndex)
            }
            pocketAnchor = f
            pocketCount = 1
        }
    }

    private mutating func startWave(_ d: DJSetPlanner.Direction) {
        direction = d
        bandSteps = 0
        waveIndex += 1
        waveLength = DJSetPlanner.waveLength(seed: seed, index: waveIndex)
    }

    /// The band the next song should come from, given the bands of the free candidates (one
    /// entry per candidate with a tempo). Flips the wave when it has run its length, or EARLY
    /// at the pool edge (no candidate further in the wave direction). nil ⇒ no band target.
    mutating func resolveTarget(freeBands: [Int]) -> Int? {
        guard let cur = band, !freeBands.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for b in freeBands { counts[b, default: 0] += 1 }
        let minPer = DJSetPlanner.minPerBand

        // Stay for ≥3 (counting what already played here) while the band still has songs.
        if playedInBand < minPer, counts[cur, default: 0] > 0 { return cur }

        /// The nearest band strictly beyond `cur` in `d` with at least `need` candidates.
        func nearest(_ d: DJSetPlanner.Direction, need: Int) -> Int? {
            counts.filter { (b, c) in c >= need && (b - cur) * d.rawValue > 0 }
                .keys.min { abs($0 - cur) < abs($1 - cur) }
        }

        if bandSteps >= waveLength { startWave(direction.flipped) }
        // A band too sparse to hold ≥3 is skipped toward the nearest populated band.
        if let b = nearest(direction, need: minPer) { return b }
        // Pool edge: nothing populated further this way — flip early.
        if let b = nearest(direction.flipped, need: minPer) {
            startWave(direction.flipped); return b
        }
        // Nothing populated either way: the nearest sparse band, this way then the other.
        if let b = nearest(direction, need: 1) { return b }
        if let b = nearest(direction.flipped, need: 1) {
            startWave(direction.flipped); return b
        }
        // Only the current band is left.
        return counts[cur, default: 0] > 0 ? cur : nil
    }
}
