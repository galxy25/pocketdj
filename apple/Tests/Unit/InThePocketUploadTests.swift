import XCTest
@testable import PocketDJ

/// In the Pocket rounds ride `ListeningPocketsService`'s flush: queued locally, acknowledged per
/// round fingerprint ONLY on 2xx, re-sent when feedback changes, a 404 (a backend without
/// `/pockets/rounds`) leaves them queued and silent, the privacy gate sends nothing, and the
/// "Delete cloud data" floor holds for rounds too. Plus the wire shape and the results decode.
@MainActor
final class InThePocketUploadTests: XCTestCase {

    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var statusByPath: [String: Int] = [:]
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        func roundPosts() -> [URLRequest] {
            requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/pockets/rounds") == true }
        }
        func record(_ req: URLRequest) -> (Data, URLResponse) {
            lock.lock(); _requests.append(req)
            let code = statusByPath[req.url?.path ?? ""] ?? 200
            lock.unlock()
            return (Data(#"{"ok":true}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        static func rounds(_ req: URLRequest) -> [[String: Any]] {
            guard let data = req.httpBody,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (obj["rounds"] as? [[String: Any]]) ?? []
        }
    }

    static let nowMs = 1_791_806_400_000.0
    static let roundsPath = "/pockets/rounds"

    private struct Env {
        let svc: ListeningPocketsService
        let spy: Spy
        let settings: SettingsStore
        let history: PlayHistoryStore
    }

    private var wires: [InThePocketRoundWire] = []

    private func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-itp-up-\(name)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeEnv(enabled: Bool = true) -> Env {
        let suite = "pdj.itp.upload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        settings.recEngineEnabled = true
        settings.listeningPocketsEnabled = enabled
        let history = PlayHistoryStore(fileURL: temp("history"))
        let spy = Spy()
        let client = ListeningPocketsClient(base: URL(string: "https://pockets.test")!, enrollSecret: "enroll",
                                            transport: { spy.record($0) })
        let svc = ListeningPocketsService(
            history: history, settings: settings, credentials: { ("key", String(repeating: "ab", count: 32)) },
            provider: NoopListeningContextProvider(), client: client,
            now: { Date(timeIntervalSince1970: Self.nowMs / 1000) },
            syncFileURL: temp("sync"), cacheFileURL: temp("cache"))
        svc.fixtureForTesting = false
        svc.deviceIdProvider = { "DEVICE-1" }
        svc.roundsProvider = { [weak self] _ in self?.wires ?? [] }
        return Env(svc: svc, spy: spy, settings: settings, history: history)
    }

    private func finishedRound(feedback: String? = "loved it", startedMinutesAgo: Double = 60) -> InThePocketRound {
        var r = InThePocketStoreTests.round(songs: ["sng_00000000000a", "sng_00000000000b", "sng_00000000000c"], outcome: .pocket)
        r.startedAtMs = Self.nowMs - startedMinutesAgo * 60_000 + 12_345
        r.endedAtMs = Self.nowMs - 30 * 60_000
        r.updatedAtMs = Self.nowMs - 30 * 60_000
        r.context.ctx = .place("plc_0f1e2d3c4b5a6978")
        r.feedback = feedback
        r.rating = 5
        for i in r.songs.indices { r.songs[i].state = .completed; r.songs[i].fraction = 0.97 }
        return r
    }

    func testFinishedRoundsUploadOnFlushAndAreAcknowledged() async throws {
        let env = makeEnv()
        let round = finishedRound()
        wires = [try XCTUnwrap(round.wire(installId: "INSTALL-1"))]
        let sent = await env.svc.flushNow()
        XCTAssertTrue(sent)
        let posts = env.spy.roundPosts()
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertNotNil(posts[0].value(forHTTPHeaderField: RecEngineClient.enrollHeader), "rounds may enroll, like events")
        let body = Spy.rounds(posts[0])
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body[0]["id"] as? String, round.id.uuidString)
        XCTAssertEqual(body[0]["outcome"] as? String, "pocket")
        XCTAssertEqual(body[0]["feedback"] as? String, "loved it")
        XCTAssertEqual((body[0]["startedAtMs"] as? Double).map { $0.truncatingRemainder(dividingBy: 60_000) }, 0)
        XCTAssertTrue(body[0]["brokeAt"] is NSNull, "nullable fields are explicit nulls")
        let ctx = (body[0]["context"] as? [String: Any])?["ctx"] as? [String: Any]
        XCTAssertEqual(ctx?["kind"] as? String, "place")
        XCTAssertNil(ctx?["tripId"], "only the ids the kind uses")
        XCTAssertNil(body[0]["contextLabel"], "display labels never upload")
        XCTAssertEqual(env.svc.acknowledgedRounds[round.id.uuidString], wires[0].fingerprint)

        // Nothing moved → nothing re-sent.
        _ = await env.svc.flushNow()
        XCTAssertEqual(env.spy.roundPosts().count, 1)
        // Feedback edited after the fact (updatedAtMs moves) → re-sent.
        var edited = round
        edited.feedback = "actually too slow"
        edited.updatedAtMs += 1000
        wires = [try XCTUnwrap(edited.wire(installId: "INSTALL-1"))]
        _ = await env.svc.flushNow()
        XCTAssertEqual(env.spy.roundPosts().count, 2)
        XCTAssertEqual(Spy.rounds(env.spy.roundPosts()[1]).first?["feedback"] as? String, "actually too slow")
    }

