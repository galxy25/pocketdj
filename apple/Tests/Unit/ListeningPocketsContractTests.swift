import XCTest
@testable import PocketDJ

/// END-TO-END CONTRACT between the app and the listening-pockets cloud job, enforced from BOTH
/// suites through two committed goldens in `Tests/Fixtures/`:
///
///   1. `listening-pockets-upload.app.json` — what THIS app actually POSTs for a deterministic
///      three-week scenario: real `PlayEvent`s driven through the real mutators (`markSkipped`,
///      `noteListened`), the real settle pass (`stampContexts` via a stub provider) and the real
///      `ListeningPocketsService` flush, captured at the transport. `testAppUploadMatchesGolden`
///      fails when the wire body drifts from the golden.
///   2. `listening-pockets-results.app.json` — what the cloud computes for (1). The node suite
///      (`scripts/lambda/listening-pockets/test-listening-pockets.mjs`, "app contract" tests) feeds
///      golden (1) through the real handler (POST → inline compute → GET) and the local runner and
///      fails when the output drifts from golden (2).
///   3. `testCloudResultsForTheAppUploadDecode` decodes golden (2) with the app's own results
///      decoder and cross-checks it against the scenario (members are the un-skipped plays, the
///      commute patterns keep their direction, labels resolve).
///
/// A change on either side breaks the chain until BOTH goldens are regenerated, in this order:
///   TEST_RUNNER_PDJ_REGEN_POCKETS_CONTRACT=1 xcodebuild test … \
///       -only-testing:PocketDJTests/ListeningPocketsContractTests/testAppUploadMatchesGolden
///   POCKETS_REGEN_CONTRACT=1 node --test scripts/lambda/listening-pockets/test-listening-pockets.mjs
/// (regenerate from the iOS simulator — its test host can write into the source tree.)
@MainActor
final class ListeningPocketsContractTests: XCTestCase {

    // MARK: - The scenario (deterministic: fixed clock, ids, install, tz)

    /// 2026-10-12T19:00:00Z — Monday 12:00 local (UTC−7). Also the cloud's `--now` (= sentAtMs).
    static let nowMs = 1_791_831_600_000.0
    static let tz = -420
    static let installId = "6F1C2D3E-0000-4000-8000-00000000AAAA"
    static let peerInstallId = "0D9E8F7A-1111-4000-8000-00000000BBBB"
    static let placeA = "plc_0f1e2d3c4b5a6978"
    static let placeB = "plc_8899aabbccddeeff"
    static let tripAB = "trp_3c9a0b1d2e4f5a6b"
    static let tripBA = "trp_b6a5f4e2d1b0a9c3"

    /// Song ids from `scripts/lambda/listening-pockets/fixtures/features.sample.json` (the catalog
    /// the node side computes against): a 118–124 BPM electronic set, ~90 BPM hip-hop, and a mix.
    static let electronic = ["sng_5050aade77c4", "sng_d355cc000d8b", "sng_2bd6aa178f08", "sng_df6f9d2e2f2a",
                             "sng_e517ffed1ba7", "sng_24124669befd", "sng_ce1a2fa144ff", "sng_2b11b843b917",
                             "sng_c47f2d82bad2", "sng_864189836f21", "sng_32df97b4f035", "sng_95d9dead7579"]
    static let hipHop = ["sng_e44e89f6c105", "sng_3d33ac723459", "sng_b508c8529337", "sng_6ad2b1e70ef0",
                         "sng_ff82a2c2c91c", "sng_6b9be13b205c", "sng_5459d757a358", "sng_3d96ac27a1d2",
                         "sng_e5da88ce56c7", "sng_bdeab8d16f53"]
    static let mixed = ["sng_9184eee1a405", "sng_2cb49ca41a10", "sng_59c0f6e65814", "sng_8b9caacdac52",
                        "sng_ba4ee2efe3cb", "sng_e3e836ed6981", "sng_b4c366ddbf98", "sng_9e601fbf0060",
                        "sng_de525748fdec", "sng_2c8aa912d67c", "sng_95f823c31396", "sng_4ce024fea8ca"]

    enum Kind { case completed, skipped, partial, unknown }

