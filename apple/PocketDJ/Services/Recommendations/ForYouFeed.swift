import Foundation
import Observation

let forYouFeedSchemaVersion = 1

// ============================================================================
// MARK: - The frozen result
// ============================================================================

/// THE LAST For You RANKING THAT WAS ACTUALLY COMPUTED — held on disk and re-rendered verbatim
/// until the owner asks for a new one.
///
/// ── WHY A SNAPSHOT AND NOT A SIGNATURE ───────────────────────────────────────────────────────
/// For You used to recompute off a signature of `(catalogRevision, history.revision, playlist /
/// pocket counts, membershipRevision, releaseFeed.revision)`. Every one of those moves during
/// ordinary use — a play bumps `history.revision`, an add bumps `membershipRevision` — so the grid
/// re-ranked while the owner was looking at it and a suggestion he had half-decided on moved, or
/// vanished. Owner, verbatim: *"history for you should cache the last result and only refresh when
/// you hit a refresh button in the menu."*
///
/// So the trade is deliberate: the feed goes SLIGHTLY STALE in exchange for being STABLE and
/// INSTANT. `refreshedAtMs` is rendered on the grid so a stale feed is legible rather than
/// mysterious.
///
/// ── WHAT IS FROZEN AND WHAT IS NOT ───────────────────────────────────────────────────────────
/// Frozen: the LOCAL, expensive ranking — In Da Zone and the per-collection suggestion lists.
/// Those are the ones that sweep ~96k catalog rows and the ones that move under the reader.
///
/// NOT frozen, on purpose:
///  • **New** — its content lives in `ReleaseFeedService`'s own cache, which only ever changes on
///    a play or the one-shot seed, never on a render. Freezing a second copy here would make the
///    tile disagree with the screen behind it, and would hide the seed (the exact bug the owner
///    reported as "my new tile is still empty").
///  • **Suggested** — same argument: `RecommendationService` holds the server's answer and the
///    list reads it directly.
///  • **feedback** — a 👍/👎 is the OWNER ACTING ON THIS LIST, not a recompute. It is applied over
///    the frozen ids at render (`RecFeedbackStore.rankedIds` / `visibleCount`), so an accepted row
///    updates and a rejected row sinks IMMEDIATELY without the ranking moving underneath.
struct ForYouFeedSnapshot: Codable, Equatable, Sendable {

    /// One collection's frozen suggestion list, with the name it had when the feed was built.
    struct Crate: Codable, Equatable, Sendable {
        var id: String
        /// "playlist" | "pocket" — drives the tile symbol and subtitle wording.
        var kind: String
        var name: String
        /// The suggested songs (NOT the members).
        var songIds: [String]
    }

    var schemaVersion: Int = forYouFeedSchemaVersion
    /// Epoch ms of the refresh that produced this. `0` ⇒ never computed (a cold install).
    var refreshedAtMs: Double = 0
    /// In Da Zone's ranked ids, in engine order.
    var zoneIds: [String] = []
    /// Which of `zoneIds` came from the rediscovery pool — the "Buried" badge, frozen with the
    /// list so the badge cannot disappear from a row while the row stays put.
    var zoneBuriedIds: [String] = []
    var crates: [Crate] = []

    /// Has a refresh ever landed? A cold install renders a spinner and seeds itself once; every
    /// launch after that renders this instantly.
    var hasResult: Bool { refreshedAtMs > 0 }

    /// Frozen ids for a tile id (`"zone"`, `"col-<id>"`). `nil` ⇒ this snapshot knows nothing
    /// about that tile, and the screen behind it falls back to computing its own list.
    func songIds(forTileId tileId: String) -> [String]? {
        if tileId == ForYouTileRoute.Kind.zone.rawValue { return hasResult ? zoneIds : nil }
        guard let crate = crates.first(where: { "col-\($0.id)" == tileId }) else { return nil }
        return crate.songIds
    }

    /// Codable is hand-rolled ONLY for leniency: a document written by a newer build (or a
    /// half-written one) must degrade to "no cache" rather than throwing away the decode and
    /// looking like a corrupt install.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, refreshedAtMs, zoneIds, zoneBuriedIds, crates
    }

    init(refreshedAtMs: Double = 0, zoneIds: [String] = [], zoneBuriedIds: [String] = [],
         crates: [Crate] = []) {
        self.refreshedAtMs = refreshedAtMs
        self.zoneIds = zoneIds
        self.zoneBuriedIds = zoneBuriedIds
        self.crates = crates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? forYouFeedSchemaVersion
        refreshedAtMs = (try? c.decode(Double.self, forKey: .refreshedAtMs)) ?? 0
        zoneIds = (try? c.decode([String].self, forKey: .zoneIds)) ?? []
        zoneBuriedIds = (try? c.decode([String].self, forKey: .zoneBuriedIds)) ?? []
        crates = (try? c.decode([Crate].self, forKey: .crates)) ?? []
    }
}

// ============================================================================
// MARK: - The builder (pure, off-actor)
// ============================================================================

/// Everything the ranking needs, as VALUE TYPES — snapshotted on the main actor so the two
/// catalog sweeps can run off it. Identical set of inputs `ForYouTilesView.rebuild` used to
/// capture inline; gathered into one Sendable struct so the work can move into a store and be
/// unit-tested without a view.
struct ForYouFeedInputs: Sendable {
    var songs: [IndexSong] = []
    var tracks: [ZoneEngine.Track] = []
    var genreBySongId: [String: String] = [:]
    var plays: [ZoneEngine.Play] = []
    var playCount: [String: Int] = [:]
    var lastPlayedMs: [String: Double] = [:]
    /// One entry per suggestible collection — `songIds` here are its MEMBERS (the profile the
    /// suggestions are drawn against), not its suggestions.
    var crates: [ForYouFeedSnapshot.Crate] = []
    var zoneFeedback = ZoneEngine.Feedback()
    /// collection id → its own feedback projection. Suppression is SCOPED, so a song thumbed down
    /// in one crate must not vanish from another's list.
    var crateFeedback: [String: ZoneEngine.Feedback] = [:]
    var nowMs: Double = 0
}