    func testA404LeavesRoundsQueuedSilentlyAndTheNextFlushRetries() async throws {
        let env = makeEnv()
        env.spy.statusByPath[Self.roundsPath] = 404
        wires = [try XCTUnwrap(finishedRound().wire(installId: "I"))]
        let sent = await env.svc.flushNow()
        XCTAssertFalse(sent)
        XCTAssertEqual(env.spy.roundPosts().count, 1)
        XCTAssertTrue(env.svc.acknowledgedRounds.isEmpty, "a 404 acknowledges nothing — the round stays queued")
        XCTAssertFalse(env.svc.roundsServiceAvailable)
        XCTAssertNil(env.svc.syncError, "no loud error for a route that isn't deployed yet")
        XCTAssertTrue(env.svc.serviceAvailable, "the events route is not blamed")

        // Still 404 → still queued, asked again.
        _ = await env.svc.flushNow()
        XCTAssertEqual(env.spy.roundPosts().count, 2)
        XCTAssertTrue(env.svc.acknowledgedRounds.isEmpty)

        // The route ships → the same round goes up.
        env.spy.statusByPath[Self.roundsPath] = nil
        let later = await env.svc.flushNow()
        XCTAssertTrue(later)
        XCTAssertEqual(env.svc.acknowledgedRounds.count, 1)
        XCTAssertTrue(env.svc.roundsServiceAvailable)
    }

    func testOtherFailuresKeepRoundsQueuedToo() async throws {
        let env = makeEnv()
        env.spy.statusByPath[Self.roundsPath] = 503
        wires = [try XCTUnwrap(finishedRound().wire(installId: "I"))]
        _ = await env.svc.flushNow()
        XCTAssertTrue(env.svc.acknowledgedRounds.isEmpty)
        env.spy.statusByPath[Self.roundsPath] = nil
        _ = await env.svc.flushNow()
        XCTAssertEqual(env.svc.acknowledgedRounds.count, 1)
    }

    func testThePrivacyGateSendsNoRounds() async throws {
        let env = makeEnv(enabled: false)
        wires = [try XCTUnwrap(finishedRound().wire(installId: "I"))]
        let sent = await env.svc.flushNow()
        XCTAssertFalse(sent)
        XCTAssertTrue(env.spy.requests.isEmpty)
    }

    func testRoundsBeforeTheDeleteFloorNeverUpload() async throws {
        let env = makeEnv()
        let erased = await env.svc.deleteCloudData(key: "key", profileId: String(repeating: "ab", count: 32))
        XCTAssertTrue(erased)
        wires = [try XCTUnwrap(finishedRound(startedMinutesAgo: 60).wire(installId: "I"))]
        _ = await env.svc.flushNow()
        XCTAssertTrue(env.spy.roundPosts().isEmpty, "\"Delete cloud data\" promised only fresh data afterwards")
    }

