import Foundation

/// IN THE POCKET — the round builder. PURE and DETERMINISTIC: the same `Input` (seed included)
/// always yields the same round, so a round can be replayed from what was uploaded, and every
/// rule here is unit-testable without a catalog, a player or a network.
///
/// ── THE PROFILE (what "a pocket here, now" sounds like) ──────────────────────────────────────
/// `.cloud`   — the cloud's pockets + patterns whose context matches NOW. A source must share the
///              time bucket; weekday/weekend and the place/trip add to its weight; a pattern counts
///              more than a one-off pocket (1 + ln occurrences). Its MUSICAL defining features
///              (genre, artist, mood, key) become weighted targets (weight += match · feature
///              score), its BPM range a band, its member / top songs "seed songs".
/// `.history` — no matching cloud results: the same profile from this device's own plays in this
///              context (same bucket + day type, else same bucket): each genre/artist weighted by
///              its share of the NON-SKIPPED plays there times its lift over all listening (capped),
///              the band = the middle half of their BPMs, seeds = the songs played through there.
/// `.cold`    — nothing for this context either: the same, over every non-skipped play.
/// Round learning (cloud `rounds` section, else the same formula over this device's finished
/// rounds) then MULTIPLIES each target's weight for this context, and adds targets that keep
/// predicting well (multiplier ≥ 1.25 on ≥ 2 positive rounds).
///
/// ── THE SCORE (per playable candidate) ───────────────────────────────────────────────────────
///   Σ matched target weights            (genre / artist / mood / camelot)
/// + 0.6 · bpm fit                        (1 inside the band, e^(−distance/8) outside)
/// + 0.8 · seed-song strength             (normalised)
/// + familiarity                          (0.6 · (playThroughRate − ½) + 0.3 · min(plays, 5)/5)
/// A candidate that matches nothing of the profile (no target, no band, not a seed) is dropped.
///
/// ── THE PICK ─────────────────────────────────────────────────────────────────────────────────
/// Top 40 by score (ties → id). Song 1 is a seeded weighted draw (score²) from the top 8; each
/// next song re-scores the rest for COHERENCE with what is already picked (+0.3 shared genre,
/// +0.3 · e^(−|ΔBPM|/10)) and DIVERSITY (−1 per already-picked song by the same artist), then
/// draws from the top 6. Four songs for `.cloud`, three otherwise (a weaker profile makes a
/// shorter, fairer bet — three is the pocket minimum).
enum InThePocketScorer {

    static let algoVersion = 1

    // MARK: - Input

    /// What the scorer knows about a song. Built from the catalog (genre category via the album).
    struct Song: Sendable, Equatable {
        var id: String
        var title: String
        var artist: String
        var lengthMs: Int?
        /// `Genre.category` — the same vocabulary as the cloud's `g` (lowercased).
        var genre: String?
        var bpm: Double?
        var camelot: String?
        var moods: [String] = []
    }

    /// One play from the history log, reduced to what matters here.
    struct Play: Sendable, Equatable {
        var songId: String
        var atMs: Double
        var tzOffsetMin: Int
        /// `PlayEvent.outcome` raw value: completed | skipped | partial | unknown.
        var outcome: String
        var ctx: ListeningContextTag?
        var isSkip: Bool { outcome == "skipped" }
    }

    struct Input: Sendable {
        var context: InThePocketContext
        /// Display label for `context.ctx` ("Location A", "A → B").
        var contextLabel: String?
        var results: ListeningPocketsResults?
        /// Every song the scorer may describe (playable or not — history songs need genres too).
        var catalog: [String: Song]
        /// Songs that can make sound right now. Only these are ever picked.
        var playableIds: Set<String>
        var plays: [Play]
        /// This device's finished rounds — the local round-learning fallback + variety exclusion.
        var pastRounds: [InThePocketRound] = []
        var nowMs: Double
        var seed: UInt64
        /// Songs played (anywhere) within this window are not picked.
        var recentExclusionMs: Double = 48 * 3_600_000
    }

    struct Pick: Sendable, Equatable {
        var song: Song
        var score: Double
        var why: [String]
    }

    struct Output: Sendable, Equatable {
        var mode: InThePocketMode
        var targets: [InThePocketTarget]
        var bpmBand: ClosedRange<Double>?
        var picks: [Pick]
        /// The round's "why" chips: "Weekday evening · Location A · 118–126 BPM · Funk/Soul".
        var chips: [String]
    }

    enum Failure: Error, Equatable {
        /// Nothing playable right now (no Apple Music, nothing ripped or downloaded).
        case nothingPlayable
        /// Fewer than three songs fit — play more music first.
        case notEnoughCandidates
    }