    struct Spec {
        var id: UUID
        var songId: String
        var playedAt: Double
        var kind: Kind
        var source: PlayHistoryStore.PlaySource
        var carPlay: Bool?
        var origin: String
        /// A context the event already carries (a peer's) — never uploaded by this device.
        var presetCtx: ListeningContextTag?
    }

    /// Three weeks of a commuter's listening, oldest first:
    ///   weekday 07:40 — electronic on the A→B drive, `PPPSPP` (one isolated skip) → 5-member pockets;
    ///   weekday 18:05 — hip-hop on the B→A drive in CarPlay, one partial (still a play);
    ///   weekday 12:30 — shuffling at B, `PSSP` → never a pocket;
    ///   weekend 15:00 — a mixed bag at A with no verdicts (`unknown` counts as a play);
    /// plus today's commute (too recent to settle → no ctx), a same-minute quick skip (ord 0/1),
    /// a peer device's play carrying a ctx, and a play outside the 90-day upload window.
    static func scenario() -> [Spec] {
        var specs: [Spec] = []
        var n = 0
        func add(_ song: String, _ at: Double, _ kind: Kind, source: PlayHistoryStore.PlaySource = .mix,
                 carPlay: Bool? = nil, origin: String = installId, ctx: ListeningContextTag? = nil) {
            n += 1
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
            specs.append(Spec(id: id, songId: song, playedAt: at, kind: kind, source: source,
                              carPlay: carPlay, origin: origin, presetCtx: ctx))
        }
        let minute = 60_000.0, hour = 60 * minute, day = 24 * hour
        let todayMidnight = nowMs - 12 * hour   // local midnight, Monday 12 Oct
        for k in stride(from: 20, through: 0, by: -1) {
            let dayStart = todayMidnight - Double(k) * day
            let dow = ((1 - k) % 7 + 7) % 7   // 0 = Sunday; today (k = 0) is Monday
            let weekday = (1...5).contains(dow)
            if weekday {
                // Morning drive A→B.
                let t0 = dayStart + 7 * hour + 40 * minute
                let pattern: [Kind] = [.completed, .completed, .completed, .skipped, .completed, .completed]
                for (i, kind) in pattern.enumerated() {
                    add(electronic[(k + i) % electronic.count], t0 + Double(i) * 4 * minute, kind)
                }
                if k == 3 {
                    // A quick skip inside the first song's minute: same floored atMs → ord 1.
                    add(mixed[0], t0 + 35_000, .skipped)
                }
                guard k > 0 else { continue }   // the rest of today hasn't happened yet
                // Midday at B: hunting, never a pocket.
                let tm = dayStart + 12 * hour + 30 * minute
                for (i, kind) in [Kind.completed, .skipped, .skipped, .completed].enumerated() {
                    add(mixed[(k + i) % mixed.count], tm + Double(i) * 3 * minute, kind, source: .playlist)
                }
                // Evening drive B→A in the car.
                let te = dayStart + 18 * hour + 5 * minute
                for i in 0..<5 {
                    add(hipHop[(k + i) % hipHop.count], te + Double(i) * 4 * minute,
                        i == 2 ? .partial : .completed, carPlay: true)
                }
            } else {
                // Weekend afternoon at A: no verdicts recorded.
                let tw = dayStart + 15 * hour
                for i in 0..<4 {
                    add(mixed[(k * 2 + i) % mixed.count], tw + Double(i) * 5 * minute, .unknown, source: .browser)
                }
            }
            if k == 2 {
                add(mixed[5], dayStart + 21 * hour, .completed, origin: peerInstallId, ctx: .place(placeA))
            }
        }
        add(mixed[1], nowMs - 100 * day, .completed)   // outside the 90-day window
        return specs.sorted { $0.playedAt < $1.playedAt }
    }