    func testBatchesCapAtFifty() async throws {
        let env = makeEnv()
        wires = try (0..<120).map { _ in try XCTUnwrap(finishedRound().wire(installId: "I")) }
        _ = await env.svc.flushNow()
        XCTAssertEqual(env.spy.roundPosts().map { Spy.rounds($0).count }, [50, 50, 20])
        XCTAssertEqual(env.svc.acknowledgedRounds.count, 120)
    }

    // MARK: - Models

    func testUnfinishedRoundsHaveNoWireAndFeedbackIsCapped() {
        var r = finishedRound()
        r.outcome = nil
        XCTAssertNil(r.wire(installId: "I"))
        XCTAssertNil(InThePocketRound.capFeedback("   \n "))
        let emoji = String(repeating: "a", count: 1999) + "😀"
        XCTAssertEqual(InThePocketRound.capFeedback(emoji)?.utf16.count, 1999, "never split a surrogate pair")
        XCTAssertEqual(InThePocketRound.capFeedback(String(repeating: "x", count: 4000))?.count, 2000)
    }

    func testOutcomeCodableRoundTrips() throws {
        for o in [InThePocketOutcome.pocket, .broke(at: 3), .abandoned] {
            var r = finishedRound()
            r.outcome = o
            let back = try JSONDecoder().decode(InThePocketRound.self, from: JSONEncoder().encode(r))
            XCTAssertEqual(back.outcome, o)
        }
    }

    func testResultsDecodeTheRoundsSectionLeniently() throws {
        let json = """
        {"v":1,"generatedAtMs":1,"stale":false,"pockets":[],"patterns":[],
         "rounds":{"v":1,"total":3,"pocket":2,"broke":1,"abandoned":0,"pocketRate":0.667,
           "contexts":[{"key":"weekday|evening|*","rounds":3,
              "weights":[{"dim":"genre","value":"funk","pos":2,"neg":1,"multiplier":1.2},{"dim":"genre"}]},
            {"rounds":1}]}}
        """
        let r = try JSONDecoder().decode(ListeningPocketsResults.self, from: Data(json.utf8))
        let l = try XCTUnwrap(r.roundLearning)
        XCTAssertEqual([l.total, l.pocket, l.broke], [3, 2, 1])
        XCTAssertEqual(l.contexts.count, 1, "a context without a key is dropped, not the document")
        XCTAssertEqual(l.contexts[0].weights, [.init(dim: "genre", value: "funk", pos: 2, neg: 1, multiplier: 1.2)])
        let none = try JSONDecoder().decode(ListeningPocketsResults.self,
                                            from: Data(#"{"v":1,"generatedAtMs":null,"stale":false,"pockets":[],"patterns":[]}"#.utf8))
        XCTAssertNil(none.roundLearning)
    }

    func testScoreboardStatsCountDecidedRoundsAndStreaks() {
        let store = GameScoreboardStore(fileURL: temp("scores"))
        for (i, o) in ["pocket", "pocket", "abandoned", "pocket", "broke", "pocket"].enumerated() {
            store.record(game: .inThePocket, score: o == "pocket" ? 4 : 1, settingsSummary: nil,
                         detail: ["outcome": o], at: Double(1_000 + i))
        }
        let s = store.inThePocketStats()
        XCTAssertEqual(s.rounds, 6)
        XCTAssertEqual(s.pockets, 4)
        XCTAssertEqual(s.pocketRate ?? 0, 0.8, accuracy: 1e-9, "4 of 5 DECIDED rounds — abandoned predicts nothing")
        XCTAssertEqual(s.bestStreak, 3, "an abandoned round neither extends nor breaks a streak")
        XCTAssertEqual(s.currentStreak, 1)
        XCTAssertEqual(GameKind.inThePocket.rawValue, "inThePocket", "persisted token")
        XCTAssertEqual(GamesView.inThePocketSummary(s), "6 rounds · 80% in the pocket · best streak 3")
    }

    func testRunTagResolvesToTheGameInHistory() {
        let ctx = PocketDJApp.historyContext(forSourceSetlistId: InThePocketStore.runTag(UUID()), collections: nil)
        XCTAssertEqual(ctx.source, .game)
        XCTAssertEqual(ctx.name, GameKind.inThePocket.label)
    }
}
