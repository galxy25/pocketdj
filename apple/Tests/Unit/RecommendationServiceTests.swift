import XCTest
@testable import PocketDJ

/// `RecommendationService` — the recommendation-engine orchestrator, driven against seeded
/// real stores (temp files) and a spy transport.
///
/// The property worth breaking a build over: with the Settings toggle OFF (the default), the
/// service emits literally ZERO network traffic — that gate is the entire privacy story.
@MainActor
final class RecommendationServiceTests: XCTestCase {

    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var status = 200
        var body = Data(#"{"ok":true}"#.utf8)

        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
        func record(_ req: URLRequest) -> (Data, URLResponse) {
            lock.lock(); _requests.append(req); lock.unlock()
            let resp = HTTPURLResponse(url: req.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
        /// The decoded JSON body of request #i.
        func json(_ i: Int) -> [String: Any] {
            guard requests.indices.contains(i), let data = requests[i].httpBody,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj
        }
    }

    private struct Env {
        let svc: RecommendationService
        let spy: Spy
        let settings: SettingsStore
        let history: PlayHistoryStore
        let favorites: FavoritesStore
        let activity: CollectionActivityStore
        let collections: CollectionsStore
        let keyURL: URL
    }

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-rec-\(name)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeEnv(enabled: Bool, keyURL: URL? = nil, stateURL: URL? = nil,
                         shared: Env? = nil) -> Env {
        let spy = Spy()
        let client = RecEngineClient(base: URL(string: "https://rec.test")!,
                                     transport: { spy.record($0) })
        let settings: SettingsStore
        let history: PlayHistoryStore
        let favorites: FavoritesStore
        let activity: CollectionActivityStore
        let collections: CollectionsStore
        if let shared {
            settings = shared.settings; history = shared.history; favorites = shared.favorites
            activity = shared.activity; collections = shared.collections
        } else {
            let suite = "pdj.rec.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            settings = SettingsStore(defaults: defaults)
            history = PlayHistoryStore(fileURL: tempURL("history"))
            favorites = FavoritesStore(fileURL: tempURL("favorites"))
            activity = CollectionActivityStore(fileURL: tempURL("activity"))
            collections = CollectionsStore(fileURL: tempURL("collections"))
        }
        settings.recEngineEnabled = enabled
        let key = keyURL ?? tempURL("key")
        let svc = RecommendationService(
            client: client, settings: settings, history: history, favorites: favorites,
            activity: activity, collections: collections,
            profileIdProvider: { "profile-test-1234" },
            keyFileURL: key, stateFileURL: stateURL ?? tempURL("sync"))
        return Env(svc: svc, spy: spy, settings: settings, history: history,
                   favorites: favorites, activity: activity, collections: collections,
                   keyURL: key)
    }

    // MARK: - The privacy gate

    func testDisabledSendsNothing() async {
        let env = makeEnv(enabled: false)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        env.favorites.set("sng_a", favorited: true, appleMusicId: nil)
        await env.svc.flushNow()
        await env.svc.refreshForYou()
        _ = await env.svc.collectionSuggestions(for: "sng_a")
        _ = await env.svc.rawCollectionSuggestions(for: "sng_a")
        XCTAssertEqual(env.spy.requests.count, 0,
                       "toggle OFF means literally zero network calls — the whole privacy story")
        XCTAssertTrue(env.svc.forYou.isEmpty)
    }

    // MARK: - Flush + cursors

    func testFlushSendsOnlyEventsPastCursorsAndAdvancesOnSuccess() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", title: "A", artist: "Aria", context: .browser, at: 1_000)
        env.history.record(songId: "sng_b", title: "B", artist: "Bea", context: .browser, at: 2_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 1)
        XCTAssertEqual(env.spy.requests[0].url?.path, "/events")
        let first = env.spy.json(0)
        XCTAssertEqual((first["plays"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(first["collectionsSnapshot"], "first flush carries the snapshot")
        XCTAssertNotNil(env.svc.lastSyncedAtMs)

        // Only the NEW event rides the second flush (cursors advanced on the 2xx).
        env.history.record(songId: "sng_c", title: "C", artist: "Cy", context: .browser, at: 3_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 2)
        let second = env.spy.json(1)
        let plays = second["plays"] as? [[String: Any]]
        XCTAssertEqual(plays?.count, 1)
        XCTAssertEqual(plays?.first?["songId"] as? String, "sng_c")
        XCTAssertNil(second["collectionsSnapshot"], "unchanged membership sends no snapshot")

        // Nothing new pending → no third request at all.
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 2)
    }

    func testFlushDoesNotAdvanceCursorOn403() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        env.spy.status = 403
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 1)
        XCTAssertNotNil(env.svc.syncError, "the key mismatch is surfaced")

        // Same events are re-sent once the key works again — the cursor never moved.
        env.spy.status = 200
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 2)
        let retried = env.spy.json(1)
        XCTAssertEqual((retried["plays"] as? [[String: Any]])?.first?["songId"] as? String, "sng_a")
    }