/// The ranking pass, lifted out of the view so it is one function, callable off the main actor,
/// and testable without SwiftUI.
enum ForYouFeedBuilder {

    /// Rank In Da Zone and every collection's suggestions.
    ///
    /// MUST stay free of stores, views and clocks (the clock rides in `inputs.nowMs`) — it runs
    /// inside `Task.detached`. The zone pass alone sweeps the whole catalog (~96k rows) and the
    /// collection pass sweeps it once per collection, which on the main actor is a visible hang.
    static func build(_ inputs: ForYouFeedInputs) -> ForYouFeedSnapshot {
        let counts = inputs.playCount
        let queue = ZoneEngine.inDaZone(songs: inputs.songs,
                                        genreBySongId: inputs.genreBySongId,
                                        otherCollections: inputs.crates.map(\.songIds),
                                        plays: inputs.plays,
                                        playCount: { counts[$0] ?? 0 },
                                        lastPlayedMs: inputs.lastPlayedMs,
                                        feedback: inputs.zoneFeedback,
                                        nowMs: inputs.nowMs)
        let crates = inputs.crates.map { c in
            ForYouFeedSnapshot.Crate(
                id: c.id, kind: c.kind, name: c.name,
                songIds: ZoneEngine.suggestions(memberSongIds: c.songIds, tracks: inputs.tracks,
                                                playCount: { counts[$0] ?? 0 },
                                                feedback: inputs.crateFeedback[c.id] ?? ZoneEngine.Feedback()))
        }
        return ForYouFeedSnapshot(
            refreshedAtMs: inputs.nowMs,
            zoneIds: queue.songIds,
            zoneBuriedIds: queue.picks.filter { $0.pool == .rediscovery }.map(\.songId),
            crates: crates)
    }
}

// ============================================================================
// MARK: - The durable store
// ============================================================================

/// Holds the frozen feed and writes it to Application Support.
///
/// Durable-JSON idiom, the same one `ReleaseFeedService` / `PlayStatsStore` use: decode on init
/// (so a cold launch paints the cached grid on the FIRST frame, with no task and no spinner),
/// atomic write, and the `PDJ_USE_FIXTURE` seam so a UI test starts from a cold cache instead of
/// yesterday's ranking.
@MainActor
@Observable
final class ForYouFeedStore {

    private(set) var snapshot = ForYouFeedSnapshot()
    /// True while an explicit refresh (or the cold-install first build) is in flight.
    private(set) var isRefreshing = false
    /// Bumped on every commit — what the grid keys its cheap tile derivation on.
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = ForYouFeedStore.launchURL()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(ForYouFeedSnapshot.self, from: data) {
            snapshot = doc
        }
    }

    nonisolated static func defaultURL() -> URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("pocketdj-foryou-feed.json")
    }

    /// A UI-test run must start COLD: this store's whole observable behaviour is "what was cached",
    /// so a leftover document would make an assertion pass or fail on yesterday's ranking.
    nonisolated static func launchURL() -> URL {
        if ProcessInfo.processInfo.environment["PDJ_USE_FIXTURE"] != nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-uitest-foryou-feed.json")
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return defaultURL()
    }

    /// Recompute — the ONLY thing that changes what the grid shows. Called from the tab menu's
    /// Refresh and, once, from a cold install that has nothing cached yet.
    ///
    /// Single-flighted: a second tap while a pass is running folds into the first rather than
    /// starting a second pair of catalog sweeps.
    func refresh(_ inputs: ForYouFeedInputs) async {
        guard !isRefreshing else { return }
        // NEVER overwrite a good cache with a ranking of nothing. An empty catalog is a transient
        // state (a reload, a source toggled off mid-refresh), and committing its empty result
        // would stamp "refreshed" on a blank feed and leave the owner with nothing but a Refresh
        // button that does not obviously help.
        guard !inputs.songs.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let built = await Task.detached(priority: .userInitiated) {
            ForYouFeedBuilder.build(inputs)
        }.value
        commit(built)
    }

    /// Land a snapshot (also the test seam).
    func commit(_ next: ForYouFeedSnapshot) {
        snapshot = next
        revision &+= 1
        save()
    }

    func songIds(forTileId tileId: String) -> [String]? { snapshot.songIds(forTileId: tileId) }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }

    /// "Updated 3 minutes ago" — deliberately coarse. A frozen feed has to SAY it is frozen, or
    /// staleness reads as a bug (which is how this feature got reported in the first place).
    static func updatedLabel(refreshedAtMs: Double,
                             nowMs: Double = Date().timeIntervalSince1970 * 1000) -> String {
        guard refreshedAtMs > 0 else { return "Not refreshed yet" }
        let secs = max(0, (nowMs - refreshedAtMs) / 1000)
        if secs < 90 { return "Updated just now" }
        let mins = Int((secs / 60).rounded())
        if mins < 60 { return "Updated \(mins) min ago" }
        let hours = Int((secs / 3600).rounded())
        if hours < 24 { return "Updated \(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = Int((secs / 86400).rounded())
        return "Updated \(days) day\(days == 1 ? "" : "s") ago"
    }
}
