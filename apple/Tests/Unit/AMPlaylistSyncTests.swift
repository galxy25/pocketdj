import XCTest
@testable import PocketDJ

/// WS2 Apple Music playlist sync — the testable (non-device) logic: the PUSH payload resolution
/// (PocketDJ playlists -> Apple Music catalog ids, dropping the un-hostable), the PULL/PUSH wire
/// decodes (including the idempotent-push row shape and job progress), and the audit-trail
/// summaries. The token mint + live HTTP are device-only and verified separately (server side via
/// curl).
@MainActor
final class AMPlaylistSyncTests: XCTestCase {

    private func tempURL(_ tag: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-\(tag)-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func song(_ id: String, am: String?) -> IndexSong {
        var o: [String: Any] = ["id": id, "name": id, "artist": "A"]
        if let am { o["appleMusicId"] = am }
        return try! JSONDecoder().decode(IndexSong.self, from: try! JSONSerialization.data(withJSONObject: o))
    }

    /// resolveOutgoing keeps only playlists with Apple-Music-hostable songs, mapping each song id to
    /// its catalog id (appleMusicId) in order and dropping songs (and whole playlists) without one.
    func testResolveOutgoingResolvesCatalogIdsAndDropsEmpties() {
        let app = AppModel()
        app.injectDiscoverAdd(song("s1", am: "111"))
        app.injectDiscoverAdd(song("s2", am: "222"))
        app.injectDiscoverAdd(song("s3", am: nil))   // no catalog id -> never pushed
        let collections = CollectionsStore(fileURL: tempURL("col"))
        collections.app = app
        _ = collections.createPlaylist("Mix", songIds: ["s1", "s3", "s2"])
        _ = collections.createPlaylist("NoneHostable", songIds: ["s3"])

        let out = PlaylistAppleMusicSync.resolveOutgoing(collections: collections, app: app)
        // Only "Mix" survives (it has hostable songs); "NoneHostable" is dropped entirely.
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "Mix")
        // s3 (no appleMusicId) is dropped; order of the survivors is preserved.
        XCTAssertEqual(out.first?.trackCatalogIds, ["111", "222"])
    }

    /// A remote playlist row from the Lambda's /pull decodes (optional fields tolerated).
    func testRemotePlaylistDecodes() throws {
        let pl = try JSONDecoder().decode(AMPlaylistSyncClient.RemotePlaylist.self, from: Data("""
        {"id":"p.1","name":"Faves","canEdit":true,"trackCatalogIds":["111","222"]}
        """.utf8))
        XCTAssertEqual(pl.id, "p.1")
        XCTAssertEqual(pl.name, "Faves")
        XCTAssertEqual(pl.canEdit, true)
        XCTAssertEqual(pl.trackCatalogIds, ["111", "222"])
        XCTAssertNil(pl.trackTitles)
    }

    /// The IDEMPOTENT push result decodes: per-playlist rows carry created-vs-matched and how many
    /// tracks this sync actually appended (the "only add the missing 209" contract).
    func testPushResultDecodes() throws {
        let r = try JSONDecoder().decode(AMPlaylistSyncClient.PushResult.self, from: Data("""
        {"playlists":[{"name":"comfort zone","id":"p.abc","created":false,"added":209,"total":1000},
                      {"name":"Fresh","id":"p.def","created":true,"added":42,"total":42}],
         "errors":[{"name":"Bad","error":"AM POST -> 403"}]}
        """.utf8))
        XCTAssertEqual(r.playlists.count, 2)
        XCTAssertEqual(r.playlists[0].name, "comfort zone")
        XCTAssertFalse(r.playlists[0].created)          // matched an existing playlist — no duplicate
        XCTAssertEqual(r.playlists[0].added, 209)       // topped up only the missing tracks
        XCTAssertEqual(r.playlists[0].total, 1000)
        XCTAssertTrue(r.playlists[1].created)
        XCTAssertEqual(r.errors.first?.name, "Bad")
    }

