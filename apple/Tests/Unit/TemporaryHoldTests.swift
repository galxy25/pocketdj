import XCTest
@testable import PocketDJ

/// np-mix-mode PHASE 1 — the temporary-vs-pinned asset ledger (`BurnStore.TemporaryHold`).
///
/// The contract under test: ABSENCE OF A HOLD = PINNED. A hold is created only by the buffer lane
/// (`AssetOrigin.buffer`), only for an asset that call CREATED (a file already on the device —
/// or a song that was ever downloaded — never becomes temporary), and EVERY explicit Download /
/// Mix action pins (drops the hold, keeps the files), including when the file already exists.
/// Hermetic: burns under `appBurnsDirOverride`, ledger in a temp file, downloads from a stub
/// `URLProtocol`, an injected clock.
@MainActor
final class TemporaryHoldTests: XCTestCase {
    private let ripsBase = URL(string: "https://rips.test")!
    private var dir: URL!
    private var indexURL: URL!
    private let t0: Double = 1_800_000_000_000
    private let hourMs: Double = 3_600_000

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-holds-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-holds-index-\(UUID().uuidString).json")
        HoldStubURLProtocol.body = Data(repeating: 7, count: 64)
        HoldStubURLProtocol.onRequest = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: indexURL)
        HoldStubURLProtocol.onRequest = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeRips() -> RipsStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HoldStubURLProtocol.self]
        return RipsStore(ripsBase: ripsBase, session: URLSession(configuration: config))
    }

    private func stems(_ id: String) -> RipsStore.Stems {
        RipsStore.Stems(vocals: "stems/\(id)/vocals.mp3", drums: "stems/\(id)/drums.mp3",
                        bass: "stems/\(id)/bass.mp3", other: "stems/\(id)/other.mp3")
    }

    private func makeBurns(_ rips: RipsStore, items: [BurnStore.BurnItem] = [],
                           settings: SettingsStore? = nil) throws -> BurnStore {
        if !items.isEmpty {
            try JSONEncoder().encode(BurnStore.Document(items: items)).write(to: indexURL)
        }
        let burns = BurnStore(rips: rips, fileURL: indexURL)
        burns.appBurnsDirOverride = dir
        burns.settings = settings
        burns.clockMs = { [t0] in t0 }
        return burns
    }

    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    private func readyItem(_ id: String, file: String? = nil, bytes: Int = 10) -> BurnStore.BurnItem {
        BurnStore.BurnItem(songId: id, title: "T-\(id)", artist: "A",
                           audioFileName: file ?? "\(id).mp3", sidecarFileName: "\(id).txt",
                           source: "digital", bpm: nil, musicalKey: nil, camelot: nil,
                           durationMs: nil, startMs: nil, bytes: bytes, rippedAt: nil,
                           downloadedAt: 1, state: .ready, error: nil, wasAppStorage: true)
    }

    private func write(_ name: String, bytes: Int = 10) throws {
        try Data(repeating: 1, count: bytes).write(to: dir.appendingPathComponent(name))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private func tempFile(bytes: Int = 50) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-holds-stream-\(UUID().uuidString).mp3")
        try Data(repeating: 3, count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func hold(_ id: String, audio: Bool = false, parts: [String] = [],
                      expiresInHours: Double = 48) -> BurnStore.TemporaryHold {
        BurnStore.TemporaryHold(songId: id, audio: audio, stemParts: parts, createdAtMs: t0,
                                expiresAtMs: t0 + expiresInHours * hourMs, audioBytes: audio ? 10 : nil,
                                stemBytes: Dictionary(uniqueKeysWithValues: parts.map { ($0, 5) }))
    }

    // MARK: Migration — absence of a hold = pinned

    /// A ledger written before this feature (no `temporaryHolds` key at all) decodes with NO
    /// holds: every file already on the device stays a download.
    func testPreFeatureLedgerDecodesWithEveryFilePinned() throws {
        let json = """
        {"schemaVersion":1,"items":[{"songId":"sng_old","title":"Old","artist":"A",
        "audioFileName":"sng_old.mp3","sidecarFileName":"sng_old.txt","source":"digital",
        "bytes":10,"downloadedAt":5,"state":"ready"}]}
        """
        try Data(json.utf8).write(to: indexURL)
        try write("sng_old.mp3")
        let burns = try makeBurns(makeRips())
        XCTAssertEqual(burns.items.count, 1, "the old ledger still decodes")
        XCTAssertTrue(burns.temporaryHolds.isEmpty, "no holds ⇒ everything pinned")
        XCTAssertFalse(burns.isTemporary("sng_old"))
        XCTAssertNil(burns.temporaryExpiry("sng_old"))
    }

    /// Holds persist with the ledger (the sweep after a relaunch must still know what's temporary)
    /// and the Document stays decodable by the same build.
    func testHoldsRoundTripThroughTheLedgerFile() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_r": .init(key: "rips/sng_r.mp3", source: "digital", stems: stems("sng_r"))])
        let burns = try makeBurns(rips)
        let ok = await burns.burnStemPart(forSong: "sng_r", part: "vocals", origin: .buffer)
        XCTAssertTrue(ok)
        let reloaded = BurnStore(rips: rips, fileURL: indexURL)
        XCTAssertEqual(reloaded.temporaryHolds["sng_r"]?.stemParts, ["vocals"])
        XCTAssertEqual(reloaded.temporaryHolds["sng_r"]?.expiresAtMs, t0 + 48 * hourMs)
    }

    // MARK: Creation — only what the buffer lane CREATED

    func testBufferStemPartHoldsANewPartWithFixedExpiry() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_s": .init(key: "rips/sng_s.mp3", source: "digital", stems: stems("sng_s"))])
        let burns = try makeBurns(rips)
        let ok = await burns.burnStemPart(forSong: "sng_s", part: "drums", origin: .buffer)
        XCTAssertTrue(ok)
        XCTAssertTrue(exists("stem-sng_s-drums.mp3"))
        let h = try XCTUnwrap(burns.temporaryHolds["sng_s"])
        XCTAssertFalse(h.audio, "only the stem was created — the hold must not claim the audio")
        XCTAssertEqual(h.stemParts, ["drums"])
        XCTAssertEqual(h.stemBytes?["drums"], 64)
        XCTAssertEqual(h.createdAtMs, t0)
        XCTAssertEqual(h.expiresAtMs, t0 + 48 * hourMs, "fixed 48 h from landing (Q3 default)")
        XCTAssertFalse(burns.isTemporary("sng_s"), "isTemporary is about the AUDIO")
    }

    func testBufferStemPartAlreadyOnDiskIsNeverHeld() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_e": .init(key: "rips/sng_e.mp3", source: "digital", stems: stems("sng_e"))])
        try write("stem-sng_e-vocals.mp3")
        let burns = try makeBurns(rips)
        let ok = await burns.burnStemPart(forSong: "sng_e", part: "vocals", origin: .buffer)
        XCTAssertTrue(ok)
        XCTAssertNil(burns.temporaryHolds["sng_e"], "a part already on the device never becomes temporary")
    }

    /// RACE: an explicit burn lands the same part while the buffer download is in flight — the
    /// explicit file stands and no hold is written (check + write share one main-actor turn).
    func testBufferPartThatLandedExplicitlyMidDownloadStaysPinned() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_x": .init(key: "rips/sng_x.mp3", source: "digital", stems: stems("sng_x"))])
        let burns = try makeBurns(rips)
        let dest = dir.appendingPathComponent("stem-sng_x-bass.mp3")
        HoldStubURLProtocol.onRequest = { _ in try? Data("EXPLICIT".utf8).write(to: dest) }
        let ok = await burns.burnStemPart(forSong: "sng_x", part: "bass", origin: .buffer)
        XCTAssertTrue(ok)
        XCTAssertNil(burns.temporaryHolds["sng_x"], "the explicit landing wins — no hold")
        XCTAssertEqual(try Data(contentsOf: dest), Data("EXPLICIT".utf8), "the explicit bytes are untouched")
    }

    func testBufferAdoptionHoldsTheAudio() throws {
        let rips = makeRips()
        rips.setManifest(["sng_a": .init(key: "rips/sng_a.mp3", source: "digital")])
        let burns = try makeBurns(rips)
        let url = burns.adoptStreamedFile(songId: "sng_a", title: "A", artist: "B",
                                          from: try tempFile(bytes: 50), origin: .buffer)
        XCTAssertNotNil(url)
        let h = try XCTUnwrap(burns.temporaryHolds["sng_a"])
        XCTAssertTrue(h.audio)
        XCTAssertEqual(h.audioBytes, 50)
        XCTAssertTrue(burns.isTemporary("sng_a"))
        XCTAssertEqual(burns.items["sng_a"]?.state, .ready, "a buffered song is a real, playable burn")
    }

    /// The design's core rule: something that WAS downloaded never turns temporary — even when
    /// its file was purged (re-landed by the buffer), while an explicit download of it is in
    /// flight, or while one is owed after a rip.
    func testBufferAdoptionNeverHoldsAnExplicitlyOwnedSong() throws {
        let rips = makeRips()
        rips.setManifest(["sng_p": .init(key: "rips/sng_p.mp3", source: "digital"),
                          "sng_o": .init(key: "rips/sng_o.mp3", source: "digital")])
        // sng_p: a .ready row whose file iOS purged.
        let burns = try makeBurns(rips, items: [readyItem("sng_p")])
        XCTAssertNotNil(burns.adoptStreamedFile(songId: "sng_p", title: "P", artist: "A",
                                                from: try tempFile(), origin: .buffer))
        XCTAssertNil(burns.temporaryHolds["sng_p"], "a once-downloaded song is re-landed pinned")
        // sng_o: the user asked for it (pending after rip).
        burns.burnWhenRipped(songId: "sng_o", title: "O", artist: "A", nowMs: 1)
        XCTAssertNotNil(burns.adoptStreamedFile(songId: "sng_o", title: "O", artist: "A",
                                                from: try tempFile(), origin: .buffer))
        XCTAssertNil(burns.temporaryHolds["sng_o"], "an owed explicit download is never temporary")
    }

    func testBufferAdoptionOfAReadyLocalSongIsANoOp() throws {
        let rips = makeRips()
        rips.setManifest(["sng_l": .init(key: "rips/sng_l.mp3", source: "digital")])
        try write("sng_l.mp3")
        let burns = try makeBurns(rips, items: [readyItem("sng_l")])
        XCTAssertNil(burns.adoptStreamedFile(songId: "sng_l", title: "L", artist: "A",
                                             from: try tempFile(), origin: .buffer))
        XCTAssertTrue(burns.temporaryHolds.isEmpty)
    }

    func testKeepTTLMakesBufferAssetsNormalDownloads() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_k": .init(key: "rips/sng_k.mp3", source: "digital", stems: stems("sng_k"))])
        let settings = makeSettings()
        settings.npMixBufferTTLHours = SettingsStore.npMixBufferKeepSentinel
        let burns = try makeBurns(rips, settings: settings)
        _ = await burns.burnStemPart(forSong: "sng_k", part: "vocals", origin: .buffer)
        XCTAssertNotNil(burns.adoptStreamedFile(songId: "sng_k", title: "K", artist: "A",
                                                from: try tempFile(), origin: .buffer))
        XCTAssertTrue(burns.temporaryHolds.isEmpty, "Keep ⇒ pinned at creation")
        XCTAssertTrue(exists("stem-sng_k-vocals.mp3"))
    }

    func testTTLSettingSetsTheExpiryOfNewHolds() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_t": .init(key: "rips/sng_t.mp3", source: "digital", stems: stems("sng_t"))])
        let settings = makeSettings()
        settings.npMixBufferTTLHours = 6
        let burns = try makeBurns(rips, settings: settings)
        _ = await burns.burnStemPart(forSong: "sng_t", part: "other", origin: .buffer)
        XCTAssertEqual(burns.temporaryExpiry("sng_t"), t0 + 6 * hourMs)
    }

    /// A later asset for the same song moves the hold's expiry LATER (never earlier).
    func testALaterAssetExtendsTheHoldNeverShortens() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_m": .init(key: "rips/sng_m.mp3", source: "digital", stems: stems("sng_m"))])
        let burns = try makeBurns(rips)
        _ = await burns.burnStemPart(forSong: "sng_m", part: "vocals", origin: .buffer)
        burns.clockMs = { [t0, hourMs] in t0 + 10 * hourMs }
        _ = await burns.burnStemPart(forSong: "sng_m", part: "drums", origin: .buffer)
        let h = try XCTUnwrap(burns.temporaryHolds["sng_m"])
        XCTAssertEqual(Set(h.stemParts), ["vocals", "drums"])
        XCTAssertEqual(h.expiresAtMs, t0 + 58 * hourMs)
        XCTAssertEqual(h.createdAtMs, t0)
    }

    /// REVIEW FIX: a song the user tried to download (the attempt failed — an `.error` row) is
    /// explicitly owned; a later buffer landing of it is a download, not a temporary copy.
    func testBufferAdoptionOfAFailedExplicitDownloadIsPinned() throws {
        let rips = makeRips()
        rips.setManifest(["sng_fe": .init(key: "rips/sng_fe.mp3", source: "digital")])
        var failed = readyItem("sng_fe")
        failed.state = .error; failed.audioFileName = ""; failed.error = "network"
        let burns = try makeBurns(rips, items: [failed])
        XCTAssertNotNil(burns.adoptStreamedFile(songId: "sng_fe", title: "E", artist: "A",
                                                from: try tempFile(), origin: .buffer))
        XCTAssertTrue(burns.temporaryHolds.isEmpty)
    }

    /// REVIEW FIX: a row reconcile drops (its file vanished) takes its audio hold with it — no
    /// stale hold may later expire a re-landed copy.
    func testReconcileDropsTheAudioHoldOfAVanishedFile() throws {
        let burns = try makeBurns(makeRips(), items: [readyItem("sng_v")])   // no file on disk
        burns.injectHoldForTesting(hold("sng_v", audio: true, parts: ["vocals"]))
        burns.reconcileOnLaunch()
        XCTAssertNil(burns.items["sng_v"])
        XCTAssertEqual(burns.temporaryHolds["sng_v"]?.audio, false)
        XCTAssertEqual(burns.temporaryHolds["sng_v"]?.stemParts, ["vocals"], "its stem parts stay held")
    }

    /// REVIEW FIX: assets buffered into a user-picked folder are deleted only while that SAME
    /// folder is active. After a folder switch, a same-named file in the new folder is not ours.
    func testUserFolderSwitchReleasesHeldPartsInsteadOfDeletingSameNamedFiles() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_uf": .init(key: "rips/sng_uf.mp3", source: "digital", stems: stems("sng_uf"))])
        func folder() throws -> (URL, Data) {
            let d = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdj-holds-uf-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: d) }
            return (d, try XCTUnwrap(BurnStore.makeBookmark(for: d)))
        }
        let (a, bookmarkA) = try folder()
        let (b, bookmarkB) = try folder()
        let settings = makeSettings()
        settings.burnFolderBookmark = bookmarkA
        let burns = try makeBurns(rips, settings: settings)
        // Plant the hold directly (the folder-switch rule is the primitive's, whoever created it).
        let partA = a.appendingPathComponent("stem-sng_uf-vocals.mp3")
        try Data("BUF".utf8).write(to: partA)
        var planted = hold("sng_uf", parts: ["vocals"])
        planted.stemPartsInUserFolder = ["vocals"]
        planted.userFolderPath = a.standardizedFileURL.path
        burns.injectHoldForTesting(planted)
        // Switch folders; B already holds an EXPLICIT copy under the same name.
        settings.burnFolderBookmark = bookmarkB
        let partB = b.appendingPathComponent("stem-sng_uf-vocals.mp3")
        try Data("EXPLICIT".utf8).write(to: partB)
        let r = burns.removeTemporaryAssets(songIds: ["sng_uf"])
        XCTAssertEqual(r.songs, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partB.path), "the new folder's file is not ours")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partA.path), "released, not deleted")
        XCTAssertTrue(burns.temporaryHolds.isEmpty)
    }

    /// Same folder still active ⇒ the user-folder part IS deleted (the release is only for switches).
    func testUserFolderPartIsDeletedWhileItsFolderIsActive() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_uk": .init(key: "rips/sng_uk.mp3", source: "digital", stems: stems("sng_uk"))])
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-holds-uk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        let settings = makeSettings()
        settings.burnFolderBookmark = try XCTUnwrap(BurnStore.makeBookmark(for: d))
        let burns = try makeBurns(rips, settings: settings)
        let part = d.appendingPathComponent("stem-sng_uk-drums.mp3")
        try Data("BUF".utf8).write(to: part)
        var planted = hold("sng_uk", parts: ["drums"])
        planted.stemPartsInUserFolder = ["drums"]
        planted.userFolderPath = d.standardizedFileURL.path
        burns.injectHoldForTesting(planted)
        burns.removeTemporaryAssets(songIds: ["sng_uk"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    // MARK: Picked burn folders (Levi 2026-11-02 — reverses the phase-1 "pinned at creation")

    private func pickedFolder(_ tag: String) throws -> (URL, Data) {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-holds-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return (d, try XCTUnwrap(BurnStore.makeBookmark(for: d)))
    }

    private func sweepManager(_ burns: BurnStore, _ settings: SettingsStore) -> StorageManager {
        let statsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-holds-stats-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: statsURL) }
        return StorageManager(burns: burns, playStats: PlayStatsStore(fileURL: statsURL), settings: settings)
    }

    /// DEFAULT (toggle off): what our buffer lane wrote into a picked folder is tracked like app
    /// storage — folder + file identity in the hold — and the expiry sweep deletes it.
    func testPickedFolderBufferedAssetsExpireAndAreDeleted() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_pf": .init(key: "rips/sng_pf.mp3", source: "digital", stems: stems("sng_pf"))])
        let (d, bookmark) = try pickedFolder("pf")
        let settings = makeSettings()
        settings.burnFolderBookmark = bookmark
        let burns = try makeBurns(rips, settings: settings)
        let ok = await burns.burnStemPart(forSong: "sng_pf", part: "vocals", origin: .buffer)
        XCTAssertTrue(ok)
        let audio = try XCTUnwrap(burns.adoptStreamedFile(songId: "sng_pf", title: "P", artist: "A",
                                                          from: try tempFile(), origin: .buffer))
        XCTAssertEqual(audio.deletingLastPathComponent().standardizedFileURL.path, d.standardizedFileURL.path)
        let h = try XCTUnwrap(burns.temporaryHolds["sng_pf"], "picked-folder buffer assets are temporary")
        XCTAssertTrue(h.audio)
        XCTAssertEqual(h.stemParts, ["vocals"])
        XCTAssertEqual(h.stemPartsInUserFolder, ["vocals"])
        XCTAssertEqual(h.userFolderPath, d.standardizedFileURL.path, "folder identity recorded")
        XCTAssertEqual(Set(h.userFolderFiles?.keys.map { $0 } ?? []),
                       [audio.lastPathComponent, "stem-sng_pf-vocals.mp3"], "file identity recorded")
        // Expire it: the sweep deletes both files and the row.
        let r = await sweepManager(burns, settings).sweepTemporary(now: t0 + 49 * hourMs, reason: "test")
        XCTAssertEqual(r?.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("stem-sng_pf-vocals.mp3").path))
        XCTAssertNil(burns.items["sng_pf"])
        XCTAssertTrue(burns.temporaryHolds.isEmpty)
    }

    /// An EXPLICIT download of the same song on THIS device pins it (files kept through expiry).
    func testExplicitDownloadOnThisDevicePinsAPickedFolderBuffer() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_pe": .init(key: "rips/sng_pe.mp3", source: "digital", stems: stems("sng_pe"))])
        let (d, bookmark) = try pickedFolder("pe")
        let settings = makeSettings()
        settings.burnFolderBookmark = bookmark
        let burns = try makeBurns(rips, settings: settings)
        _ = await burns.burnStemPart(forSong: "sng_pe", part: "drums", origin: .buffer)
        let audio = try XCTUnwrap(burns.adoptStreamedFile(songId: "sng_pe", title: "P", artist: "A",
                                                          from: try tempFile(), origin: .buffer))
        XCTAssertNotNil(burns.temporaryHolds["sng_pe"])
        _ = await burns.burn([(id: "sng_pe", title: "P", artist: "A")])     // ⤓ Download, same name
        XCTAssertNil(burns.temporaryHolds["sng_pe"], "an explicit action on this device pins")
        let r = await sweepManager(burns, settings).sweepTemporary(now: t0 + 500 * hourMs, reason: "test")
        XCTAssertEqual(r?.removed ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("stem-sng_pe-drums.mp3").path))
    }

    /// A file already sitting in the picked folder (audio at the adoption name, a stem part) is
    /// never made temporary — and survives every sweep.
    func testPreExistingPickedFolderFilesAreUntouched() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_px": .init(key: "rips/sng_px.mp3", source: "digital", stems: stems("sng_px"))])
        let (d, bookmark) = try pickedFolder("px")
        let settings = makeSettings()
        settings.burnFolderBookmark = bookmark
        // Learn the adoption name, then lose the ledger (the file stays: an orphan / another
        // device's download).
        let probe = try makeBurns(rips, settings: settings)
        let url = try XCTUnwrap(probe.adoptStreamedFile(songId: "sng_px", title: "X", artist: "A",
                                                        from: try tempFile(), origin: .explicit("probe")))
        try? FileManager.default.removeItem(at: indexURL)
        let part = d.appendingPathComponent("stem-sng_px-bass.mp3")
        try Data("THEIRS".utf8).write(to: part)
        let burns = try makeBurns(rips, settings: settings)
        XCTAssertNotNil(burns.adoptStreamedFile(songId: "sng_px", title: "X", artist: "A",
                                                from: try tempFile(), origin: .buffer))
        let ok = await burns.burnStemPart(forSong: "sng_px", part: "bass", origin: .buffer)
        XCTAssertTrue(ok)
        XCTAssertNil(burns.temporaryHolds["sng_px"], "pre-existing files never become temporary")
        await sweepManager(burns, settings).sweepTemporary(now: t0 + 500 * hourMs, reason: "test", ignoreExpiry: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: part), Data("THEIRS".utf8))
    }

    /// A buffered picked-folder file REWRITTEN since we wrote it (another device's download into
    /// the shared folder) is no longer ours: the sweep releases it instead of deleting it.
    func testPickedFolderFileRewrittenSinceBufferedIsReleasedNotDeleted() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_pr": .init(key: "rips/sng_pr.mp3", source: "digital", stems: stems("sng_pr"))])
        let (d, bookmark) = try pickedFolder("pr")
        let settings = makeSettings()
        settings.burnFolderBookmark = bookmark
        let burns = try makeBurns(rips, settings: settings)
        _ = await burns.burnStemPart(forSong: "sng_pr", part: "other", origin: .buffer)
        let part = d.appendingPathComponent("stem-sng_pr-other.mp3")
        try Data("REWRITTEN".utf8).write(to: part)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: part.path)
        let r = burns.removeTemporaryAssets(songIds: ["sng_pr"])
        XCTAssertEqual(r.songs, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path), "released, not deleted")
        XCTAssertTrue(burns.temporaryHolds.isEmpty)
    }

    /// REVIEW MUST (2026-11-02): an iCloud Drive picked folder keeps another device's EVICTED file
    /// as a hidden `.<name>.icloud` placeholder — `fileExists` at the real name says no. The lane's
    /// write replaces that shared file; holding it would let this device's sweep delete the other
    /// device's download everywhere. Never temporary (a part with no placeholder still is).
    func testEvictedICloudCopyInAPickedFolderIsNeverHeld() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_ic": .init(key: "rips/sng_ic.mp3", source: "digital", stems: stems("sng_ic"))])
        let (d, bookmark) = try pickedFolder("ic")
        let settings = makeSettings()
        settings.burnFolderBookmark = bookmark
        try Data("stub".utf8).write(to: d.appendingPathComponent(".stem-sng_ic-vocals.mp3.icloud"))
        let burns = try makeBurns(rips, settings: settings)
        let okV = await burns.burnStemPart(forSong: "sng_ic", part: "vocals", origin: .buffer)
        let okD = await burns.burnStemPart(forSong: "sng_ic", part: "drums", origin: .buffer)
        XCTAssertTrue(okV && okD)
        XCTAssertEqual(burns.temporaryHolds["sng_ic"]?.stemParts, ["drums"],
                       "the part over an evicted iCloud copy is never temporary; a fresh one is")
        burns.removeTemporaryAssets(songIds: ["sng_ic"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("stem-sng_ic-vocals.mp3").path))
        // Audio: the adoption name's placeholder makes the adopted file pre-existing too.
        let probe = try makeBurns(rips, settings: makeSettings())
        let name = try XCTUnwrap(probe.adoptStreamedFile(songId: "sng_ic", title: "I", artist: "A",
                                                         from: try tempFile(), origin: .explicit("probe"))).lastPathComponent
        try? FileManager.default.removeItem(at: indexURL)
        try Data("stub".utf8).write(to: d.appendingPathComponent(".\(name).icloud"))
        let burns2 = try makeBurns(rips, settings: settings)
        let audio = try XCTUnwrap(burns2.adoptStreamedFile(songId: "sng_ic", title: "I", artist: "A",
                                                           from: try tempFile(), origin: .buffer))
        XCTAssertEqual(audio.lastPathComponent, name)
        XCTAssertFalse(burns2.temporaryHolds["sng_ic"]?.audio ?? false, "audio over an evicted copy is never temporary")
    }

    /// REVIEW MUST (2026-11-02): device B's EXPLICIT stems download reuses the parts device A's
    /// buffer lane wrote into the SHARED picked folder (`burnStemPart`/`burnStems` return an existing
    /// part as-is — no rewrite). B now claims them (bumps the modification time), so A's sweep sees
    /// them rewritten and releases them instead of deleting B's download.
    func testAnotherDevicesExplicitReuseOfASharedBufferedPartIsNeverDeleted() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_sx": .init(key: "rips/sng_sx.mp3", source: "digital", stems: stems("sng_sx"))])
        let (d, bookmark) = try pickedFolder("sx")
        let settingsA = makeSettings()
        settingsA.burnFolderBookmark = bookmark
        let deviceA = try makeBurns(rips, settings: settingsA)
        let okA = await deviceA.burnStemPart(forSong: "sng_sx", part: "vocals", origin: .buffer)
        XCTAssertTrue(okA)
        XCTAssertEqual(deviceA.temporaryHolds["sng_sx"]?.stemParts, ["vocals"])
        // Device B: its own ledger, the same shared folder, an explicit download right away.
        let indexB = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-holds-indexB-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: indexB) }
        let settingsB = makeSettings()
        settingsB.burnFolderBookmark = bookmark
        let deviceB = BurnStore(rips: rips, fileURL: indexB)
        deviceB.appBurnsDirOverride = FileManager.default.temporaryDirectory.appendingPathComponent("pdj-holds-appB-\(UUID().uuidString)")
        deviceB.settings = settingsB
        let okB = await deviceB.burnStemPart(forSong: "sng_sx", part: "vocals", origin: .explicit("stems"))
        XCTAssertTrue(okB)
        // A's sweep: the part is B's download now.
        let r = deviceA.removeTemporaryAssets(songIds: ["sng_sx"])
        XCTAssertEqual(r.songs, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("stem-sng_sx-vocals.mp3").path),
                      "another device's explicit download is never deleted by this device's sweep")
    }

    /// A hold that records file identities but not THIS file's (never recorded / unreadable) can't
    /// prove the file is ours: released, never deleted.
    func testPickedFolderFileWithNoRecordedIdentityIsReleased() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_ni": .init(key: "rips/sng_ni.mp3", source: "digital", stems: stems("sng_ni"))])
        let (d, bookmark) = try pickedFolder("ni")
        let settings = makeSettings()
        settings.burnFolderBookmark = bookmark
        let burns = try makeBurns(rips, settings: settings)
        _ = await burns.burnStemPart(forSong: "sng_ni", part: "bass", origin: .buffer)
        var h = try XCTUnwrap(burns.temporaryHolds["sng_ni"])
        h.userFolderFiles = ["something-else.mp3": 1]
        burns.injectHoldForTesting(h)
        burns.removeTemporaryAssets(songIds: ["sng_ni"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("stem-sng_ni-bass.mp3").path))
    }

    /// Toggle ON ("Keep buffered files in shared/picked folders"): the old rule — buffer assets in
    /// a picked folder are pinned at creation; app storage still carries holds.
    func testKeepPickedFolderToggleOnPinsAtCreation() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_sh": .init(key: "rips/sng_sh.mp3", source: "digital", stems: stems("sng_sh")),
                          "sng_ap": .init(key: "rips/sng_ap.mp3", source: "digital", stems: stems("sng_ap"))])
        let (d, bookmark) = try pickedFolder("shared")
        let settings = makeSettings()
        settings.npMixKeepPickedFolderBuffers = true
        settings.burnFolderBookmark = bookmark
        let deviceA = try makeBurns(rips, settings: settings)
        let ok = await deviceA.burnStemPart(forSong: "sng_sh", part: "vocals", origin: .buffer)
        XCTAssertTrue(ok)
        XCTAssertNotNil(deviceA.adoptStreamedFile(songId: "sng_sh", title: "S", artist: "A",
                                                  from: try tempFile(), origin: .buffer))
        XCTAssertTrue(deviceA.temporaryHolds.isEmpty, "toggle on ⇒ nothing in a picked folder is temporary")
        XCTAssertFalse(deviceA.isTemporary("sng_sh"))
        await sweepManager(deviceA, settings).sweepTemporary(now: t0 + 500 * hourMs, reason: "test", ignoreExpiry: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("stem-sng_sh-vocals.mp3").path))
        XCTAssertNotNil(deviceA.localURL(forSong: "sng_sh"))
        // App storage is unaffected by the switch.
        settings.burnFolderBookmark = nil
        _ = await deviceA.burnStemPart(forSong: "sng_ap", part: "drums", origin: .buffer)
        XCTAssertNotNil(deviceA.temporaryHolds["sng_ap"], "app storage still carries holds")
    }

    /// The setting round-trips through persistence (nil ⇒ off).
    func testKeepPickedFolderSettingDefaultsOffAndPersists() throws {
        let suite = "test.\(UUID().uuidString)"
        let a = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertNil(a.npMixKeepPickedFolderBuffers)
        a.npMixKeepPickedFolderBuffers = true
        a.persist()
        let b = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(b.npMixKeepPickedFolderBuffers, true)
    }

    /// REVIEW MUST (2026-11-02): a file already sitting at the adoption name with NO ledger row
    /// (a lost / purged ledger, a tvOS orphan, a pre-feature download) was not created by the
    /// buffer lane — it must never become temporary.
    func testBufferAdoptionOverAFileAlreadyOnDiskIsNeverHeld() throws {
        let rips = makeRips()
        rips.setManifest(["sng_or": .init(key: "rips/sng_or.mp3", source: "digital")])
        // Learn the adoption name from a throwaway store sharing the same burns dir.
        let probe = try makeBurns(rips)
        let url = try XCTUnwrap(probe.adoptStreamedFile(songId: "sng_or", title: "O", artist: "A",
                                                        from: try tempFile(), origin: .explicit("probe")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // A fresh ledger (the old one lost) — the file is still there.
        try? FileManager.default.removeItem(at: indexURL)
        let burns = try makeBurns(rips)
        XCTAssertNil(burns.items["sng_or"])
        XCTAssertNotNil(burns.adoptStreamedFile(songId: "sng_or", title: "O", artist: "A",
                                                from: try tempFile(), origin: .buffer))
        XCTAssertNil(burns.temporaryHolds["sng_or"], "a file that was already on the device stays pinned")
    }

    /// REVIEW MUST (2026-11-02): an orphaned analog SIDE (no row references it) that the buffer
    /// lane "shares" must not become a hold — the sweep would delete the only copy.
    func testBufferAdoptionOfAnOrphanedAnalogSideIsNeverHeld() throws {
        let rips = makeRips()
        rips.setManifest(["sng_an1": .init(key: "rips/alb_x.mp3", source: "analog", startMs: 0),
                          "sng_an2": .init(key: "rips/alb_x.mp3", source: "analog", startMs: 60_000)])
        let probe = try makeBurns(rips)
        let side = try XCTUnwrap(probe.adoptStreamedFile(songId: "sng_an1", title: "1", artist: "A",
                                                         from: try tempFile(), origin: .explicit("probe")))
        try? FileManager.default.removeItem(at: indexURL)
        let burns = try makeBurns(rips)
        XCTAssertNotNil(burns.adoptStreamedFile(songId: "sng_an2", title: "2", artist: "A",
                                                from: try tempFile(), origin: .buffer))
        XCTAssertNil(burns.temporaryHolds["sng_an2"])
        burns.removeTemporaryAssets(songIds: ["sng_an2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: side.path), "the orphaned side survives")
    }

    /// REVIEW MUST (2026-11-02): explicit Studio use pins (design §3.3: Studio / Demux / Tracks).
    /// A take resolves its melody stem by song key at every use — buffered stems under it must
    /// become a download, or the sweep breaks the take.
    func testStudioTakeMelodyStemResolutionPinsBufferedStems() throws {
        let burns = try makeBurns(makeRips())
        for p in ["vocals", "drums", "bass", "other"] { try write("stem-sng_tk-\(p).mp3") }
        burns.injectHoldForTesting(hold("sng_tk", parts: ["vocals", "drums", "bass", "other"]))
        let demuxDir = dir.appendingPathComponent("demux", isDirectory: true)
        let demux = DemuxStore(cacheDir: DemuxStore.defaultCacheDir(demuxDir))
        let got = DemuxTakeSwitch.resolveMelodyStem(key: "sng_tk", burns: burns, demux: demux)
        XCTAssertNotNil(got)
        got?.release?()
        XCTAssertNil(burns.temporaryHolds["sng_tk"], "a stem a take is built on is a download")
    }

    // MARK: Pin paths — every explicit Download / Mix action

    func testPinDropsTheHoldAndKeepsTheFiles() throws {
        let burns = try makeBurns(makeRips(), items: [readyItem("sng_q")])
        try write("sng_q.mp3"); try write("stem-sng_q-vocals.mp3")
        burns.injectHoldForTesting(hold("sng_q", audio: true, parts: ["vocals"]))
        XCTAssertEqual(burns.pin(songIds: ["sng_q"], reason: "test"), 1)
        XCTAssertTrue(burns.temporaryHolds.isEmpty)
        XCTAssertTrue(exists("sng_q.mp3")); XCTAssertTrue(exists("stem-sng_q-vocals.mp3"))
        XCTAssertNotNil(burns.items["sng_q"])
        XCTAssertEqual(burns.pin(songIds: ["sng_q", "nope"], reason: "test"), 0, "no hold ⇒ no-op")
    }

    /// Pinning matches by BASE id: an edition variant's hold is pinned by its base row and vice
    /// versa (over-pinning keeps files; under-pinning could delete an explicit download).
    func testPinMatchesEditionVariantsThroughTheBaseId() throws {
        let base = "sng_0123456789ab"
        let burns = try makeBurns(makeRips())
        burns.injectHoldForTesting(hold("\(base)_clean", audio: true))
        burns.injectHoldForTesting(hold(base, parts: ["vocals"]))
        burns.injectHoldForTesting(hold("sng_ffffffffffff", parts: ["vocals"]))
        XCTAssertEqual(burns.pin(songIds: [base], reason: "test"), 2)
        XCTAssertEqual(Array(burns.temporaryHolds.keys), ["sng_ffffffffffff"])
    }

    /// Table-driven over the explicit funnels of §3.3 — each one pins even when the file is
    /// ALREADY on the device (the freshness skip runs after the pin).
    func testEveryExplicitActionPinsEvenWhenTheFileAlreadyExists() async throws {
        let rips = makeRips()
        let ids = ["p_burn", "p_rb", "p_album", "p_when", "p_final", "p_stems", "p_part", "p_adopt", "p_adoptstems"]
        var manifest: [String: RipsStore.ManifestEntry] = [:]
        for id in ids { manifest[id] = .init(key: "rips/\(id).mp3", source: "digital", stems: stems(id)) }
        rips.setManifest(manifest)
        for id in ids {
            try write("\(id).mp3")
            for p in ["vocals", "drums", "bass", "other"] { try write("stem-\(id)-\(p).mp3") }
        }
        let burns = try makeBurns(rips, items: ids.map { readyItem($0) })
        for id in ids { burns.injectHoldForTesting(hold(id, audio: true, parts: ["vocals"])) }

        let cases: [(String, () async -> Void)] = [
            ("p_burn", { _ = await burns.burn([(id: "p_burn", title: "T", artist: "A")]) }),
            ("p_rb", { burns.startRipAndBurn(songId: "p_rb", title: "T", artist: "A", appleMusicId: nil, lengthMs: nil) }),
            ("p_album", { burns.startRipAndBurnAlbum([.init(id: "p_album", title: "T", artist: "A", appleMusicId: nil, lengthMs: nil)]) }),
            ("p_when", { burns.burnWhenRipped(songId: "p_when", title: "T", artist: "A") }),
            ("p_final", {
                burns.finalizeBurn(record: .init(
                    taskIdentifier: 0, songId: "p_final", kind: .burn, audioFileName: "p_final.mp3",
                    sidecarFileName: "p_final.txt", sidecarText: "", wasAppStorage: true,
                    burnFolderBookmark: nil, expectedBytes: nil, manifestKey: "rips/p_final.mp3",
                    source: "digital", bpm: nil, musicalKey: nil, camelot: nil, durationMs: nil,
                    startMs: nil, rippedAt: nil, title: "T", artist: "A", createdAt: 0), bytes: 10)
            }),
            ("p_stems", { _ = await burns.burnStems(forSong: "p_stems") }),
            ("p_part", { _ = await burns.burnStemPart(forSong: "p_part", part: "vocals") }),
            ("p_adopt", { _ = burns.adoptStreamedFile(songId: "p_adopt", title: "T", artist: "A", from: URL(fileURLWithPath: "/nonexistent")) }),
            ("p_adoptstems", { _ = burns.adoptStreamedStems(songId: "p_adoptstems", files: [:]) }),
        ]
        for (id, action) in cases {
            XCTAssertNotNil(burns.temporaryHolds[id], "precondition \(id)")
            await action()
            XCTAssertNil(burns.temporaryHolds[id], "\(id): an explicit action must pin")
            XCTAssertTrue(exists("\(id).mp3"), "\(id): pinning keeps the file")
        }
    }

    /// The Now Playing stems toggle is a control touch, not an explicit download: it neither pins
    /// a buffered song nor makes anything temporary.
    func testIncidentalStemsNeitherPinNorHold() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_i": .init(key: "rips/sng_i.mp3", source: "digital", stems: stems("sng_i"))])
        let burns = try makeBurns(rips)
        burns.injectHoldForTesting(hold("sng_i", parts: ["vocals"]))
        try write("stem-sng_i-vocals.mp3")
        _ = await burns.burnStems(forSong: "sng_i", origin: .incidental)
        let h = try XCTUnwrap(burns.temporaryHolds["sng_i"], "no pin")
        XCTAssertEqual(h.stemParts, ["vocals"], "the newly fetched parts are NOT added to the hold")
        XCTAssertTrue(exists("stem-sng_i-drums.mp3"))
    }

    func testMixDeckLoadPinsTheSong() throws {
        let burns = try MixBurnFixture.burnStore(ids: ["d1"])
        burns.injectHoldForTesting(hold("d1", audio: true))
        let engine = MixEngine(burns: burns)
        engine.load(songId: "d1", title: "T", artist: "A", bpm: 120, camelot: nil, key: nil,
                    albumId: nil, on: .a)
        XCTAssertNil(burns.temporaryHolds["d1"], "loading onto a deck is an explicit Mix action")
    }

    func testMixDownloadLanePinsSongsAlreadyOnDisk() throws {
        let rips = makeRips()
        let burns = try MixBurnFixture.burnStore(ids: ["m1", "m2"], rips: rips)
        burns.injectHoldForTesting(hold("m1", audio: true))
        burns.injectHoldForTesting(hold("other", audio: true))
        let engine = MixEngine(burns: burns)
        let d = CollectionMixDownloader(engine: engine, burns: burns, rips: rips, transfers: nil)
        d.resolveRipIds = { _ in ["m1", "m2"] }
        d.resolveLoadables = { _ in [] }
        d.songLengthSeconds = { _ in nil }
        d.songTitleArtist = { (title: $0, artist: "A") }
        d.declaredMemberCount = { _ in 2 }
        d.catalogSongCount = { 100 }
        d.begin(sources: [.pocket("crate")])
        XCTAssertNil(burns.temporaryHolds["m1"], "the Mix download lane pins what it counts as downloaded")
        XCTAssertNotNil(burns.temporaryHolds["other"], "songs outside the crate keep their hold")
        d.cancel()
    }

    // MARK: Streams — explicit wins

    private func makeLoader(_ rips: RipsStore, _ burns: BurnStore) -> MixStreamLoader {
        let sdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-holds-ms-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sdir) }
        return MixStreamLoader(rips: rips, burns: burns, directory: sdir)
    }

    func testBufferStreamAdoptsAsTemporary() throws {
        let rips = makeRips()
        rips.setManifest(["sng_bs": .init(key: "rips/sng_bs.mp3", source: "digital")])
        let burns = try makeBurns(rips)
        let loader = makeLoader(rips, burns)
        let f = try tempFile(bytes: 40)
        loader.injectStreamForTesting(songId: "sng_bs", file: f, bytes: 40, expected: 40,
                                      adoptable: true, finished: true, origin: .buffer)
        XCTAssertTrue(burns.isTemporary("sng_bs"))
    }

    /// A Mix deck joining a LIVE buffer stream upgrades it: the adoption is a pinned download.
    func testExplicitJoinUpgradesABufferStream() throws {
        let rips = makeRips()
        rips.setManifest(["sng_j": .init(key: "rips/sng_j.mp3", source: "digital")])
        let burns = try makeBurns(rips)
        let loader = makeLoader(rips, burns)
        let f = try tempFile(bytes: 40)
        loader.injectStreamForTesting(songId: "sng_j", file: f, bytes: 10, expected: 40,
                                      adoptable: true, origin: .buffer)
        XCTAssertNotNil(loader.open("sng_j", title: "J", artist: "A"), "joins the live stream")
        loader.injectStreamForTesting(songId: "sng_j", file: f, bytes: 40, expected: 40,
                                      adoptable: true, finished: true)
        XCTAssertNotNil(burns.items["sng_j"])
        XCTAssertFalse(burns.isTemporary("sng_j"), "explicit wins")
        XCTAssertTrue(burns.temporaryHolds.isEmpty)
    }

    /// A buffer opener joining an EXPLICIT stream never downgrades it.
    func testBufferJoinNeverDowngradesAnExplicitStream() throws {
        let rips = makeRips()
        rips.setManifest(["sng_d": .init(key: "rips/sng_d.mp3", source: "digital")])
        let burns = try makeBurns(rips)
        let loader = makeLoader(rips, burns)
        let f = try tempFile(bytes: 40)
        loader.injectStreamForTesting(songId: "sng_d", file: f, bytes: 10, expected: 40, adoptable: true)
        _ = loader.open("sng_d", title: "D", artist: "A", origin: .buffer)
        loader.injectStreamForTesting(songId: "sng_d", file: f, bytes: 40, expected: 40,
                                      adoptable: true, finished: true)
        XCTAssertTrue(burns.temporaryHolds.isEmpty)
    }

    /// An explicit open of a FINISHED, adopted buffer stream pins its burn.
    func testExplicitOpenOfAFinishedBufferStreamPins() throws {
        let rips = makeRips()
        rips.setManifest(["sng_f": .init(key: "rips/sng_f.mp3", source: "digital")])
        let burns = try makeBurns(rips)
        let loader = makeLoader(rips, burns)
        loader.injectStreamForTesting(songId: "sng_f", file: try tempFile(bytes: 40), bytes: 40,
                                      expected: 40, adoptable: true, finished: true, origin: .buffer)
        XCTAssertTrue(burns.isTemporary("sng_f"))
        XCTAssertNotNil(loader.open("sng_f", title: "F", artist: "A"))
        XCTAssertFalse(burns.isTemporary("sng_f"))
    }

    // MARK: Explicit deletes leave no dangling holds

    func testDeletingADownloadForgetsItsHold() throws {
        let burns = try makeBurns(makeRips(), items: [readyItem("sng_del")])
        try write("sng_del.mp3")
        burns.injectHoldForTesting(hold("sng_del", audio: true, parts: ["vocals"]))
        burns.removeBurns(songIds: ["sng_del"])
        XCTAssertNil(burns.temporaryHolds["sng_del"])
    }

    func testDeletingStemsForgetsTheHeldParts() throws {
        let burns = try makeBurns(makeRips(), items: [readyItem("sng_st")])
        burns.injectHoldForTesting(hold("sng_st", audio: true, parts: ["vocals"]))
        burns.injectHoldForTesting(hold("sng_st2", parts: ["drums"]))
        burns.removeStems(forSongs: ["sng_st", "sng_st2"])
        XCTAssertEqual(burns.temporaryHolds["sng_st"]?.stemParts, [], "the audio stays held")
        XCTAssertEqual(burns.temporaryHolds["sng_st"]?.audio, true)
        XCTAssertNil(burns.temporaryHolds["sng_st2"], "a stems-only hold goes entirely")
    }

    // MARK: Stem Lock prefetch is TEMPORARY (Q5 = yes)

    func testStemLockPrefetchedPartsAreTemporary() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_sl": .init(key: "rips/sng_sl.mp3", source: "digital", stems: stems("sng_sl"))])
        let burns = try makeBurns(rips)
        let loader = makeLoader(rips, burns)
        let lane = StemLockPrefetcher.live(streamer: loader, burns: burns, rips: rips, isCatalogOwner: { false })
        let ok = await lane.fetchStemPart("sng_sl", "vocals")
        XCTAssertTrue(ok)
        XCTAssertEqual(burns.temporaryHolds["sng_sl"]?.stemParts, ["vocals"],
                       "a Stem Lock prefetch is speculative ⇒ temporary")
    }

    func testStemLockPrefetchOfAPinnedSongsMissingPartHoldsOnlyThatPart() async throws {
        let rips = makeRips()
        rips.setManifest(["sng_pp": .init(key: "rips/sng_pp.mp3", source: "digital", stems: stems("sng_pp"))])
        try write("sng_pp.mp3")
        let burns = try makeBurns(rips, items: [readyItem("sng_pp")])
        let lane = StemLockPrefetcher.live(streamer: makeLoader(rips, burns), burns: burns, rips: rips,
                                           isCatalogOwner: { false })
        _ = await lane.fetchStemPart("sng_pp", "bass")
        let h = try XCTUnwrap(burns.temporaryHolds["sng_pp"])
        XCTAssertFalse(h.audio, "the pinned audio is never claimed by the hold")
        XCTAssertEqual(h.stemParts, ["bass"])
    }
}

/// HTTP 200 + a fixed body; `onRequest` runs BEFORE the response (the mid-download race seam).
final class HoldStubURLProtocol: URLProtocol {
    static var body = Data()
    static var onRequest: ((URL) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.onRequest?(request.url!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
