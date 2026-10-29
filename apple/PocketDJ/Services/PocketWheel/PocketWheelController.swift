import Foundation
import Observation

/// The app-scoped glue between the wheel, its centre ▶, CarPlay and Siri (§3): reads NOW (time,
/// day, CarPlay, motion, place guess, the last 45 minutes) and asks `PocketBestMatch` for the
/// pocket that fits; plays a pocket through the `play` seam (the adaptive run store, Phase 5).
@MainActor
@Observable
final class PocketWheelController {

    private(set) var result: PocketBestMatch.Result?
    private(set) var computedAtMs: Double = 0
    private(set) var lastNow: PocketBestMatch.Now?

    @ObservationIgnored private let cache: PocketMomentCache
    @ObservationIgnored private let history: PlayHistoryStore
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var carPlayConnected: () -> Bool = { false }
    @ObservationIgnored var motionNow: () async -> String? = { nil }
    @ObservationIgnored var contextGuess: () -> ListeningContextTag? = { nil }
    /// T2: the cloud's results when the pockets opt-in is on.
    @ObservationIgnored var cloudResults: () -> ListeningPocketsResults? = { nil }
    /// T4: the most recently played collection, else Favorites, else For You's top tile.
    @ObservationIgnored var emptyFallback: () -> PocketProfile? = { nil }
    /// Collection attribution of one play (the moment engine's rule, with live collections).
    @ObservationIgnored var attribute: (PlayHistoryStore.PlayEvent) -> [String: Double] = {
        $0.originCollectionId.map { [$0: 1] } ?? [:]
    }
    /// Start a pocket (Phase 5: `PocketRunStore.start`).
    @ObservationIgnored var play: (PocketProfile) async -> Void = { _ in }

    init(cache: PocketMomentCache, history: PlayHistoryStore) {
        self.cache = cache
        self.history = history
    }

    /// Recompute the best match for NOW.
    @discardableResult
    func refresh() async -> PocketBestMatch.Result {
        let date = now()
        let tz = TimeZone.current.secondsFromGMT(for: date) / 60
        let nowMs = date.timeIntervalSince1970 * 1000
        let local = PocketClock.local(atMs: nowMs, tzOffsetMin: tz)
        let guess = contextGuess()
        let motion = await motionNow()
        let recent = PocketBestMatch.recentActivity(events: history.events, nowMs: nowMs, attribute: attribute)
        var n = PocketBestMatch.Now(hour: local.fractionalHour, dow: local.dow,
                                    mode: PocketBestMatch.modeNow(carPlayConnected: carPlayConnected(), motion: motion,
                                                                  contextGuess: guess),
                                    ctx: guess.map(PocketMomentEngine.contextKey).flatMap { $0 == "none" ? nil : $0 })
        n.recentCollections = recent.collections
        n.recentSkipRate = recent.skipRate
        var fallbacks = PocketBestMatch.Fallbacks(empty: emptyFallback())
        if let results = cloudResults(), results.generatedAtMs != nil {
            let ctx = InThePocketContext.make(atMs: nowMs, tzOffsetMin: tz, ctx: guess)
            let input = InThePocketScorer.Input(context: ctx, contextLabel: nil, results: results, catalog: [:],
                                                playableIds: [], plays: [], nowMs: nowMs, seed: 0)
            if let p = InThePocketScorer.cloudProfile(input) { fallbacks.cloud = PocketBestMatch.cloudProfile(p) }
            if (results.roundLearning?.pocketRate ?? 0) >= 0.5 { fallbacks.boostedPatternIds = Set(results.patterns.map(\.id)) }
        }
        let r = PocketBestMatch.best(snapshot: cache.snapshot, now: n, fallbacks: fallbacks)
        result = r
        lastNow = n
        computedAtMs = nowMs
        return r
    }

    /// Phase 5b: the best pocket for NOW with the mode forced (a run re-targeting mid-run).
    func profile(forMode mode: PocketMode) async -> PocketProfile? {
        await refresh()
        guard var n = lastNow else { return nil }
        n.mode = mode
        let r = PocketBestMatch.best(snapshot: cache.snapshot, now: n)
        return r.profile.tier == .empty ? nil : r.profile
    }

    /// Recompute if the answer is older than a minute (cheap; called on appear + by CarPlay).
    func refreshIfStale() async {
        if now().timeIntervalSince1970 * 1000 - computedAtMs > 60_000 { await refresh() }
    }

    func playBest() async {
        let r = await refresh()
        await play(r.profile)
    }

    func playMoment(_ key: PocketMomentKey) async {
        guard let m = cache.snapshot.index()[key] else { return }
        await play(.from(moment: m, names: cache.snapshot.collectionNames))
    }

    func play(alternative: PocketWheelBestMatchSummary) async {
        guard let key = alternative.key else { return }
        await playMoment(key)
    }

    /// The top `count` moments within ±1 h of now across modes (CarPlay's "Pockets right now").
    func momentsNow(count: Int = 5) -> [PocketMoment] {
        guard let n = lastNow else { return [] }
        var scored: [(PocketMoment, Double)] = []
        for m in cache.snapshot.moments where m.plays > 0 {
            let dh = PocketBestMatch.circularHours(n.hour, Double(m.key.hour) + 0.5)
            guard dh <= 1.5 else { continue }
            scored.append((m, PocketBestMatch.score(m, now: n, boosted: []).score))
        }
        scored.sort { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.key < b.0.key }
        return Array(scored.prefix(count).map { $0.0 })
    }

    // MARK: View glue

    var collectionNames: [String: String] { cache.snapshot.collectionNames }
    func collectionName(_ id: String) -> String? { cache.snapshot.collectionNames[id] }

    static func summary(_ p: PocketProfile) -> PocketWheelBestMatchSummary {
        PocketWheelBestMatchSummary(key: p.key, caption: p.caption, detail: p.detail, collectionId: p.dominantCollectionId)
    }

    var bestSummary: PocketWheelBestMatchSummary? { result.map { Self.summary($0.profile) } }
    var alternativeSummaries: [PocketWheelBestMatchSummary] { result?.alternatives.map(Self.summary) ?? [] }
}