    /// Job progress decodes and renders a human step line for the sync UI.
    func testJobProgressDisplay() throws {
        let p = try JSONDecoder().decode(AMPlaylistSyncClient.JobProgress.self, from: Data("""
        {"label":"Reading “Roadtrip”","done":37,"total":126}
        """.utf8))
        XCTAssertEqual(p.display, "Reading “Roadtrip” (37/126)")
        let open = try JSONDecoder().decode(AMPlaylistSyncClient.JobProgress.self, from: Data("""
        {"label":"Listing Apple Music playlists","done":200,"total":null}
        """.utf8))
        XCTAssertEqual(open.display, "Listing Apple Music playlists (200)")
    }

    /// The audit-trail summary lines compress the per-playlist changes faithfully.
    func testSummaryTexts() {
        XCTAssertEqual(
            PlaylistAppleMusicSync.pushSummaryText(created: 2, updated: 1, addedTracks: 209, unchanged: 9, failed: 0),
            "created 2 · updated 1 (+209 songs) · 9 already in sync")
        XCTAssertEqual(
            PlaylistAppleMusicSync.pushSummaryText(created: 0, updated: 0, addedTracks: 0, unchanged: 0, failed: 0),
            "Nothing to push")
        let changes: [PlaylistAppleMusicSync.SyncReport.Change] = [
            .init(kind: "created", name: "Fresh", added: 42, removed: 0, detail: nil),
            .init(kind: "updated", name: "comfort zone", added: 209, removed: 0, detail: nil),
            .init(kind: "reconciled", name: "Mix", added: 0, removed: 3, detail: nil),
        ]
        XCTAssertEqual(PlaylistAppleMusicSync.reportSummaryText(changes: changes, errors: []),
                       "1 created · 1 updated · 1 reconciled")
        XCTAssertEqual(PlaylistAppleMusicSync.reportSummaryText(changes: [], errors: ["boom"]),
                       "Everything in sync · 1 error")
    }

    /// POCKETS THAT CAME FROM APPLE MUSIC PLAYLISTS sync two-way like the playlist they were
    /// (Levi 2026-07-29: "only syncing my playlists, not pockets that came from playlists").
    /// Either Apple Music source qualifies; hand-made pockets stay local.
    func testResolveOutgoingIncludesAppleMusicSourcedPockets() {
        let app = AppModel()
        app.injectDiscoverAdd(song("s1", am: "111"))
        app.injectDiscoverAdd(song("s2", am: "222"))
        app.injectDiscoverAdd(song("s3", am: "333"))
        let collections = CollectionsStore(fileURL: tempURL("pockets"))
        collections.app = app

        // A pocket converted from a PRIVATE-catalog source playlist.
        let privateSource = SourcePlaylist(
            playlist: IndexPlaylist(id: "pl_x", name: "comfort zone", songIds: ["s1", "s2"]),
            sourceName: Config.appleMusicSourceName)
        _ = collections.convertToPocket(source: privateSource)
        // A pocket linked to the PUBLIC on-device library source.
        let publicSource = SourcePlaylist(
            playlist: IndexPlaylist(id: "amlibpl_y", name: "road trip", songIds: ["s3"]),
            sourceName: AppleMusicLibraryStore.sourceName)
        _ = collections.convertToPocket(source: publicSource)
        // A hand-made pocket — NO provenance — must stay local.
        _ = collections.createPocket("secret weapons", songIds: ["s1", "s3"])

        let out = PlaylistAppleMusicSync.resolveOutgoing(collections: collections, app: app)
        let names = Set(out.map(\.name))
        XCTAssertTrue(names.contains("comfort zone"))
        XCTAssertTrue(names.contains("road trip"))
        XCTAssertFalse(names.contains("secret weapons"))
        XCTAssertEqual(out.first(where: { $0.name == "comfort zone" })?.trackCatalogIds, ["111", "222"])
        XCTAssertEqual(out.first(where: { $0.name == "road trip" })?.trackCatalogIds, ["333"])
    }