    // MARK: - Tuning (one place)

    static let maxTargets = 6
    static let bpmWeight = 0.6
    static let seedWeight = 0.8
    static let topK = 40
    static let firstDrawFrom = 8
    static let nextDrawFrom = 6
    static let minContextPlays = 5
    static let learningAddMin = 1.25

    // MARK: - Build

    static func build(_ input: Input) -> Result<Output, Failure> {
        let candidatesAll = input.playableIds.compactMap { input.catalog[$0] }
        guard !candidatesAll.isEmpty else { return .failure(.nothingPlayable) }

        var profile = cloudProfile(input) ?? historyProfile(input)
        applyLearning(&profile, input: input)

        // Exclusions: anything played recently, and the songs of the last three rounds.
        let cutoff = input.nowMs - input.recentExclusionMs
        var excluded = Set(input.plays.filter { $0.atMs >= cutoff }.map(\.songId))
        for r in input.pastRounds.sorted(by: { $0.createdAtMs > $1.createdAtMs }).prefix(3) {
            excluded.formUnion(r.songs.map(\.id))
        }
        let familiarity = Self.familiarity(input.plays)
        let maxSeed = profile.seedSongs.values.max() ?? 0

        var scored: [Pick] = []
        for c in candidatesAll where !excluded.contains(c.id) {
            var s = 0.0
            var why: [String] = []
            var related = false
            for t in profile.targets where matches(c, t) {
                s += t.weight; why.append(t.label); related = true
            }
            if let band = profile.bpmBand, let b = foldBpm(c.bpm) {
                let d = band.contains(b) ? 0 : min(abs(b - band.lowerBound), abs(b - band.upperBound))
                let fit = d == 0 ? 1 : exp(-d / 8)
                s += bpmWeight * fit
                if d == 0 { why.append("\(Int(b.rounded())) BPM"); related = true }
            }
            if maxSeed > 0, let w = profile.seedSongs[c.id] {
                s += seedWeight * (w / maxSeed); why.append("From your pockets"); related = true
            }
            guard related else { continue }
            s += familiarity[c.id] ?? 0
            scored.append(Pick(song: c, score: s, why: why))
        }
        let count = profile.mode == .cloud ? 4 : 3
        guard scored.count >= 3 else { return .failure(.notEnoughCandidates) }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.song.id < $1.song.id }
        var pool = Array(scored.prefix(topK))
        var rng = SplitMix64(seed: input.seed)
        var picks: [Pick] = []
        while picks.count < min(count, scored.count), !pool.isEmpty {
            let ranked: [(Int, Double)]
            if picks.isEmpty {
                ranked = pool.indices.map { ($0, pool[$0].score) }
            } else {
                ranked = pool.indices.map { i in (i, pool[i].score + coherence(pool[i].song, with: picks)) }
                    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : pool[$0.0].song.id < pool[$1.0].song.id }
            }
            let window = Array(ranked.prefix(picks.isEmpty ? firstDrawFrom : nextDrawFrom))
            let chosen = weightedDraw(window, rng: &rng)
            picks.append(pool[chosen])
            pool.remove(at: chosen)
        }
        guard picks.count >= 3 else { return .failure(.notEnoughCandidates) }
        return .success(Output(mode: profile.mode, targets: profile.targets, bpmBand: profile.bpmBand,
                               picks: picks, chips: chips(input: input, profile: profile)))
    }

    // MARK: - Profiles

    struct Profile: Equatable {
        var mode: InThePocketMode
        var targets: [InThePocketTarget]
        var bpmBand: ClosedRange<Double>?
        var seedSongs: [String: Double]
    }

    static let musicalDims: Set<String> = ["genre", "artist", "mood", "camelot"]

    /// How well a cloud source's context matches now: 0 unless the time bucket matches; +1 day
    /// type; +2 the same place / trip.
    static func contextMatch(timeBucket: String?, dayType: String?, ctx: ListeningContextTag?,
                             to now: InThePocketContext) -> Double {
        guard timeBucket == now.timeBucket else { return 0 }
        var m = 2.0
        if dayType == now.dayType { m += 1 }
        if let ctx, let mine = now.ctx {
            if ctx.isTrip, mine.isTrip, ctx.tripId == mine.tripId { m += 2 }
            if ctx.isPlace, mine.isPlace, ctx.placeId == mine.placeId { m += 2 }
        }
        return m
    }

    static func cloudProfile(_ input: Input) -> Profile? {
        guard let results = input.results, results.generatedAtMs != nil else { return nil }
        var acc: [String: (target: InThePocketTarget, w: Double)] = [:]
        var seeds: [String: Double] = [:]
        var bandLo = 0.0, bandHi = 0.0, bandW = 0.0
        var any = false
        func absorb(features: [ListeningPocketFeature], numeric: [String: ListeningPocketNumeric],
                    songIds: [(String, Double)], weight w: Double) {
            any = true
            for f in features where musicalDims.contains(f.dim) && f.score > 0 {
                let key = f.dim + "\u{0}" + f.value
                var cur = acc[key] ?? (InThePocketTarget(dim: f.dim, value: f.value, label: f.label, weight: 0), 0)
                cur.w += w * f.score
                acc[key] = cur
            }
            if let bpm = numeric["bpm"], bpm.defining || bpm.coverage >= 0.6 {
                bandLo += w * bpm.lo; bandHi += w * bpm.hi; bandW += w
            }
            for (id, n) in songIds { seeds[id, default: 0] += w * n }
        }
        for p in results.patterns {
            let m = contextMatch(timeBucket: p.timeBucket, dayType: p.dayType, ctx: p.ctx, to: input.context)
            guard m > 0 else { continue }
            let w = m * (1 + log(Double(max(1, p.occurrences))))
            absorb(features: p.features, numeric: p.numeric,
                   songIds: p.topSongs.map { ($0.songId, Double(max(1, $0.plays))) }, weight: w)
        }
        for p in results.pockets {
            let m = contextMatch(timeBucket: p.timeBucket, dayType: p.dayType, ctx: p.ctx, to: input.context)
            guard m > 0 else { continue }
            absorb(features: p.features, numeric: p.numeric, songIds: p.songIds.map { ($0, 1) }, weight: 0.5 * m)
        }
        guard any else { return nil }
        let band: ClosedRange<Double>? = bandW > 0 ? normalizedBand(bandLo / bandW, bandHi / bandW) : nil
        guard !acc.isEmpty || band != nil || !seeds.isEmpty else { return nil }
        return Profile(mode: .cloud, targets: normalize(acc.values.map { var t = $0.target; t.weight = $0.w; return t }),
                       bpmBand: band, seedSongs: seeds)
    }

    static func historyProfile(_ input: Input) -> Profile {
        let ctx = input.context
        let withCtx = input.plays.map { p in (p, InThePocketContext.make(atMs: p.atMs, tzOffsetMin: p.tzOffsetMin, ctx: nil)) }
        var inContext = withCtx.filter { $0.1.timeBucket == ctx.timeBucket && $0.1.dayType == ctx.dayType }.map(\.0)
        if let here = ctx.ctxKey {
            let atPlace = inContext.filter { p in
                InThePocketContext.make(atMs: p.atMs, tzOffsetMin: p.tzOffsetMin, ctx: p.ctx).ctxKey == here
            }
            if atPlace.count >= minContextPlays { inContext = atPlace }
        }
        if inContext.count < minContextPlays {
            inContext = withCtx.filter { $0.1.timeBucket == ctx.timeBucket }.map(\.0)
        }
        let mode: InThePocketMode = inContext.count >= minContextPlays ? .history : .cold
        let basis = mode == .history ? inContext : input.plays
        let kept = basis.filter { !$0.isSkip }
        let allKept = input.plays.filter { !$0.isSkip }

        func shares(_ plays: [Play], _ key: (Song) -> [String]) -> [String: Double] {
            var counts: [String: Double] = [:]
            var n = 0.0
            for p in plays {
                guard let s = input.catalog[p.songId] else { continue }
                n += 1
                for k in key(s) { counts[k, default: 0] += 1 }
            }
            guard n > 0 else { return [:] }
            return counts.mapValues { $0 / n }
        }
        var targets: [InThePocketTarget] = []
        for (dim, key) in [("genre", { (s: Song) in s.genre.map { [$0] } ?? [] }),
                           ("artist", { (s: Song) in [s.artist.lowercased()] })] as [(String, (Song) -> [String])] {
            let here = shares(kept, key)
            let overall = shares(allKept, key)
            for (value, share) in here where share >= 0.15 {
                let lift = min(3, max(0.5, share / max(overall[value] ?? share, 0.01)))
                let label: String
                if dim == "genre" { label = genreLabel(value) } else {
                    label = kept.lazy.compactMap { input.catalog[$0.songId] }
                        .first { $0.artist.lowercased() == value }?.artist ?? value
                }
                targets.append(InThePocketTarget(dim: dim, value: value, label: label, weight: share * lift))
            }
        }
        let bpms = kept.compactMap { input.catalog[$0.songId].flatMap { foldBpm($0.bpm) } }.sorted()
        var band: ClosedRange<Double>?
        if bpms.count >= 3 {
            band = normalizedBand(bpms[bpms.count / 4], bpms[(bpms.count * 3) / 4])
        }
        var seeds: [String: Double] = [:]
        for p in basis { seeds[p.songId, default: 0] += p.isSkip ? -2 : 1 }
        seeds = seeds.filter { $0.value > 0 }
        return Profile(mode: mode, targets: normalize(targets), bpmBand: band, seedSongs: seeds)
    }

    /// Weights scaled so the strongest target is 1; top `maxTargets` by weight (ties → dim, value).
    static func normalize(_ targets: [InThePocketTarget]) -> [InThePocketTarget] {
        let top = targets.filter { $0.weight > 0 }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : ($0.dim, $0.value) < ($1.dim, $1.value) }
            .prefix(maxTargets)
        guard let m = top.first?.weight, m > 0 else { return [] }
        return top.map { var t = $0; t.weight = (t.weight / m * 1000).rounded() / 1000; return t }
    }

    /// A band at least 6 BPM wide, rounded to whole beats.
    static func normalizedBand(_ lo: Double, _ hi: Double) -> ClosedRange<Double> {
        var a = min(lo, hi).rounded(), b = max(lo, hi).rounded()
        if b - a < 6 { let mid = (a + b) / 2; a = (mid - 3).rounded(.down); b = (mid + 3).rounded(.up) }
        return a...b
    }

    // MARK: - Round learning

    /// "dim\0value" → multiplier for this context: the cloud's `rounds` section (exact key, then
    /// relaxed), else the SAME formula over this device's own finished rounds.
    static func learning(for input: Input) -> [String: (multiplier: Double, pos: Int)] {
        let keys = input.context.learningKeys
        if let cloud = input.results?.roundLearning {
            for k in keys {
                if let c = cloud.contexts.first(where: { $0.key == k }) {
                    return Dictionary(c.weights.map { ($0.dim + "\u{0}" + $0.value, ($0.multiplier, $0.pos)) },
                                      uniquingKeysWith: { a, _ in a })
                }
            }
        }
        let local = InThePocketLearning.contexts(input.pastRounds)
        for k in keys {
            if let c = local[k] { return c.mapValues { ($0.multiplier, $0.pos) } }
        }
        return [:]
    }

    static func applyLearning(_ profile: inout Profile, input: Input) {
        let learned = learning(for: input)
        guard !learned.isEmpty else { return }
        var present = Set<String>()
        for i in profile.targets.indices {
            let key = profile.targets[i].dim + "\u{0}" + profile.targets[i].value
            present.insert(key)
            if let l = learned[key] { profile.targets[i].weight = (profile.targets[i].weight * l.multiplier * 1000).rounded() / 1000 }
        }
        for (key, l) in learned.sorted(by: { $0.key < $1.key })
        where !present.contains(key) && l.multiplier >= learningAddMin && l.pos >= 2 {
            let parts = key.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            guard parts.count == 2, musicalDims.contains(parts[0]) else { continue }
            let label = parts[0] == "genre" ? genreLabel(parts[1]) : parts[1].capitalized
            profile.targets.append(InThePocketTarget(dim: parts[0], value: parts[1], label: label,
                                                     weight: (0.3 * l.multiplier * 1000).rounded() / 1000))
        }
        profile.targets.sort { $0.weight != $1.weight ? $0.weight > $1.weight : ($0.dim, $0.value) < ($1.dim, $1.value) }
    }

    // MARK: - Pieces

    static func matches(_ s: Song, _ t: InThePocketTarget) -> Bool {
        switch t.dim {
        case "genre": return s.genre?.lowercased() == t.value
        case "artist": return s.artist.lowercased() == t.value
        case "mood": return s.moods.contains { $0.lowercased() == t.value }
        case "camelot": return s.camelot?.uppercased() == t.value.uppercased()
        default: return false
        }
    }

    static func coherence(_ s: Song, with picked: [Pick]) -> Double {
        var c = 0.0
        if let g = s.genre, picked.contains(where: { $0.song.genre == g }) { c += 0.3 }
        let bpms = picked.compactMap { foldBpm($0.song.bpm) }
        if let b = foldBpm(s.bpm), !bpms.isEmpty {
            let mean = bpms.reduce(0, +) / Double(bpms.count)
            c += 0.3 * exp(-abs(b - mean) / 10)
        }
        let sameArtist = picked.filter { $0.song.artist.lowercased() == s.artist.lowercased() }.count
        c -= Double(sameArtist)
        return c
    }

    /// Per song: 0.6 · (play-through rate − ½) + 0.3 · min(plays, 5)/5 — Laplace-smoothed, so a
    /// never-played song is exactly 0 and a song the user keeps skipping goes negative.
    static func familiarity(_ plays: [Play]) -> [String: Double] {
        var through: [String: Int] = [:], skips: [String: Int] = [:]
        for p in plays {
            if p.isSkip { skips[p.songId, default: 0] += 1 } else { through[p.songId, default: 0] += 1 }
        }
        var out: [String: Double] = [:]
        for id in Set(through.keys).union(skips.keys) {
            let n = Double(through[id] ?? 0), k = Double(skips[id] ?? 0)
            let rate = (n + 1) / (n + k + 2)
            out[id] = 0.6 * (rate - 0.5) + 0.3 * min(n, 5) / 5
        }
        return out
    }

    /// Seeded draw proportional to max(score, 0.01)².
    static func weightedDraw(_ window: [(Int, Double)], rng: inout SplitMix64) -> Int {
        let weights = window.map { pow(max($0.1, 0.01), 2) }
        let total = weights.reduce(0, +)
        var r = rng.nextUnit() * total
        for (i, w) in weights.enumerated() {
            r -= w
            if r < 0 { return window[i].0 }
        }
        return window[window.count - 1].0
    }

    /// Fold a tempo into [80, 160) by doubling/halving — the cloud's `foldBpm`.
    static func foldBpm(_ b: Double?) -> Double? {
        guard var x = b, x.isFinite, x > 0 else { return nil }
        while x < 80 { x *= 2 }
        while x >= 160 { x /= 2 }
        return x
    }

    static func genreLabel(_ g: String) -> String {
        switch g {
        case "r&b": return "R&B"
        case "edm": return "EDM"
        case "hip-hop": return "Hip-Hop"
        default: return g.prefix(1).uppercased() + g.dropFirst()
        }
    }

    static func chips(input: Input, profile: Profile) -> [String] {
        var out = [input.context.timePhrase]
        if let l = input.contextLabel { out.append(l) }
        if let b = profile.bpmBand { out.append("\(Int(b.lowerBound))–\(Int(b.upperBound)) BPM") }
        let genres = profile.targets.filter { $0.dim == "genre" }.prefix(2).map(\.label)
        if !genres.isEmpty { out.append(genres.joined(separator: "/")) }
        else if let a = profile.targets.first(where: { $0.dim == "artist" }) { out.append(a.label) }
        return out
    }
}