    func testCollectionsSnapshotSentOnlyWhenHashChanges() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        XCTAssertNotNil(env.spy.json(0)["collectionsSnapshot"])

        env.history.record(songId: "sng_b", context: .browser, at: 2_000)
        await env.svc.flushNow()
        XCTAssertNil(env.spy.json(1)["collectionsSnapshot"], "same membership → no snapshot")

        // Membership changed → the next flush carries a fresh snapshot.
        _ = env.collections.createPocket("Warmup")
        env.history.record(songId: "sng_c", context: .browser, at: 3_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 3)
        let snap = env.spy.json(2)["collectionsSnapshot"] as? [String: Any]
        XCTAssertNotNil(snap)
        let entries = snap?["collections"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?["kind"] as? String, "pocket")
    }

    func testKeyMintedOnceAndStableAcrossReload() async throws {
        let keyURL = tempURL("shared-key")
        let env = makeEnv(enabled: true, keyURL: keyURL)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        let auth1 = try XCTUnwrap(env.spy.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth1.hasPrefix("Bearer "))
        XCTAssertEqual(auth1.count, "Bearer ".count + 64, "32 random bytes hex-encoded")

        // A second service constructed over the SAME key file (a relaunch / another store
        // reload) presents the SAME key. Fresh cursor file so its flush actually sends.
        let env2 = makeEnv(enabled: true, keyURL: keyURL, stateURL: tempURL("sync2"), shared: env)
        await env2.svc.flushNow()
        let auth2 = env2.spy.requests.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth2, auth1)
    }

    func testDeleteCloudDataResetsCursors() async {
        let env = makeEnv(enabled: true)
        env.history.record(songId: "sng_a", context: .browser, at: 1_000)
        await env.svc.flushNow()
        XCTAssertEqual(env.spy.requests.count, 1)

        env.spy.body = Data(#"{"deleted":true}"#.utf8)
        let ok = await env.svc.deleteCloudData()
        XCTAssertTrue(ok)
        XCTAssertEqual(env.spy.requests.last?.httpMethod, "DELETE")

        // Cursors reset → the next flush re-uploads history from the top.
        env.spy.body = Data(#"{"ok":true}"#.utf8)
        await env.svc.flushNow()
        let resent = env.spy.json(env.spy.requests.count - 1)
        XCTAssertEqual((resent["plays"] as? [[String: Any]])?.first?["songId"] as? String, "sng_a")
    }

    // MARK: - Fixture seam

    func testFixtureSeamServesCannedForYou() async {
        let env = makeEnv(enabled: false)
        env.svc.fixtureForTesting = true
        await env.svc.refreshForYou()
        XCTAssertEqual(env.svc.forYou.map(\.songId), ["sng_fix_1", "sng_fix_2", "sng_fix_3"])
        XCTAssertEqual(env.svc.forYou.first?.name, "Neon")

        // Canned collection suggestions come from the live collections (first playlists + pocket).
        _ = env.collections.createPocket("Soul")
        _ = env.collections.createPlaylist("Warmup")
        let sugs = await env.svc.collectionSuggestions(for: "sng_x")
        XCTAssertEqual(sugs.count, 2)
        XCTAssertTrue(sugs.contains { $0.kind == "playlist" && $0.name == "Warmup" })
        XCTAssertTrue(sugs.contains { $0.kind == "pocket" && $0.name == "Soul" })

        XCTAssertEqual(env.spy.requests.count, 0, "the fixture seam never touches the network")
    }
}
