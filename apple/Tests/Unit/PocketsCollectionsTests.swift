import XCTest
@testable import PocketDJ

/// Pockets × collections (docs/design/pockets-collections.md), app half:
///   · `CollectionFlattener` — effective membership (albums expanded, child pockets flattened,
///     deduped, cycle-safe), caps, add times (latest add not followed by a remove; album / child
///     pocket adds credit expanded songs), the song-level add history (window, cap, newest first);
///   · `ListeningPocketsCollections` — payload hash gating (changed content or ≥ 24 h), the
///     per-event `contextId` / `contextKind` mapping, and the flush (own batch, ids only, opt-in);
///   · results decoding with and without the new optional fields;
///   · the scorer: membership pull (a song SIMILAR to a playlist's songs pulls those songs in),
///     no-collections parity, and learning a `collection` target.
@MainActor
final class PocketsCollectionsTests: XCTestCase {

    typealias Ev = CollectionActivityStore.ActivityEvent
    static let day = 86_400_000.0

    static func ev(_ kind: CollectionActivityStore.ActivityKind, _ item: String, in cid: String?,
                   at: Double) -> Ev {
        Ev(id: UUID(), at: at, kind: kind, itemId: item, itemTitle: nil, itemArtist: nil,
           collectionId: cid, collectionKind: cid == nil ? nil : "playlist",
           collectionName: cid == nil ? nil : "Name of \(cid!)", originInstallId: "I")
    }

    static func seq(_ nodes: [PlaylistNode]) -> PlaylistNode {
        PlaylistNode(nodeId: "nd_\(UUID().uuidString)", kind: .sequence, name: "Main", children: nodes)
    }
    static func node(_ kind: PlaylistNode.Kind, _ id: String) -> PlaylistNode {
        switch kind {
        case .song: return PlaylistNode(nodeId: "nd_\(id)", kind: .song, songId: id)
        case .album: return PlaylistNode(nodeId: "nd_\(id)", kind: .album, albumId: id)
        case .pocket: return PlaylistNode(nodeId: "nd_\(id)", kind: .pocket, pocketId: id)
        default: return PlaylistNode(nodeId: "nd_\(id)", kind: kind, text: id)
        }
    }

    /// pkt_a: s1, album alb_1 (s2, s3), child pkt_b. pkt_b: s3, s4, child pkt_a (a CYCLE).
    /// pls_x: s5, album alb_1, a nested chapter holding pocket pkt_b and s5 again, a text node.
    static let albumTracks = ["alb_1": ["s2", "s3"]]
    static let pockets = [
        Pocket(id: "pkt_a", name: "Pocket A", songIds: ["s1"], albumIds: ["alb_1"], childPocketIds: ["pkt_b"]),
        Pocket(id: "pkt_b", name: "Pocket B", songIds: ["s3", "s4"], childPocketIds: ["pkt_a"]),
    ]
    static let playlists = [
        Playlist(id: "pls_x", name: "Playlist X", sequences: [
            seq([node(.song, "s5"), node(.album, "alb_1"),
                 seq([node(.pocket, "pkt_b"), node(.song, "s5"), node(.text, "cue")])])
        ])
    ]
    static var source: CollectionFlattener.Source {
        .init(pockets: pockets, playlists: playlists,
              sourcePlaylists: [(id: "pl_src", name: "Source", songIds: ["s9", "s9", "s8"])],
              albumTracks: albumTracks)
    }

    // MARK: - Flattening

    func testFlattenExpandsAlbumsAndChildPocketsDedupedAndCycleSafe() {
        let flat = CollectionFlattener.flatten(Self.source)
        XCTAssertEqual(flat.map(\.id), ["pkt_a", "pkt_b", "pls_x", "pl_src"])
        XCTAssertEqual(flat.map(\.kind), ["pocket", "pocket", "playlist", "source"])
        XCTAssertEqual(flat[0].songIds, ["s1", "s2", "s3", "s4"], "own, album tracks, child pocket — deduped")
        XCTAssertEqual(flat[1].songIds, ["s3", "s4", "s1", "s2"], "the cycle back to A terminates")
        XCTAssertEqual(flat[2].songIds, ["s5", "s2", "s3", "s4", "s1"], "nested chapter, pocket node flattened")
        XCTAssertEqual(flat[3].songIds, ["s9", "s8"])
    }