    // MARK: - Fakes

    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [Data] = []
        var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return _bodies }
        func record(_ req: URLRequest) -> (Data, URLResponse) {
            lock.lock()
            if req.httpMethod == "POST", let b = req.httpBody { _bodies.append(b) }
            lock.unlock()
            let body = req.httpMethod == "POST"
                ? Data(#"{"ok":true}"#.utf8)
                : Data(#"{"v":1,"generatedAtMs":null,"stale":false,"algo":{"version":1,"params":{}},"pockets":[],"patterns":[]}"#.utf8)
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// Answers like the on-device engine would for this commuter (by LOCAL time of day), and
    /// `.pending` inside the 6 h horizon — exactly what `ListeningLocationStore` guarantees.
    @MainActor
    private final class CommuterProvider: ListeningContextProviding {
        var isSupported: Bool { true }
        var isActive: Bool { true }
        var revision: Int { 0 }
        func context(at date: Date) -> ListeningContextLookup {
            let ms = date.timeIntervalSince1970 * 1000
            if ListeningPocketsContractTests.nowMs - ms < ListeningContextConstants.pendingHorizon * 1000 {
                return .pending
            }
            let localMin = Int(((ms / 60_000) + Double(ListeningPocketsContractTests.tz))
                .truncatingRemainder(dividingBy: 1440) + 1440) % 1440
            typealias T = ListeningPocketsContractTests
            switch localMin {
            case 7 * 60..<(8 * 60 + 30):
                return .settled(.trip(T.tripAB, origin: T.placeA, destination: T.placeB))
            case (17 * 60 + 45)..<(19 * 60 + 30):
                return .settled(.trip(T.tripBA, origin: T.placeB, destination: T.placeA))
            case 9 * 60..<(17 * 60):
                let dow = (Int((ms / 60_000 + Double(T.tz)) / 1440) + 4) % 7   // 1970-01-01 was a Thursday
                return .settled(.place((1...5).contains(dow) ? T.placeB : T.placeA))
            default:
                return .settled(.place(T.placeA))
            }
        }
        func placeLabels() -> [ListeningPlaceLabel] {
            [ListeningPlaceLabel(id: ListeningPocketsContractTests.placeA, rank: 1, label: "Location A", shareOfTime: 0.6234),
             ListeningPlaceLabel(id: ListeningPocketsContractTests.placeB, rank: 2, label: "Location B", shareOfTime: 0.2711)]
        }
        func tripLabels() -> [ListeningTripLabel] {
            typealias T = ListeningPocketsContractTests
            return [ListeningTripLabel(id: T.tripAB, origin: T.placeA, destination: T.placeB, label: "A → B", occurrences: 15),
                    ListeningTripLabel(id: T.tripBA, origin: T.placeB, destination: T.placeA, label: "B → A", occurrences: 14)]
        }
        func label(for tag: ListeningContextTag) -> String? { nil }
    }

    // MARK: - Helpers

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pockets-contract-\(name)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "\(name).json is in the test bundle (Tests/Fixtures)")
        return try Data(contentsOf: url)
    }

    /// Source-tree location of a golden (regeneration only).
    private static func sourceFixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
    }

    private static func canonical(_ obj: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Runs the scenario through the real store + service and returns the POSTed body.
    private func uploadBody() async throws -> Data {
        // A history document with a FIXED installId (the store adopts the file's).
        let historyURL = tempURL("history")
        try JSONEncoder().encode(PlayHistoryStore.Document(installId: Self.installId)).write(to: historyURL)
        let history = PlayHistoryStore(fileURL: historyURL)
        XCTAssertEqual(history.installId, Self.installId)

        let specs = Self.scenario()
        history.replaceAll(specs.map { s in
            PlayHistoryStore.PlayEvent(
                id: s.id, songId: s.songId, playedAt: s.playedAt, source: s.source,
                contextId: nil, contextName: nil, title: nil, artist: "Artist \(s.songId.suffix(4))",
                originInstallId: s.origin, tzOffsetMin: Self.tz, listeningContext: s.presetCtx,
                carPlay: s.carPlay)
        })
        // Verdicts land after the fact, through the same calls SkipTracker / the Mix bridge make.
        for s in specs {
            switch s.kind {
            case .completed: history.noteListened(eventId: s.id, fraction: 0.97)
            case .partial:   history.noteListened(eventId: s.id, fraction: 0.3)
            case .skipped:
                history.noteListened(eventId: s.id, fraction: 0.15)
                history.markSkipped(eventId: s.id)
            case .unknown:   break
            }
        }

        let suite = "pdj.pockets.contract.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)
        settings.recEngineEnabled = true
        settings.listeningPocketsEnabled = true
        let spy = Spy()
        let svc = ListeningPocketsService(
            history: history, settings: settings,
            credentials: { ("k-bearer", String(repeating: "ab", count: 32)) },
            provider: CommuterProvider(),
            client: ListeningPocketsClient(base: URL(string: "https://pockets.test")!,
                                           enrollSecret: "enroll", transport: { spy.record($0) }),
            now: { Date(timeIntervalSince1970: Self.nowMs / 1000) },
            syncFileURL: tempURL("sync"), cacheFileURL: tempURL("cache"))
        svc.fixtureForTesting = false
        svc.deviceIdProvider = { "DEVICE-CONTRACT" }
        let sent = await svc.flushNow()
        XCTAssertTrue(sent)
        XCTAssertEqual(spy.bodies.count, 1, "the whole scenario fits one batch")
        return try XCTUnwrap(spy.bodies.first)
    }

    // MARK: - 1. The app's upload IS the golden the cloud consumes

    func testAppUploadMatchesGolden() async throws {
        let body = try await uploadBody()
        let actual = try JSONSerialization.jsonObject(with: body)
        let pretty = try Self.canonical(actual)

        if ProcessInfo.processInfo.environment["PDJ_REGEN_POCKETS_CONTRACT"] != nil {
            let dest = Self.sourceFixtureURL("listening-pockets-upload.app")
            try (pretty + Data("\n".utf8)).write(to: dest, options: .atomic)
            print("[contract] regenerated \(dest.path)")
            return
        }
        let golden = try JSONSerialization.jsonObject(with: try fixtureData("listening-pockets-upload.app"))
        if !(golden as AnyObject).isEqual(actual) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("listening-pockets-upload.app.actual.json")
            try? pretty.write(to: out)
            add(XCTAttachment(data: pretty, uniformTypeIdentifier: "public.json"))
            XCTFail("The app's upload body drifted from Tests/Fixtures/listening-pockets-upload.app.json "
                    + "(actual: \(out.path)). If intended, regenerate BOTH goldens — see the class doc.")
        }

        // The properties the cloud relies on, asserted directly so a regenerated golden can't
        // quietly bless a broken body.
        let obj = try XCTUnwrap(actual as? [String: Any])
        XCTAssertEqual(obj["installId"] as? String, Self.installId)
        XCTAssertEqual((obj["sentAtMs"] as? NSNumber)?.doubleValue, Self.nowMs)
        let events = try XCTUnwrap(obj["events"] as? [[String: Any]])
        let specs = Self.scenario()
        XCTAssertEqual(events.count, specs.count - 1, "everything but the out-of-window play")
        let byId = Dictionary(uniqueKeysWithValues: specs.map { ($0.id.uuidString, $0) })
        for e in events {
            let s = try XCTUnwrap(byId[e["id"] as? String ?? ""])
            XCTAssertEqual((e["atMs"] as? NSNumber)?.int64Value, ListeningPocketsService.flooredMinute(s.playedAt))
            let expected: String
            switch s.kind {
            case .completed: expected = "completed"
            case .skipped: expected = "skipped"
            case .partial: expected = "partial"
            case .unknown: expected = "unknown"
            }
            XCTAssertEqual(e["outcome"] as? String, expected)
            if s.origin != Self.installId {
                XCTAssertTrue(e["ctx"] is NSNull, "a peer's ctx never rides this device's upload")
            } else if Self.nowMs - s.playedAt < ListeningContextConstants.pendingHorizon * 1000 {
                XCTAssertTrue(e["ctx"] is NSNull, "inside the pending horizon nothing is stamped")
            } else {
                XCTAssertNotNil(e["ctx"] as? [String: Any], "settled plays carry their place/trip")
            }
        }
        let sameMinute = events.filter { ($0["ord"] as? Int) == 1 }
        XCTAssertEqual(sameMinute.count, 1, "the quick skip shares its minute and gets ord 1")
        XCTAssertEqual((obj["places"] as? [Any])?.count, 2)
        XCTAssertEqual((obj["trips"] as? [Any])?.count, 2)
    }

    // MARK: - 3. What the cloud computed for that upload decodes and means what it should

    func testCloudResultsForTheAppUploadDecode() throws {
        let data = try fixtureData("listening-pockets-results.app")
        let r = try JSONDecoder().decode(ListeningPocketsResults.self, from: data)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(r.pockets.count, (raw["pockets"] as? [Any])?.count, "no pocket dropped by the decoder")
        XCTAssertEqual(r.patterns.count, (raw["patterns"] as? [Any])?.count, "no pattern dropped by the decoder")
        XCTAssertEqual(r.generatedAtMs, Self.nowMs)
        XCTAssertEqual(r.baseline?.thin, false)

        let specs = Self.scenario()
        let byId = Dictionary(uniqueKeysWithValues: specs.map { ($0.id.uuidString, $0) })
        XCTAssertFalse(r.pockets.isEmpty)
        for p in r.pockets {
            XCTAssertEqual(p.members.count, p.memberCount)
            XCTAssertGreaterThanOrEqual(p.memberCount, 3)
            for m in p.members {
                let s = try XCTUnwrap(byId[m.eventId], "member \(m.eventId) is one of the app's plays")
                XCTAssertNotEqual(s.kind, .skipped, "skips are never pocket members")
                XCTAssertEqual(m.songId, s.songId)
                XCTAssertEqual(m.atMs, Double(ListeningPocketsService.flooredMinute(s.playedAt)))
            }
        }
        // A morning commute: PPPSPP → 5 members, the isolated skip excluded but counted.
        let morning = try XCTUnwrap(r.pockets.first { $0.timeBucket == "morning" && $0.ctx?.tripId == Self.tripAB })
        XCTAssertEqual(morning.memberCount, 5)
        XCTAssertGreaterThanOrEqual(morning.skippedCount, 1)
        // Today's commute is too recent to settle: a pocket, but no context.
        let today = try XCTUnwrap(r.pockets.first { $0.localDate == "2026-10-12" })
        XCTAssertNil(today.ctx)
        // No pocket from the midday hunting (PSSP).
        XCTAssertFalse(r.pockets.contains { $0.timeBucket == "midday" })

        // Direction of travel: A→B mornings and B→A evenings are DIFFERENT recurring patterns.
        let ab = try XCTUnwrap(r.patterns.first { $0.ctx?.tripId == Self.tripAB })
        let ba = try XCTUnwrap(r.patterns.first { $0.ctx?.tripId == Self.tripBA })
        XCTAssertNotEqual(ab.id, ba.id)
        XCTAssertTrue(ab.title.contains("A → B"), ab.title)
        XCTAssertTrue(ab.title.contains("Electronic"), ab.title)
        XCTAssertTrue(ba.title.contains("B → A"), ba.title)
        XCTAssertGreaterThanOrEqual(ab.occurrences, 10)
        let bpm = try XCTUnwrap(ab.numeric["bpm"])
        XCTAssertTrue(bpm.defining)
        XCTAssertGreaterThanOrEqual(bpm.lo, 118)
        XCTAssertLessThanOrEqual(bpm.hi, 124)
        XCTAssertTrue(ab.features.contains { $0.kind == .genre && $0.value == "electronic" })
        XCTAssertFalse(ab.topSongs.isEmpty)
        XCTAssertTrue(Set(ab.songIds).isSubset(of: Set(Self.electronic)))
        // Every pocket's patternId names a pattern in the document.
        let patternIds = Set(r.patterns.map(\.id))
        for p in r.pockets { if let pid = p.patternId { XCTAssertTrue(patternIds.contains(pid), pid) } }

        // The label snapshot the app uploaded comes back and resolves both directions.
        XCTAssertEqual(r.snapshotLabel(for: .trip(Self.tripAB, origin: Self.placeA, destination: Self.placeB)), "A → B")
        XCTAssertEqual(r.snapshotLabel(for: .trip(Self.tripBA, origin: Self.placeB, destination: Self.placeA)), "B → A")
        XCTAssertEqual(r.snapshotLabel(for: .place(Self.placeA)), "Location A")
    }
}