    /// A converted POCKET and a PLAYLIST that normName-collide merge into ONE outgoing list —
    /// the pocket's remote twin converges instead of duplicating.
    func testResolveOutgoingMergesPocketWithSameNamedPlaylist() {
        let app = AppModel()
        app.injectDiscoverAdd(song("s1", am: "111"))
        app.injectDiscoverAdd(song("s2", am: "222"))
        let collections = CollectionsStore(fileURL: tempURL("pocketmerge"))
        collections.app = app
        _ = collections.createPlaylist("Mix", songIds: ["s1"])
        let source = SourcePlaylist(
            playlist: IndexPlaylist(id: "pl_m", name: "Mix ", songIds: ["s2"]),   // trailing space
            sourceName: Config.appleMusicSourceName)
        _ = collections.convertToPocket(source: source)

        let out = PlaylistAppleMusicSync.resolveOutgoing(collections: collections, app: app)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(Set(out.first?.trackCatalogIds ?? []), ["111", "222"])
    }

    /// The pull-import dedupe covers POCKET names too: a remote playlist whose local twin is a
    /// converted pocket must not re-import as a duplicate playlist beside it.
    func testImportDedupeSkipsConvertedPocketTwin() {
        let app = AppModel()
        app.injectDiscoverAdd(song("s1", am: "111"))
        let collections = CollectionsStore(fileURL: tempURL("pocketdedupe"))
        collections.app = app
        let source = SourcePlaylist(
            playlist: IndexPlaylist(id: "pl_c", name: "Comfort Zone", songIds: ["s1"]),
            sourceName: Config.appleMusicSourceName)
        _ = collections.convertToPocket(source: source)

        let existing = PlaylistAppleMusicSync.existingCollectionNames(collections: collections)
        XCTAssertTrue(existing.contains("comfort zone"))
        let remote: [AMPlaylistSyncClient.RemotePlaylist] = [
            .init(id: "p.1", name: "comfort zone ", canEdit: true, description: nil,
                  trackCatalogIds: ["111"], trackTitles: nil),
            .init(id: "p.2", name: "Fresh", canEdit: true, description: nil,
                  trackCatalogIds: ["9"], trackTitles: nil),
        ]
        let imports = PlaylistAppleMusicSync.newImports(remote: remote, existingNames: existing)
        XCTAssertEqual(imports.map(\.name), ["Fresh"])   // the pocket's twin is NOT re-imported
    }

    /// PER-COLLECTION SYNC DIRECTION (Levi 2026-07-29: smart-playlist mirrors must NEVER push):
    /// "Get only"/"Off" collections are excluded from the push payload; "Send only" stays in.
    func testResolveOutgoingHonorsDirection() {
        let app = AppModel()
        app.injectDiscoverAdd(song("s1", am: "111"))
        app.injectDiscoverAdd(song("s2", am: "222"))
        let collections = CollectionsStore(fileURL: tempURL("direction"))
        collections.app = app
        let pullOnly = collections.createPlaylist("comfort zone", songIds: ["s1"])
        collections.setAMSyncDirection(.pull, forPlaylist: pullOnly.id)
        let off = collections.createPlaylist("archived", songIds: ["s1"])
        collections.setAMSyncDirection(.off, forPlaylist: off.id)
        let pushOnly = collections.createPlaylist("bangers", songIds: ["s2"])
        collections.setAMSyncDirection(.push, forPlaylist: pushOnly.id)
        _ = collections.createPlaylist("normal", songIds: ["s1"])   // nil direction = two-way

        // A pull-only AM-sourced POCKET is excluded too (the smart-playlist pocket case).
        let source = SourcePlaylist(
            playlist: IndexPlaylist(id: "pl_p", name: "potential", songIds: ["s2"]),
            sourceName: Config.appleMusicSourceName)
        let pocket = collections.convertToPocket(source: source)
        collections.setAMSyncDirection(.pull, forPocket: pocket.id)

        let names = Set(PlaylistAppleMusicSync.resolveOutgoing(collections: collections, app: app).map(\.name))
        XCTAssertEqual(names, ["bangers", "normal"])
    }