    /// The rec engine's snapshot and the pockets upload share ONE flattening.
    func testRecSnapshotAndPocketsUploadShareTheFlattening() {
        let payload = ListeningPocketsCollections.build(.init(source: Self.source), nowMs: 1_000 * Self.day)
        XCTAssertEqual(payload.collections.map(\.songIds), CollectionFlattener.flatten(Self.source).map(\.songIds))
    }

    func testCapsTrimCollectionsSongsAndTotal() {
        let cs = (0..<5).map { i in
            CollectionFlattener.Collection(id: "c\(i)", kind: "pocket", name: "",
                                           songIds: (0..<10).map { "c\(i)s\($0)" })
        }
        let capped = CollectionFlattener.capped(cs, collectionCap: 4, songCap: 6, totalCap: 15)
        XCTAssertEqual(capped.count, 4)
        XCTAssertEqual(capped.map(\.songIds.count), [6, 6, 3, 0], "per-collection cap, then the total budget")
        XCTAssertEqual(capped[0].songIds, Array(cs[0].songIds.prefix(6)))
    }

    func testSpecCapsAndOversizedSourcePlaylistsLeftOut() {
        XCTAssertEqual(ListeningPocketsCollections.collectionCap, 500)
        XCTAssertEqual(ListeningPocketsCollections.songCap, 5_000)
        XCTAssertEqual(ListeningPocketsCollections.totalSongCap, 100_000)
        XCTAssertEqual(ListeningPocketsCollections.addEventsCap, 5_000)
        var src = Self.source
        src.sourcePlaylists.append((id: "pl_library", name: "Library", songIds: (0..<5_001).map { "L\($0)" }))
        let big = (0..<6_000).map { "P\($0)" }
        src.pockets.append(Pocket(id: "pkt_big", name: "Big", songIds: big))
        let flat = ListeningPocketsCollections.flattened(src)
        XCTAssertFalse(flat.contains { $0.id == "pl_library" }, "a library-sized source playlist is not a vibe")
        XCTAssertEqual(flat.first { $0.id == "pkt_big" }?.songIds.count, 5_000, "a user's own pocket is truncated, not dropped")
    }

    // MARK: - Add history

