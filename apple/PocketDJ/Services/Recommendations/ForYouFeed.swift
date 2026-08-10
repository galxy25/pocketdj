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
    /// WHICH RANKER produced `zoneIds` — `ForYouTileSource.rawValue`. Frozen ALONGSIDE the ids,
    /// never derived at render from "is the engine on right now": the toggle can be flipped, or
    /// the network can drop, long after a ranking was cached, and an attribution recomputed from
    /// live state would then describe a list it did not produce. Stored as the raw string so an
    /// unknown future value degrades to `.onDevice` instead of failing the whole decode.
    var zoneSourceRaw: String = ForYouTileSource.onDevice.rawValue
    var crates: [Crate] = []

    /// The frozen attribution, decoded leniently.
    var zoneSource: ForYouTileSource {
        ForYouTileSource(rawValue: zoneSourceRaw) ?? .onDevice
    }

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
        case schemaVersion, refreshedAtMs, zoneIds, zoneBuriedIds, zoneSourceRaw, crates
    }

    init(refreshedAtMs: Double = 0, zoneIds: [String] = [], zoneBuriedIds: [String] = [],
         zoneSource: ForYouTileSource = .onDevice, crates: [Crate] = []) {
        self.refreshedAtMs = refreshedAtMs
        self.zoneIds = zoneIds
        self.zoneBuriedIds = zoneBuriedIds
        self.zoneSourceRaw = zoneSource.rawValue
        self.crates = crates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? forYouFeedSchemaVersion
        refreshedAtMs = (try? c.decode(Double.self, forKey: .refreshedAtMs)) ?? 0
        zoneIds = (try? c.decode([String].self, forKey: .zoneIds)) ?? []
        zoneBuriedIds = (try? c.decode([String].self, forKey: .zoneBuriedIds)) ?? []
        // ADDITIVE-OPTIONAL: a document written before the cloud path existed has no such key and
        // decodes to the on-device answer, which is exactly what produced it.
        zoneSourceRaw = (try? c.decode(String.self, forKey: .zoneSourceRaw))
            ?? ForYouTileSource.onDevice.rawValue
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
    /// Crates the owner has switched OFF in the tile's ⋯ menu (`Playlist.recsEnabled == false`).
    ///
    /// They stay in `crates` on purpose — their membership is still In Da Zone's co-membership
    /// signal (see `CollectionsStore.suggestibleCollections`) — but `build` computes NO suggestions
    /// for them and emits NO crate, so they cost nothing and cannot produce a tile. Empty ⇒ the
    /// ranking is byte-identical to what it was before this feature existed.
    var recsOffCrateIds: Set<String> = []
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
        // ── THE OPT-OUT, APPLIED BEFORE THE WORK AND NOT AFTER IT ────────────────────────────
        // `ZoneEngine.suggestions` is a CATALOG SWEEP PER CRATE (~96k rows each). A switched-off
        // collection is therefore filtered here, ahead of the map — not rendered-then-hidden.
        // Owner's requirement, verbatim: "no suggestions computed for it, and no wasted work —
        // not merely a hidden tile that still ranks." Note this drops the crate from the SNAPSHOT
        // too, so a switched-off collection cannot leave a stale frozen list behind to be
        // resurrected by a later toggle-on without a refresh.
        //
        // The zone pass above still sees every crate (`inputs.crates`) — see `recsOffCrateIds`.
        let crates = inputs.crates
            .filter { !inputs.recsOffCrateIds.contains($0.id) }
            .map { c in
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
            zoneSource: .onDevice,
            crates: crates)
    }

    /// Replace a snapshot's In Da Zone half with the CLOUD engine's ranking — or leave it exactly
    /// as it is when the cloud has nothing usable to say.
    ///
    /// ── WHY THIS TAKES A BUILT SNAPSHOT INSTEAD OF REPLACING THE BUILD ───────────────────────
    /// The on-device pass runs FIRST and unconditionally, and this is a second, cheap pass over
    /// its result. That ordering is the fallback: by the time a cloud answer is even asked for,
    /// a complete, correct feed already exists and is already on screen. Every cloud failure —
    /// disabled, offline, 5xx, an empty list, a list of ids this catalog cannot resolve, a list
    /// entirely thumbed down — arrives here as an empty shaped queue and returns the input
    /// untouched. There is no branch in which a cloud problem produces an empty tile.
    ///
    /// The collection tiles are deliberately NOT touched: `/recs/songs` ranks the whole library
    /// against the listener's taste, which is In Da Zone's question, not "what belongs in this
    /// crate" (that is `/recs/collections`, a different route with a different shape).
    static func applyingCloudZone(_ snapshot: ForYouFeedSnapshot, cloudZoneIds: [String],
                                  inputs: ForYouFeedInputs) -> ForYouFeedSnapshot {
        guard !cloudZoneIds.isEmpty else { return snapshot }
        let queue = ZoneEngine.shapeCloudRanking(songIds: cloudZoneIds,
                                                 songs: inputs.songs,
                                                 plays: inputs.plays,
                                                 lastPlayedMs: inputs.lastPlayedMs,
                                                 feedback: inputs.zoneFeedback,
                                                 nowMs: inputs.nowMs)
        guard !queue.isEmpty else { return snapshot }
        var next = snapshot
        next.zoneIds = queue.songIds
        next.zoneBuriedIds = queue.picks.filter { $0.pool == .rediscovery }.map(\.songId)
        next.zoneSourceRaw = ForYouTileSource.cloud.rawValue
        return next
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
    ///
    /// ── TWO COMMITS, AND THE ORDER IS THE FALLBACK ───────────────────────────────────────────
    /// `cloudZone` is the recommendation engine's ranking for In Da Zone, if this install has one
    /// to ask (nil when the engine is off — the default — so a disabled install does exactly what
    /// it did before, including making no request at all).
    ///
    /// The on-device ranking is computed and COMMITTED FIRST, then the network call is awaited.
    /// That is deliberate and it is the whole "never block first render on a network call" rule:
    ///  · the grid already paints from the previous cache while this runs;
    ///  · the local answer lands as soon as it is ready, at local speed;
    ///  · the cloud answer arrives later and updates the tile in place, or never arrives and
    ///    changes nothing.
    /// Doing it the other way — await the server, then decide — makes every refresh as slow as the
    /// slowest Lambda cold start, and makes a timeout look like a hung refresh.
    func refresh(_ inputs: ForYouFeedInputs,
                 cloudZone: (() async -> [String])? = nil) async {
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

        guard let cloudZone else { return }
        let cloudIds = await cloudZone()
        guard !cloudIds.isEmpty else { return }
        let shaped = await Task.detached(priority: .userInitiated) {
            ForYouFeedBuilder.applyingCloudZone(built, cloudZoneIds: cloudIds, inputs: inputs)
        }.value
        // Identical ⇒ the cloud answer shaped away to nothing and `applyingCloudZone` handed the
        // input straight back. Committing it anyway would burn a revision and re-derive the grid
        // for no change.
        guard shaped != built else { return }
        commit(shaped)
    }

    /// Land a snapshot (also the test seam).
    func commit(_ next: ForYouFeedSnapshot) {
        snapshot = next
        revision &+= 1
        save()
    }

    func songIds(forTileId tileId: String) -> [String]? { snapshot.songIds(forTileId: tileId) }

    // ========================================================================
    // MARK: - CloudSync — the feed follows the Apple ID
    // ========================================================================

    /// Owner, verbatim: *"syncing of recommendations (and accept reject) at the profile level so it
    /// is synced across all devices."* The 👍/👎 half already synced (`rec-feedback`, union-by-id).
    /// THIS is the other half — the ranking itself. Without it each device ran its own 4:20 sweep
    /// and For You said something different on the phone than on the Mac, which is the complaint.
    var syncFileURL: URL { fileURL }

    /// THE MTIME OF THIS FILE IS ALWAYS `snapshot.refreshedAtMs`, AND THAT IS THE WHOLE DESIGN.
    ///
    /// `CloudSyncService` is whole-document last-writer-wins over FILE MODIFICATION TIMES. That is
    /// right for a snapshot (a ranking is one indivisible answer — union-merging two of them the
    /// way the verdict LOG is merged would interleave two rankings into a third that neither engine
    /// produced), but the raw mtime is the wrong CLOCK. A pull WRITES the file, so a device that
    /// merely received a peer's ranking gets an mtime of *now* while its contents are from whenever
    /// that peer last refreshed. Two consequences, both silent:
    ///   · it then looks NEWER than a genuinely fresher ranking a peer pushes moments later, so it
    ///     refuses to pull it; and
    ///   · its own push watermark equals that mtime, so it cannot publish either.
    /// The device sits on a stale feed forever with no symptom and no way out but a manual Refresh
    /// — exactly the divergence this feature exists to remove.
    ///
    /// Stamping the file's mtime with the refresh instant makes the engine's mtime comparison a
    /// comparison of REFRESH RECENCY, on every device, with no second sync engine and no change to
    /// `CloudSyncService`. The device that actually re-ranked most recently wins; PULLING NEVER
    /// COUNTS AS REFRESHING. A never-refreshed feed stamps epoch 0, so a cold install can pull but
    /// can never overwrite a real ranking with its empty one.
    private nonisolated static func stampMtime(_ url: URL, refreshedAtMs: Double) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: max(0, refreshedAtMs) / 1000)],
            ofItemAtPath: url.path)
    }

    /// CloudSync write seam. Lands the peer's document only when it is STRICTLY FRESHER than ours.
    ///
    /// The engine's own mtime gate already asks that question, so this is belt-and-braces there —
    /// but `restoreForOnboarding` applies every cloud document unconditionally, and a corrupt or
    /// half-written payload has to degrade to "keep what we have" rather than to a blank grid.
    func applyPulledPayload(_ data: Data) {
        guard let incoming = try? JSONDecoder().decode(ForYouFeedSnapshot.self, from: data),
              incoming.refreshedAtMs > snapshot.refreshedAtMs else {
            // Not fresher (or not decodable): keep ours, and re-stamp so the watermark
            // `CloudSyncService` reads immediately after this call still describes OUR refresh.
            Self.stampMtime(fileURL, refreshedAtMs: snapshot.refreshedAtMs)
            return
        }
        try? data.write(to: fileURL, options: .atomic)
        Self.stampMtime(fileURL, refreshedAtMs: incoming.refreshedAtMs)
    }

    /// Post-pull reload. REPLACES rather than merges — see `applyPulledPayload`.
    ///
    /// It deliberately does NOT save: the bytes on disk are already the pulled ones, and a re-save
    /// would move the mtime off the refresh instant and break the invariant above. That also keeps
    /// `CloudSyncService.applyPull`'s "did the reload rewrite the file?" check answering *no*, so
    /// the pulled document is watermarked instead of being bounced straight back up.
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(ForYouFeedSnapshot.self, from: data),
              doc.refreshedAtMs > snapshot.refreshedAtMs else { return false }
        snapshot = doc
        revision &+= 1
        return true
    }

    /// Account deletion / "Erase everything": forget the cached ranking AND the file, so a
    /// re-onboarded install starts cold rather than re-publishing the erased feed off a leftover
    /// document. (Deleting the file rather than saving an empty snapshot keeps the mtime invariant
    /// out of the "epoch 0 file exists" corner.)
    func clear() {
        snapshot = ForYouFeedSnapshot()
        revision &+= 1
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        Self.stampMtime(fileURL, refreshedAtMs: snapshot.refreshedAtMs)
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