/// The cloud's round-learning formula, on device — so a round's lesson applies to the very next
/// round, before the cloud recomputes (and without the cloud at all). MUST match
/// `learnFromRounds` / `roundMultiplier` in scripts/lambda/listening-pockets/analyze.mjs.
enum InThePocketLearning {
    static let earlySkipMaxSong = 2
    static let smoothing = 1.0
    static let minMultiplier = 0.25
    static let maxMultiplier = 2.0

    /// +1 pocket, −1 broke at song ≤ 2, 0 otherwise.
    static func label(_ r: InThePocketRound) -> Int {
        switch r.outcome {
        case .pocket?: return 1
        case .broke(let n)? where n <= earlySkipMaxSong: return -1
        default: return 0
        }
    }

    static func multiplier(pos: Int, neg: Int) -> Double {
        let m = 2 * (Double(pos) + smoothing) / (Double(pos + neg) + 2 * smoothing)
        return (min(maxMultiplier, max(minMultiplier, m)) * 1000).rounded() / 1000
    }

    struct Weight: Equatable { var pos: Int; var neg: Int; var multiplier: Double }

    /// context key → "dim\0value" → weight.
    static func contexts(_ rounds: [InThePocketRound]) -> [String: [String: Weight]] {
        var counts: [String: [String: (Int, Int)]] = [:]
        for r in rounds {
            let l = label(r)
            guard l != 0 else { continue }
            for k in r.context.learningKeys {
                var m = counts[k] ?? [:]
                for key in Set(r.targets.map { $0.dim + "\u{0}" + $0.value }) {
                    var c = m[key] ?? (0, 0)
                    if l > 0 { c.0 += 1 } else { c.1 += 1 }
                    m[key] = c
                }
                counts[k] = m
            }
        }
        return counts.mapValues { $0.mapValues { Weight(pos: $0.0, neg: $0.1, multiplier: multiplier(pos: $0.0, neg: $0.1)) } }
    }
}

/// A tiny seedable PRNG (SplitMix64) — deterministic across platforms and runs, unlike the system
/// generator. Used only for the round draw.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