    func testAddTimesLatestAddNotFollowedByRemoveAndExpandedCredit() {
        let t = 100 * Self.day
        let activity = [
            Self.ev(.add, "s1", in: "pkt_a", at: t + 1),
            Self.ev(.remove, "s1", in: "pkt_a", at: t + 2),
            Self.ev(.add, "s1", in: "pkt_a", at: t + 3),          // re-added: the latest add stands
            Self.ev(.add, "alb_1", in: "pkt_a", at: t + 4),       // album credits s2, s3
            Self.ev(.add, "s3", in: "pkt_b", at: t + 5),          // before B joined A
            Self.ev(.add, "pkt_b", in: "pkt_a", at: t + 6),       // child pocket credits B's songs
            Self.ev(.add, "s4", in: "pkt_b", at: t + 7),          // after B joined A → A sees t+7
            Self.ev(.add, "s5", in: "pls_x", at: t + 8),
            Self.ev(.remove, "s5", in: "pls_x", at: t + 9),       // removed and not re-added → unknown
            Self.ev(.heart, "s5", in: nil, at: t + 10),           // hearts are not membership
        ]
        let flat = CollectionFlattener.flatten(Self.source)
        let adds = CollectionFlattener.addTimes(collections: flat, activity: activity,
                                                pockets: Self.pockets, albumTracks: Self.albumTracks)
        // s1: direct (re-added) t+3 — B joining later didn't change it. s3: in via the album at
        // t+4 before B brought it again. s4: via B only, added to B after B joined A → t+7.
        XCTAssertEqual(adds["pkt_a"], ["s1": t + 3, "s2": t + 4, "s3": t + 4, "s4": t + 7])
        XCTAssertEqual(adds["pkt_b"], ["s3": t + 5, "s4": t + 7])
        XCTAssertNil(adds["pls_x"], "a removed song has no standing add")

        // On the wire: unknown adds omitted, ms integral.
        let payload = ListeningPocketsCollections.build(.init(source: Self.source, activity: activity), nowMs: t + Self.day)
        let a = payload.collections.first { $0.id == "pkt_a" }!
        XCTAssertEqual(a.adds.map(\.songId), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(a.adds.first?.atMs, Int64(t + 3))
        XCTAssertTrue(payload.collections.first { $0.id == "pls_x" }!.adds.isEmpty)
    }

    func testAddEventsExpandedWindowedCappedNewestFirst() {
        let now = 1_000 * Self.day
        let activity = [
            Self.ev(.add, "s1", in: "pkt_a", at: now - 400 * Self.day),   // outside 365 d
            Self.ev(.add, "alb_1", in: "pls_x", at: now - 10 * Self.day),
            Self.ev(.remove, "s5", in: "pls_x", at: now - 5 * Self.day),
            Self.ev(.heart, "s5", in: nil, at: now - 1 * Self.day),
        ]
        let rows = CollectionFlattener.addEvents(activity: activity, pockets: Self.pockets,
                                                 albumTracks: Self.albumTracks,
                                                 sinceMs: now - 365 * Self.day)
        XCTAssertEqual(rows.map(\.songId), ["s5", "s2", "s3"])
        XCTAssertEqual(rows.map(\.kind), ["remove", "add", "add"])
        XCTAssertEqual(rows.map(\.collectionId), ["pls_x", "pls_x", "pls_x"])
        let capped = CollectionFlattener.addEvents(activity: activity, pockets: Self.pockets,
                                                   albumTracks: Self.albumTracks, sinceMs: 0, cap: 2)
        XCTAssertEqual(capped.count, 2)
        XCTAssertEqual(capped.map(\.songId), ["s5", "s2"], "newest first under the cap")
        // The Delete-cloud-data floor bounds it from below too.
        let floored = ListeningPocketsCollections.build(.init(source: Self.source, activity: activity),
                                                        nowMs: now, floorMs: now - 7 * Self.day)
        XCTAssertEqual(floored.addEvents.map(\.songId), ["s5"])
    }

    // MARK: - Hash gating

    func testHashGatingChangedContentOr24Hours() {
        let now = 1_000 * Self.day
        let a = ListeningPocketsCollections.build(.init(source: Self.source), nowMs: now)
        let b = ListeningPocketsCollections.build(.init(source: Self.source), nowMs: now + 5_000)
        XCTAssertEqual(a.hash, b.hash, "the hash never covers the send time")
        var changed = Self.source
        changed.pockets[0].songIds.append("s7")
        XCTAssertNotEqual(ListeningPocketsCollections.build(.init(source: changed), nowMs: now).hash, a.hash)

        XCTAssertTrue(ListeningPocketsCollections.isDue(hash: a.hash, lastHash: nil, lastSentAtMs: nil, nowMs: now))
        XCTAssertFalse(ListeningPocketsCollections.isDue(hash: a.hash, lastHash: a.hash, lastSentAtMs: now - 3_600_000, nowMs: now))
        XCTAssertTrue(ListeningPocketsCollections.isDue(hash: a.hash, lastHash: a.hash, lastSentAtMs: now - Self.day, nowMs: now))
        XCTAssertTrue(ListeningPocketsCollections.isDue(hash: "other", lastHash: a.hash, lastSentAtMs: now - 1, nowMs: now))
    }

    // MARK: - Event context

    func testContextMapping() {
        typealias C = ListeningPocketsCollections
        XCTAssertEqual(C.context(contextId: "pkt_1", source: .setlist)?.kind, "pocket")
        XCTAssertEqual(C.context(contextId: "pls_1", source: .setlist)?.kind, "playlist")
        XCTAssertEqual(C.context(contextId: "set_1", source: .setlist)?.kind, "setlist")
        XCTAssertEqual(C.context(contextId: "pl_am_1", source: .playlist)?.kind, "source")
        XCTAssertNil(C.context(contextId: nowPlayingSetlistId, source: .pocket), "the Now Playing queue is not a collection")
        XCTAssertNil(C.context(contextId: "itp_ABC", source: .setlist), "a game run is not a collection")
        XCTAssertNil(C.context(contextId: "mix_1", source: .mix))
        XCTAssertNil(C.context(contextId: nil, source: .pocket))
    }

    func testWireEncodesContextIdOnlyWhenPresent() throws {
        func json(_ e: ListeningPocketsUploadEvent) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as! [String: Any]
        }
        var e = ListeningPocketsUploadEvent(id: "E", songId: "s1", atMs: 60_000, ord: 0, tzOffsetMin: 0,
                                            source: "pocket", outcome: "completed", fraction: 1,
                                            originInstallId: nil, artist: nil, carPlay: nil, ctx: nil)
        let bare = try json(e)
        XCTAssertNil(bare["contextId"]); XCTAssertNil(bare["contextKind"])
        let fpBare = ListeningPocketsService.fingerprint(e)
        XCTAssertEqual(fpBare, "completed|100|-|0", "pre-collections fingerprints are unchanged (no mass re-send)")
        e.contextId = "pkt_1"; e.contextKind = "pocket"
        let withCtx = try json(e)
        XCTAssertEqual(withCtx["contextId"] as? String, "pkt_1")
        XCTAssertEqual(withCtx["contextKind"] as? String, "pocket")
        XCTAssertNotEqual(ListeningPocketsService.fingerprint(e), fpBare, "gaining a context re-sends once")
    }