    /// The instant write-back respects the direction gate: a "Get only" collection reports
    /// `.pushDisabled` — never enqueues an upstream write (force-sync included).
    func testWriteBackRespectsDirection() {
        let app = AppModel()
        app.injectDiscoverAdd(song("s1", am: "111"))
        let collections = CollectionsStore(fileURL: tempURL("wbdir"))
        collections.app = app
        let source = SourcePlaylist(
            playlist: IndexPlaylist(id: "pl_c", name: "comfort zone", songIds: []),
            sourceName: Config.appleMusicSourceName)
        let pocket = collections.convertToPocket(source: source)
        collections.addSong("s1", toPocket: pocket.id)
        collections.setAMSyncDirection(.pull, forPocket: pocket.id)
        XCTAssertEqual(collections.forceWriteBackSong("s1", forTargetKind: .pocket,
                                                      collectionId: pocket.id), .pushDisabled)
        // Flip back to two-way: no longer direction-blocked (falls through to the normal path).
        collections.setAMSyncDirection(.both, forPocket: pocket.id)
        XCTAssertNotEqual(collections.forceWriteBackSong("s1", forTargetKind: .pocket,
                                                         collectionId: pocket.id), .pushDisabled)
    }

    /// The source-follow PULL respects the direction gate: "Send only" stops following the
    /// source; "Get only" keeps following it.
    func testSourceFollowRespectsDirection() {
        let collections = CollectionsStore(fileURL: tempURL("followdir"))
        let source = SourcePlaylist(
            playlist: IndexPlaylist(id: "pl_f", name: "flow", songIds: ["a"]),
            sourceName: Config.appleMusicSourceName)
        let pocket = collections.convertToPocket(source: source)

        // Source grows; a SEND-ONLY pocket must NOT pull the add.
        collections.setAMSyncDirection(.push, forPocket: pocket.id)
        let grown = SourcePlaylist(
            playlist: IndexPlaylist(id: "pl_f", name: "flow", songIds: ["a", "b"]),
            sourceName: Config.appleMusicSourceName)
        XCTAssertEqual(collections.syncConvertedCollections(with: [grown]), 0)
        XCTAssertEqual(collections.pocket(pocket.id)?.songIds, ["a"])

        // GET-ONLY pulls it.
        collections.setAMSyncDirection(.pull, forPocket: pocket.id)
        XCTAssertEqual(collections.syncConvertedCollections(with: [grown]), 1)
        XCTAssertEqual(collections.pocket(pocket.id)?.songIds, ["a", "b"])
    }

    /// The direction survives a persist/reload round-trip (additive schema — no version bump).
    func testDirectionPersists() {
        let url = tempURL("dirpersist")
        let collections = CollectionsStore(fileURL: url)
        let pl = collections.createPlaylist("comfort zone", songIds: [])
        collections.setAMSyncDirection(.pull, forPlaylist: pl.id)
        let reloaded = CollectionsStore(fileURL: url)
        XCTAssertEqual(reloaded.playlist(pl.id)?.amSyncDir, .pull)
    }

    /// normName mirrors the server's rule (trim + lowercase + collapse whitespace) — client and
    /// server must agree on what "same name" means or the pull re-imports what the push merged.
    func testNormName() {
        XCTAssertEqual(PlaylistAppleMusicSync.normName("Sap "), "sap")            // Library.xml trailing space
        XCTAssertEqual(PlaylistAppleMusicSync.normName("  Comfort   Zone "), "comfort zone")
        XCTAssertEqual(PlaylistAppleMusicSync.normName("MIX"), "mix")
    }

    /// Same-named local playlists merge into ONE outgoing list (ordered union, duplicate ids
    /// dropped) — otherwise push and reconcile fight over the single remote playlist forever.
    func testResolveOutgoingMergesNormNameCollisions() {
        let app = AppModel()
        app.injectDiscoverAdd(song("s1", am: "111"))
        app.injectDiscoverAdd(song("s2", am: "222"))
        app.injectDiscoverAdd(song("s3", am: "333"))
        let collections = CollectionsStore(fileURL: tempURL("col2"))
        collections.app = app
        _ = collections.createPlaylist("Sap ", songIds: ["s1", "s2"])   // trailing space
        _ = collections.createPlaylist("Sap", songIds: ["s2", "s3"])    // same normName, overlap s2

        let out = PlaylistAppleMusicSync.resolveOutgoing(collections: collections, app: app)
        XCTAssertEqual(out.count, 1)                                    // merged, not two
        XCTAssertEqual(out.first?.trackCatalogIds, ["111", "222", "333"]) // ordered union, no dup 222
    }