    // MARK: - The flush

    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [[String: Any]] = []
        var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _bodies }
        func record(_ req: URLRequest) -> (Data, URLResponse) {
            lock.lock()
            if req.httpMethod == "POST", let d = req.httpBody,
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { _bodies.append(o) }
            lock.unlock()
            return (Data(#"{"ok":true}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @MainActor
    private final class NoLocation: ListeningContextProviding {
        var isSupported = false
        var isActive = false
        var revision = 0
        func context(at date: Date) -> ListeningContextLookup { .unavailable }
        func placeLabels() -> [ListeningPlaceLabel] { [] }
        func tripLabels() -> [ListeningTripLabel] { [] }
        func label(for tag: ListeningContextTag) -> String? { nil }
    }

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-pcoll-\(name)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFlushSendsCollectionsInTheirOwnBatchIdsOnlyAndGatesResends() async throws {
        let suite = "pdj.pcoll.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.recEngineEnabled = true
        settings.listeningPocketsEnabled = true
        let history = PlayHistoryStore(fileURL: tempURL("history"))
        var nowMs = 1_791_806_400_000.0
        // A play that started from a pocket via the Now Playing queue (its origin rides along).
        var play = PlayHistoryStore.PlayEvent(id: UUID(), songId: "s1", playedAt: nowMs - 600_000, source: .pocket,
                                              contextId: nowPlayingSetlistId, contextName: "Pocket A",
                                              title: nil, artist: "A", originInstallId: history.installId)
        play.originCollectionId = "pkt_a"
        history.replaceAll([play])
        let spy = Spy()
        let client = ListeningPocketsClient(base: URL(string: "https://pockets.test")!, enrollSecret: "x",
                                            transport: { spy.record($0) })
        let svc = ListeningPocketsService(history: history, settings: settings,
                                          credentials: { ("k", String(repeating: "ab", count: 32)) },
                                          provider: NoLocation(), client: client,
                                          now: { Date(timeIntervalSince1970: nowMs / 1000) },
                                          syncFileURL: tempURL("sync"), cacheFileURL: tempURL("cache"))
        svc.fixtureForTesting = false
        svc.deviceIdProvider = { "DEVICE-1" }
        var src = Self.source
        let activity = [Self.ev(.add, "s1", in: "pkt_a", at: nowMs - Self.day)]
        svc.collectionsProvider = { .init(source: src, activity: activity) }

        await svc.flushNow()
        var bodies = spy.bodies
        XCTAssertEqual(bodies.count, 2, "events batch, then the collections batch")
        let events = bodies[0]["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(events.first?["contextId"] as? String, "pkt_a", "the run's origin, not the queue id")
        XCTAssertEqual(events.first?["contextKind"] as? String, "pocket")
        XCTAssertNil(bodies[0]["collections"])
        let coll = bodies[1]
        XCTAssertEqual((coll["events"] as? [Any])?.count, 0, "membership rides its own batch")
        let cs = coll["collections"] as? [[String: Any]] ?? []
        XCTAssertEqual(cs.map { $0["id"] as? String }, ["pkt_a", "pkt_b", "pls_x", "pl_src"])
        XCTAssertNotNil(coll["addEvents"])
        let text = String(data: try JSONSerialization.data(withJSONObject: coll), encoding: .utf8)!
        for name in ["Pocket A", "Pocket B", "Playlist X", "Source", "Name of"] {
            XCTAssertFalse(text.contains(name), "collection names never leave the device (\(name))")
        }
        XCTAssertNil(cs.first?["name"])

        // Unchanged within 24 h → not re-sent.
        nowMs += 3_600_000
        await svc.flushNow()
        XCTAssertEqual(spy.bodies.count, 2)
        // Content changed → re-sent.
        src.pockets[0].songIds.append("s7")
        await svc.flushNow()
        bodies = spy.bodies
        XCTAssertEqual(bodies.count, 3)
        XCTAssertNotNil(bodies[2]["collections"])
        // Unchanged but ≥ 24 h since the last ack → re-sent.
        nowMs += Self.day
        await svc.flushNow()
        XCTAssertEqual(spy.bodies.count, 4)
        XCTAssertNotNil(spy.bodies[3]["collections"])

        // Opt-in off → nothing at all.
        settings.listeningPocketsEnabled = false
        src.pockets[0].songIds.append("s8")
        await svc.flushNow()
        XCTAssertEqual(spy.bodies.count, 4)
    }

    // MARK: - Results decoding

    func testResultsDecodeWithAndWithoutCollectionFields() throws {
        let old = #"""
        {"v":1,"generatedAtMs":1,"stale":false,"pockets":[{"id":"pk_1","members":[{"songId":"s1"}]}],
         "patterns":[{"id":"pt_1","topSongs":[{"songId":"s1","plays":2}]}]}
        """#
        let o = try JSONDecoder().decode(ListeningPocketsResults.self, from: Data(old.utf8))
        XCTAssertNil(o.collectionsSeen)
        XCTAssertEqual(o.pockets.first?.membership, [])
        XCTAssertEqual(o.patterns.first?.membership, [])
        XCTAssertEqual(o.patterns.first?.collectionCandidates, [])

        let new = #"""
        {"v":1,"generatedAtMs":1,"stale":false,"algo":{"version":3},"collectionsSeen":7,
         "pockets":[{"id":"pk_1","members":[{"songId":"s1"}],
           "features":[{"dim":"collection","value":"pls_x","label":"pls_x","share":0.6,"lift":2,"score":0.5},
                       {"dim":"playContext","value":"pocket","label":"Pocket","share":0.5,"lift":1.5,"score":0.2}],
           "membership":[{"collectionId":"pls_x","weight":0.7},{"collectionId":"pkt_a","weight":0.3},
                         {"weight":0.1},{"collectionId":"bad","weight":"x"}]}],
         "patterns":[{"id":"pt_1","topSongs":[{"songId":"s1","plays":2}],
           "membership":[{"collectionId":"pls_x","weight":1}],
           "collectionCandidates":[{"songId":"s2","score":0.8,"via":["pls_x"]},{"songId":"s3"},{"score":1}],
           "unknownField":{"a":1}}]}
        """#
        let n = try JSONDecoder().decode(ListeningPocketsResults.self, from: Data(new.utf8))
        XCTAssertEqual(n.collectionsSeen, 7)
        XCTAssertEqual(n.algoVersion, 3)
        let p = try XCTUnwrap(n.pockets.first)
        XCTAssertEqual(p.membership, [.init(collectionId: "pls_x", weight: 0.7), .init(collectionId: "pkt_a", weight: 0.3)],
                       "malformed rows dropped one by one")
        XCTAssertEqual(p.features.map(\.kind), [.collection, .playContext])
        let pt = try XCTUnwrap(n.patterns.first)
        XCTAssertEqual(pt.membership, [.init(collectionId: "pls_x", weight: 1)])
        XCTAssertEqual(pt.collectionCandidates, [.init(songId: "s2", score: 0.8, via: ["pls_x"]),
                                                 .init(songId: "s3", score: 0, via: [])])
    }

    func testCollectionFeatureRelabelledLocally() {
        let f = ListeningPocketFeature(dim: "collection", value: "pls_x", label: "pls_x", share: 0.5, lift: 2, score: 1)
        let named = ListeningPocketLabeler(results: nil, location: nil, collectionNames: ["pls_x": "Friday Warmup"])
        XCTAssertEqual(named.label(for: f), "Friday Warmup")
        let gone = ListeningPocketLabeler(results: nil, location: nil)
        XCTAssertEqual(gone.label(for: f), "Earlier collection", "never the raw id")
    }

    // MARK: - Scorer

    // 2026-10-13 (Tue) 19:30 local at UTC−7.
    static let nowMs = 1_791_945_000_000.0
    static let tz = -420
    static let evening = InThePocketContext.make(atMs: nowMs, tzOffsetMin: tz, ctx: nil)

    /// Funk around 120 (the playlist's sound), rock fast, jazz slow.
    static let catalog: [String: InThePocketScorer.Song] = {
        var out: [String: InThePocketScorer.Song] = [:]
        func add(_ id: String, _ genre: String, _ bpm: Double, _ moods: [String] = []) {
            out[id] = .init(id: id, title: "T-\(id)", artist: "Artist-\(id)", lengthMs: 200_000,
                            genre: genre, bpm: bpm, moods: moods)
        }
        add("f1", "funk", 118, ["groovy"]); add("f2", "funk", 120, ["groovy"]); add("f3", "funk", 122, ["groovy"])
        add("f4", "funk", 121, ["groovy"]); add("live", "funk", 119, ["groovy"])
        add("r1", "rock", 150); add("r2", "rock", 155); add("r3", "rock", 148); add("r4", "rock", 152)
        add("j1", "jazz", 90); add("j2", "jazz", 95); add("j3", "jazz", 92)
        return out
    }()

    /// Ten weeks of evenings: rock and jazz, never funk — so without collections nothing pulls funk.
    static let plays: [InThePocketScorer.Play] = {
        var out: [InThePocketScorer.Play] = []
        for w in 1...10 {
            for (i, id) in ["r1", "r2", "j1", "j2"].enumerated() {
                out.append(.init(songId: id, atMs: nowMs - Double(w) * 7 * day + Double(i) * 240_000,
                                 tzOffsetMin: tz, outcome: "completed", ctx: nil))
            }
        }
        return out
    }()

    /// The funk playlist (f1, f2, f3) and a rock pocket (r3, r4).
    static let collections = [
        InThePocketScorer.CollectionInfo(id: "pls_funk", name: "Funk Friday", songIds: ["f1", "f2", "f3"],
                                         addedAtMs: ["f1": nowMs - 2 * day]),
        InThePocketScorer.CollectionInfo(id: "pkt_rock", name: "Rock", songIds: ["r3", "r4"]),
    ]

    static func input(plays: [InThePocketScorer.Play] = plays, results: ListeningPocketsResults? = nil,
                      collections: [InThePocketScorer.CollectionInfo] = collections) -> InThePocketScorer.Input {
        InThePocketScorer.Input(context: evening, contextLabel: nil, results: results, catalog: catalog,
                                playableIds: Set(catalog.keys), plays: plays, pastRounds: [], nowMs: nowMs,
                                seed: 7, recentExclusionMs: 30 * 60_000, collections: collections)
    }

    static func scores(_ input: InThePocketScorer.Input) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: InThePocketScorer.scoreCandidates(input).scored.map { ($0.song.id, $0.score) })
    }

    /// Levi's example: playing a song SIMILAR to a playlist's songs (not in it) pulls that
    /// playlist's songs into consideration — they gain score and become eligible.
    func testPlayingASongSimilarToAPlaylistPullsThePlaylistsSongsIn() {
        let live = InThePocketScorer.Play(songId: "live", atMs: Self.nowMs - 10 * 60_000, tzOffsetMin: Self.tz,
                                          outcome: "completed", ctx: nil)
        let before = Self.scores(Self.input(plays: Self.plays + [live], collections: []))
        let after = Self.scores(Self.input(plays: Self.plays + [live]))
        for id in ["f1", "f2", "f3"] {
            XCTAssertGreaterThan(after[id] ?? 0, before[id] ?? 0, "\(id) is in the playlist the live song sounds like")
        }
        let (profile, _, scored) = InThePocketScorer.scoreCandidates(Self.input(plays: Self.plays + [live]))
        XCTAssertNotNil(profile.membership["pls_funk"], "the live song's SOFT membership put the playlist in the profile")
        XCTAssertTrue(scored.first { $0.song.id == "f1" }?.why.contains("Like Funk Friday") == true)
        // A similar NON-member (f4) is pulled too — "or similar ones" — but a member pulls at least as hard.
        XCTAssertGreaterThan(after["f4"] ?? 0, 0)
        XCTAssertGreaterThanOrEqual(after["f1"] ?? 0, after["f4"] ?? 0)
    }

    func testSoftMembershipAndAddRecency() throws {
        let funk = try XCTUnwrap(InThePocketScorer.Centroid(Self.collections[0], catalog: Self.catalog))
        XCTAssertGreaterThan(InThePocketScorer.similarity(Self.catalog["f4"]!, funk), InThePocketScorer.softMin)
        XCTAssertLessThan(InThePocketScorer.similarity(Self.catalog["r1"]!, funk), InThePocketScorer.softMin)
        XCTAssertNil(InThePocketScorer.Centroid(Self.collections[1], catalog: Self.catalog),
                     "fewer than 3 resolvable members ⇒ hard membership only")
        XCTAssertEqual(InThePocketScorer.addScale(nil, refMs: Self.nowMs), 0.75)
        XCTAssertEqual(InThePocketScorer.addScale(Self.nowMs, refMs: Self.nowMs), 1, accuracy: 1e-9)
        XCTAssertEqual(InThePocketScorer.addScale(Self.nowMs - 45 * Self.day, refMs: Self.nowMs),
                       0.5 + 0.5 * exp(-1), accuracy: 1e-9)
    }

    /// Membership is CURRENT and retroactive: a song added to a collection AFTER it was played
    /// still labels that old play, and the add-recency scale is measured from NOW.
    func testMembershipIsRetroactiveAndRecencyIsFromNow() {
        // r1 was played weeks ago (every evening in `plays`); it joined "Late adds" only yesterday.
        let late = InThePocketScorer.CollectionInfo(id: "pls_late", name: "Late adds", songIds: ["r1", "zz"],
                                                    addedAtMs: ["r1": Self.nowMs - Self.day])
        let p = InThePocketScorer.scoreCandidates(Self.input(collections: [late])).profile
        XCTAssertNotNil(p.membership["pls_late"], "an add after the play still counts")
        let index = InThePocketScorer.MembershipIndex(Self.input(collections: [late]))
        XCTAssertEqual(index.hard("r1", refMs: Self.nowMs)["pls_late"] ?? 0,
                       0.5 + 0.5 * exp(-1.0 / 45), accuracy: 1e-9, "age = now − add, not play − add")
    }

    /// No collections ⇒ the round is exactly what it was before the feature; collections that
    /// touch nothing in the round are inert too.
    func testNoCollectionsParity() {
        let none = InThePocketScorer.build(Self.input(collections: []))
        let inert = InThePocketScorer.build(Self.input(collections: [
            .init(id: "pls_far", name: "Far", songIds: ["zz1", "zz2", "zz3"]),
        ]))
        guard case .success(let a) = none, case .success(let b) = inert else { return XCTFail("expected rounds") }
        XCTAssertEqual(a.picks, b.picks)
        XCTAssertFalse(a.targets.contains { $0.dim == "collection" })
        XCTAssertEqual(InThePocketScorer.scoreCandidates(Self.input(collections: [])).profile.membership, [:])
    }

    func testCloudMembershipAndCandidatesFeedTheRound() throws {
        let json = """
        {"v":1,"generatedAtMs":1791940000000,"stale":false,"pockets":[],
         "patterns":[{"id":"pt_1","pocketIds":["a","b"],"occurrences":2,"dayType":"\(Self.evening.dayType)",
           "timeBucket":"\(Self.evening.timeBucket)",
           "features":[{"dim":"genre","value":"jazz","label":"Jazz","share":0.8,"lift":2,"score":0.5}],
           "topSongs":[{"songId":"j1","plays":3}],
           "membership":[{"collectionId":"pls_funk","weight":1}],
           "collectionCandidates":[{"songId":"r4","score":0.9,"via":["pkt_rock"]}]}]}
        """
        let results = try JSONDecoder().decode(ListeningPocketsResults.self, from: Data(json.utf8))
        let (profile, _, scored) = InThePocketScorer.scoreCandidates(Self.input(plays: [], results: results))
        XCTAssertEqual(profile.mode, .cloud)
        XCTAssertEqual(profile.membership, ["pls_funk": 1])
        let ids = Set(scored.map(\.song.id))
        XCTAssertTrue(ids.isSuperset(of: ["f1", "f2", "f3"]), "the pattern's collection pulls its songs in")
        XCTAssertTrue(ids.contains("r4"), "a cloud collection candidate is considered")
        guard case .success(let out) = InThePocketScorer.build(Self.input(plays: [], results: results)) else {
            return XCTFail("expected a round")
        }
        XCTAssertEqual(out.targets.filter { $0.dim == "collection" }.map(\.value), ["pls_funk"])
        XCTAssertEqual(out.targets.first { $0.dim == "collection" }?.label, "Funk Friday", "local name, label only")
    }

    /// Round learning re-weights collections: a collection that keeps predicting well here joins
    /// the profile; one that keeps breaking pulls less.
    func testLearningACollectionTarget() throws {
        let key = Self.evening.learningKeys.last!
        func results(_ weights: String) throws -> ListeningPocketsResults {
            let json = """
            {"v":1,"generatedAtMs":1791940000000,"stale":false,"pockets":[],
             "patterns":[{"id":"pt_1","occurrences":2,"dayType":"\(Self.evening.dayType)","timeBucket":"\(Self.evening.timeBucket)",
               "features":[{"dim":"genre","value":"jazz","label":"Jazz","share":0.8,"lift":2,"score":0.5}],
               "topSongs":[{"songId":"j1","plays":3}],
               "membership":[{"collectionId":"pls_funk","weight":1}]}],
             "rounds":{"total":5,"pocket":4,"contexts":[{"key":"\(key)","rounds":5,"weights":[\(weights)]}]}}
            """
            return try JSONDecoder().decode(ListeningPocketsResults.self, from: Data(json.utf8))
        }
        let learned = try results(#"{"dim":"collection","value":"pkt_rock","pos":3,"neg":0,"multiplier":1.8},"#
                                  + #"{"dim":"collection","value":"pls_funk","pos":0,"neg":3,"multiplier":0.4}"#)
        let base = InThePocketScorer.scoreCandidates(Self.input(plays: [], results: try results(""))).profile
        let p = InThePocketScorer.scoreCandidates(Self.input(plays: [], results: learned)).profile
        XCTAssertNil(base.membership["pkt_rock"])
        XCTAssertNotNil(p.membership["pkt_rock"], "a well-predicting collection joins the vector")
        XCTAssertLessThan(p.membership["pls_funk"] ?? 1, base.membership["pls_funk"] ?? 0, "a breaking one pulls less")
        let s = Self.scores(Self.input(plays: [], results: learned))
        XCTAssertNotNil(s["r3"], "the learned collection's songs are now related")

        // The on-device learner keys `collection` targets like any other.
        var round = InThePocketRound(
            id: UUID(), createdAtMs: Self.nowMs, startedAtMs: Self.nowMs, endedAtMs: Self.nowMs, updatedAtMs: Self.nowMs,
            tzOffsetMin: Self.tz, context: Self.evening, contextLabel: nil, mode: .history, seed: "1",
            algoVersion: InThePocketScorer.algoVersion,
            targets: [InThePocketTarget(dim: "collection", value: "pkt_rock", label: "Rock", weight: 1)],
            songs: [], outcome: .pocket, rating: nil, feedback: nil, appVersion: nil)
        round.outcome = .pocket
        let ctx = InThePocketLearning.contexts([round, round])
        XCTAssertEqual(ctx[key]?["collection\u{0}pkt_rock"]?.pos, 2)
    }
}