    /// Pull-import skips normName matches of existing locals and collapses same-named remote
    /// copies (old-bug duplicates) to the fullest one — k copies import once, not k times.
    func testNewImportsDedupesAndSkipsExisting() {
        let remote: [AMPlaylistSyncClient.RemotePlaylist] = [
            .init(id: "p.1", name: "Sap", canEdit: true, description: nil, trackCatalogIds: ["1"], trackTitles: nil),
            .init(id: "p.2", name: "comfort zone", canEdit: true, description: nil, trackCatalogIds: ["1", "2"], trackTitles: nil),
            .init(id: "p.3", name: "Comfort Zone", canEdit: true, description: nil, trackCatalogIds: ["1", "2", "3"], trackTitles: nil),
            .init(id: "p.4", name: "Fresh", canEdit: true, description: nil, trackCatalogIds: ["9"], trackTitles: nil),
        ]
        // Local already has "Sap " (normName "sap") -> remote "Sap" must NOT re-import.
        let existing = Set([PlaylistAppleMusicSync.normName("Sap ")])
        let imports = PlaylistAppleMusicSync.newImports(remote: remote, existingNames: existing)
        XCTAssertEqual(imports.map(\.id), ["p.3", "p.4"])   // fullest comfort-zone copy + Fresh
    }

    /// A sync report round-trips through Codable (the persisted audit-trail format).
    func testSyncReportCodableRoundTrip() throws {
        let report = PlaylistAppleMusicSync.SyncReport(
            dateMs: 1_785_400_000_000,
            changes: [.init(kind: "updated", name: "comfort zone", added: 209, removed: 0,
                            detail: "209 of 1000 tracks sent")],
            errors: [], summary: "1 updated")
        let data = try JSONEncoder().encode([report])
        let back = try JSONDecoder().decode([PlaylistAppleMusicSync.SyncReport].self, from: data)
        XCTAssertEqual(back, [report])
    }

    /// The persisted CURRENT RUN hydrates at init — and a snapshot that never completed (the app
    /// died mid-sync) comes back with its running steps flagged interrupted, so the last sync is
    /// always inspectable and shows as resumable rather than vanishing.
    func testCurrentRunHydratesAndMarksInterrupted() throws {
        let runURL = tempURL("run")
        let snapshot: [String: Any] = [
            "startedMs": 1_785_400_000_000.0,
            "updatedMs": 1_785_400_120_000.0,
            "completed": false,
            "steps": [
                ["id": 0, "label": "Preparing playlists", "detail": "12 playlists · 640 tracks", "state": "done"],
                ["id": 1, "label": "Pushing to Apple Music", "detail": "Adding to “comfort zone” (300/1000)", "state": "running"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: runURL)

        let sync = PlaylistAppleMusicSync(transport: nil, auditURL: tempURL("audit"), runURL: runURL)
        XCTAssertEqual(sync.currentRunStartedMs, 1_785_400_000_000.0)
        XCTAssertFalse(sync.currentRunCompleted)
        XCTAssertEqual(sync.steps.count, 2)
        XCTAssertEqual(sync.steps[0].state, .done)                 // finished steps stay finished
        XCTAssertEqual(sync.steps[1].state, .interrupted)          // dead-process running -> interrupted
        XCTAssertEqual(sync.steps[1].detail, "Adding to “comfort zone” (300/1000)")
    }

    /// A COMPLETED snapshot hydrates verbatim (no interrupted remap) — the "always double-check
    /// the last sync" case.
    func testCompletedRunHydratesVerbatim() throws {
        let runURL = tempURL("run2")
        let snapshot: [String: Any] = [
            "startedMs": 1_785_400_000_000.0,
            "updatedMs": 1_785_400_500_000.0,
            "completed": true,
            "steps": [["id": 0, "label": "Importing new playlists", "detail": "2 imported", "state": "done"]],
        ]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: runURL)

        let sync = PlaylistAppleMusicSync(transport: nil, auditURL: tempURL("audit2"), runURL: runURL)
        XCTAssertTrue(sync.currentRunCompleted)
        XCTAssertEqual(sync.steps.first?.state, .done)
    }
}
