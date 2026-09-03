import XCTest
@testable import PocketDJ

/// Storage manager — BurnStore's bulk delete + usage surface. All tests run against a
/// HERMETIC app-burns root (`appBurnsDirOverride`) so they can never touch this machine's
/// real burned files. Items are seeded by writing the store's own Document JSON (the
/// decode-on-init path), and the on-disk files are created with exact byte sizes.
///
/// Everything here deletes DOWNLOADED media only — there is deliberately no catalog or
/// collections involvement to test, because the API never touches them.
@MainActor
final class BurnStoreStorageTests: XCTestCase {

    private var dir: URL!            // the hermetic app-burns root
    private var indexURL: URL!       // the store's ledger json

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-storage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-storage-index-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: indexURL)
        super.tearDown()
    }

    // MARK: Fixtures

    private func item(_ id: String, artist: String = "Artist", audio: String,
                      bytes: Int, source: String = "digital", downloadedAt: Double = 0,
                      state: BurnStore.State = .ready, cut: String? = nil) -> BurnStore.BurnItem {
        BurnStore.BurnItem(songId: id, title: "T-\(id)", artist: artist,
                           audioFileName: audio, sidecarFileName: "\(id).txt",
                           source: source, bpm: nil, musicalKey: nil, camelot: nil,
                           durationMs: nil, startMs: nil, bytes: bytes, rippedAt: nil,
                           downloadedAt: downloadedAt, state: state, error: nil,
                           wasAppStorage: true, cutFileName: cut, cutDownloadedAt: nil)
    }

    /// Seed the ledger + matching files: audio files get their recorded byte size, every
    /// item gets a 1-byte sidecar.
    private func makeStore(_ items: [BurnStore.BurnItem]) throws -> BurnStore {
        let doc = BurnStore.Document(items: items)
        try JSONEncoder().encode(doc).write(to: indexURL)
        var written = Set<String>()
        for it in items where it.state == .ready {
            if !it.audioFileName.isEmpty && written.insert(it.audioFileName).inserted {
                try Data(repeating: 0, count: it.bytes).write(to: dir.appendingPathComponent(it.audioFileName))
            }
            if !it.sidecarFileName.isEmpty {
                try Data([0x1]).write(to: dir.appendingPathComponent(it.sidecarFileName))
            }
        }
        let store = BurnStore(rips: RipsStore(), fileURL: indexURL)
        store.appBurnsDirOverride = dir
        return store
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private func write(_ name: String, bytes: Int) throws {
        try Data(repeating: 0, count: bytes).write(to: dir.appendingPathComponent(name))
    }

    // MARK: removeBurns

    func testRemoveBurnsDeletesFilesAndLedgerAndPersists() throws {
        let store = try makeStore([
            item("s1", audio: "a-s1.mp3", bytes: 10),
            item("s2", audio: "a-s2.mp3", bytes: 20),
        ])
        store.removeBurns(songIds: ["s1"])
        XCTAssertFalse(exists("a-s1.mp3"))
        XCTAssertFalse(exists("s1.txt"))
        XCTAssertTrue(exists("a-s2.mp3"))
        XCTAssertNil(store.items["s1"])
        XCTAssertNotNil(store.items["s2"])
        // Persisted: a reloaded store only knows s2.
        let reloaded = BurnStore(rips: RipsStore(), fileURL: indexURL)
        XCTAssertNil(reloaded.items["s1"])
        XCTAssertNotNil(reloaded.items["s2"])
    }

    /// The analog whole-album mp3 is SHARED across the album's songs — it must survive
    /// while any surviving item still references it, and go when the last one does.
    func testRemoveBurnsKeepsSharedAnalogAlbumUntilLastSongGoes() throws {
        let store = try makeStore([
            item("s1", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s2", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
        ])
        store.removeBurns(songIds: ["s1"])
        XCTAssertTrue(exists("album-alb1.mp3"), "shared album file must survive s2")
        store.removeBurns(songIds: ["s2"])
        XCTAssertFalse(exists("album-alb1.mp3"), "last reference gone → file deleted")
    }

    /// A batch containing BOTH songs of a shared album deletes the album file in one call.
    func testRemoveBurnsBatchDeletesSharedAlbumWhenWholeGroupGoes() throws {
        let store = try makeStore([
            item("s1", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s2", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
        ])
        store.removeBurns(songIds: ["s1", "s2"])
        XCTAssertFalse(exists("album-alb1.mp3"))
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: Stem usage + cleanup (MISC1)

    func testStemUsageAndPerSongRemovalLeavesBeatGridsAndAudio() throws {
        let store = try makeStore([
            item("s1", artist: "Alpha", audio: "a-s1.mp3", bytes: 10),
            item("s2", artist: "Beta",  audio: "a-s2.mp3", bytes: 20),
        ])
        // s1 gets 4 stems (5 bytes each) + a beat grid; s2 has none.
        for part in ["vocals", "drums", "bass", "other"] { try write("stem-s1-\(part).mp3", bytes: 5) }
        try write("analysis-s1.json", bytes: 7)   // beat grid — must NOT count as a stem, must survive

        XCTAssertEqual(store.stemUsageBytes(), 20, "4 stems × 5 bytes; beat grid + audio excluded")
        let byArtist = store.stemUsageByArtist()
        XCTAssertEqual(byArtist.map(\.artist), ["Alpha"], "only the artist with stems is listed")
        XCTAssertEqual(byArtist.first?.bytes, 20)
        XCTAssertEqual(byArtist.first?.songIds, ["s1"])

        // Per-song stem removal: the 4 stems go; the beat grid and burned audio stay.
        store.removeStems(forSongs: ["s1"])
        XCTAssertFalse(exists("stem-s1-vocals.mp3"))
        XCTAssertFalse(exists("stem-s1-other.mp3"))
        XCTAssertTrue(exists("analysis-s1.json"), "beat grid must survive stem removal")
        XCTAssertTrue(exists("a-s1.mp3"), "burned audio must survive stem removal")
        XCTAssertEqual(store.stemUsageBytes(), 0)
    }

    func testRemoveAllStemsLeavesBeatGridsAndAudio() throws {
        let store = try makeStore([ item("s1", audio: "a-s1.mp3", bytes: 10) ])
        for part in ["vocals", "drums", "bass", "other"] { try write("stem-s1-\(part).mp3", bytes: 3) }
        try write("analysis-s1.json", bytes: 7)
        XCTAssertEqual(store.stemUsageBytes(), 12)
        store.removeAllStems()
        XCTAssertEqual(store.stemUsageBytes(), 0)
        XCTAssertTrue(exists("analysis-s1.json"), "removeAllStems must NOT touch beat grids")
        XCTAssertTrue(exists("a-s1.mp3"), "removeAllStems must NOT touch burned audio")
    }

    func testRemoveAllStemsRespectsProtecting() throws {
        let store = try makeStore([ item("s1", audio: "a-s1.mp3", bytes: 10) ])
        for part in ["vocals", "drums"] { try write("stem-s1-\(part).mp3", bytes: 3) }
        store.removeAllStems(protecting: ["s1"])
        XCTAssertTrue(exists("stem-s1-vocals.mp3"), "a protected (in-use) song's stems are kept")
        XCTAssertEqual(store.stemUsageBytes(), 6)
    }

    func testRemoveBurnsDeletesCutStemsAndBeatgrid() throws {
        let store = try makeStore([
            item("s1", audio: "album-alb1.mp3", bytes: 50, source: "analog", cut: "cut-s1.mp3"),
        ])
        try write("cut-s1.mp3", bytes: 5)
        for part in ["vocals", "drums", "bass", "other"] { try write("stem-s1-\(part).mp3", bytes: 3) }
        try write("analysis-s1.json", bytes: 2)
        store.removeBurns(songIds: ["s1"])
        XCTAssertFalse(exists("cut-s1.mp3"))
        XCTAssertFalse(exists("stem-s1-vocals.mp3"))
        XCTAssertFalse(exists("stem-s1-other.mp3"))
        XCTAssertFalse(exists("analysis-s1.json"))
    }

    // MARK: removeAllBurns

    func testRemoveAllBurnsSweepsUntrackedAuxButKeepsForeignFiles() throws {
        let store = try makeStore([item("s1", audio: "a-s1.mp3", bytes: 10)])
        try write("stem-zzz-vocals.mp3", bytes: 4)   // stems for a song NOT in the ledger
        try write("analysis-zzz.json", bytes: 4)
        try write("keep-me.pdf", bytes: 9)           // a user file in a user-picked folder
        store.removeAllBurns()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(exists("a-s1.mp3"))
        XCTAssertFalse(exists("stem-zzz-vocals.mp3"))
        XCTAssertFalse(exists("analysis-zzz.json"))
        XCTAssertTrue(exists("keep-me.pdf"), "never delete files this app didn't write")
    }

    /// An item recorded as living in the USER folder whose bookmark doesn't resolve
    /// (unplugged drive / no folder configured) must be SKIPPED — dropping its ledger
    /// entry without deleting its files would orphan them forever.
    func testRemoveBurnsKeepsUnreachableUserFolderItems() throws {
        var it = item("s1", audio: "a-s1.mp3", bytes: 10)
        it.wasAppStorage = false          // written to a user folder…
        let store = try makeStore([it])   // …but no bookmark is configured now
        store.removeBurns(songIds: ["s1"])
        XCTAssertNotNil(store.items["s1"], "unreachable item keeps its ledger entry")
        store.removeAllBurns()
        XCTAssertNotNil(store.items["s1"], "delete-all skips it too — no silent orphaning")
    }

    /// In a USER-PICKED folder, only exact-shaped aux names whose songId the app KNOWS
    /// are counted/swept — the user's own coincidentally-named files are never touched.
    func testUserFolderAuxOwnershipProtectsForeignFiles() throws {
        let store = try makeStore([item("s1", audio: "a-s1.mp3", bytes: 10)])
        // A separate USER folder with a resolvable bookmark.
        let user = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-userburns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: user) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.burnFolderBookmark = try XCTUnwrap(BurnStore.makeBookmark(for: user))
        store.settings = settings

        func writeUser(_ name: String, bytes: Int) throws {
            try Data(repeating: 0, count: bytes).write(to: user.appendingPathComponent(name))
        }
        try writeUser("stem-loop.mp3", bytes: 11)          // user's file: "loop" is no stem part
        try writeUser("analysis-2026.json", bytes: 13)     // user's file: id unknown to the app
        try writeUser("stem-s1-vocals.mp3", bytes: 7)      // ours: ledger-known id + real part

        let before = store.burnedUsageBytes()
        XCTAssertEqual(before, 10 + 1 + 7, "user files never counted (audio+sidecar+our stem)")

        store.removeAllBurns()
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent("stem-loop.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent("analysis-2026.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent("stem-s1-vocals.mp3").path))
    }

    func testAuxFileSongIdParsesOnlyExactShapes() {
        XCTAssertEqual(BurnStore.auxFileSongId("stem-abc-vocals.mp3"), "abc")
        XCTAssertEqual(BurnStore.auxFileSongId("stem-a-b-drums.mp3"), "a-b")
        XCTAssertEqual(BurnStore.auxFileSongId("analysis-abc.json"), "abc")
        XCTAssertNil(BurnStore.auxFileSongId("stem-loop.mp3"), "no valid part suffix")
        XCTAssertNil(BurnStore.auxFileSongId("stem--vocals.mp3"), "empty id")
        XCTAssertNil(BurnStore.auxFileSongId("analysis-.json"), "empty id")
        XCTAssertNil(BurnStore.auxFileSongId("music.mp3"))
    }

    // MARK: Usage measurement

    func testBurnedUsageBytesCountsOnlyOurFiles() throws {
        let store = try makeStore([item("s1", audio: "a-s1.mp3", bytes: 10)])   // + 1-byte sidecar
        try write("stem-s1-vocals.mp3", bytes: 7)
        try write("analysis-s1.json", bytes: 3)
        try write("unrelated.bin", bytes: 100)
        XCTAssertEqual(store.burnedUsageBytes(), 10 + 1 + 7 + 3)
    }

    func testUsageByArtistGroupsAndCountsSharedAudioOnce() throws {
        let store = try makeStore([
            item("s1", artist: "Beta", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s2", artist: "Beta", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s3", artist: "Alpha", audio: "a-s3.mp3", bytes: 30),
            item("s4", artist: "Alpha", audio: "a-s4.mp3", bytes: 40, state: .error),   // not ready → excluded
        ])
        let rows = store.usageByArtist()
        XCTAssertEqual(rows.map(\.artist), ["Alpha", "Beta"])   // sorted
        XCTAssertEqual(rows[0].songIds, ["s3"])
        XCTAssertEqual(rows[0].bytes, 30)
        XCTAssertEqual(rows[1].songIds, ["s1", "s2"])
        XCTAssertEqual(rows[1].bytes, 100, "shared album mp3 counted once, not per song")
    }

    func testReadyBurnedIdsAndApproximateBytes() throws {
        let store = try makeStore([
            item("s1", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s2", audio: "album-alb1.mp3", bytes: 100, source: "analog"),
            item("s3", audio: "a-s3.mp3", bytes: 30, state: .error),
        ])
        XCTAssertEqual(store.readyBurnedIds(in: ["s1", "s2", "s3", "nope"]).sorted(), ["s1", "s2"])
        XCTAssertEqual(store.approximateBytes(forSongs: ["s1", "s2"]), 100)
    }

    // MARK: Ledger location (task #53 — tvOS ledger lives WITH the media, in Caches)

    func testDefaultURLFollowsThePlatformStorageHome() {
        let caches = BurnStore.defaultURL(preferCaches: true)
        XCTAssertTrue(caches.path.contains("/Caches/"), "tvOS ledger home is Caches: \(caches.path)")
        XCTAssertEqual(caches.lastPathComponent, "pocketdj-burns.json")
        let support = BurnStore.defaultURL(preferCaches: false)
        XCTAssertTrue(support.path.contains("/Application Support/"),
                      "everywhere else the ledger stays in App Support: \(support.path)")
        XCTAssertEqual(support.lastPathComponent, "pocketdj-burns.json")
    }

    func testLegacyLedgerURLExistsOnlyWhereTheHomeMoved() {
        XCTAssertNil(BurnStore.legacyLedgerURL(preferCaches: false),
                     "no migration source where the location didn't change")
        let legacy = BurnStore.legacyLedgerURL(preferCaches: true)
        XCTAssertTrue(legacy?.path.contains("/Application Support/") == true)
        XCTAssertEqual(legacy?.lastPathComponent, "pocketdj-burns.json")
    }

    func testLegacyLedgerMigratesOnceToTheNewHome() throws {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-legacy-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: legacyURL) }
        let doc = BurnStore.Document(items: [item("s1", audio: "a-s1.mp3", bytes: 10)])
        try JSONEncoder().encode(doc).write(to: legacyURL)

        // Nothing at the NEW path + a legacy ledger => adopt it and re-persist at the new home.
        let store = BurnStore(rips: RipsStore(), fileURL: indexURL, legacyFileURL: legacyURL)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNotNil(store.items["s1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path),
                      "the migrated ledger is re-persisted at the NEW home immediately")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path),
                      "read-only migration — a rollback build still finds its ledger")

        // A ledger at the new path WINS — legacy is only ever a fallback.
        let doc2 = BurnStore.Document(items: [item("s2", audio: "a-s2.mp3", bytes: 20)])
        try JSONEncoder().encode(doc2).write(to: indexURL)
        let store2 = BurnStore(rips: RipsStore(), fileURL: indexURL, legacyFileURL: legacyURL)
        XCTAssertNotNil(store2.items["s2"])
        XCTAssertNil(store2.items["s1"], "legacy must not merge over a live ledger")
    }

    // MARK: Orphan ADOPTION (task #53 — rebuild the ledger from burned files on disk)

    /// A REAL digital burn's on-disk pair (sidecar built by `buildSidecar` itself, so the
    /// round-trip is against exactly what the burn path writes), no ledger => the scan
    /// rebuilds the entry: id from the filename suffix, title/artist from the sidecar's
    /// first line, bpm/key/camelot from its Raw JSON manifestEntry.
    func testAdoptionRebuildsADigitalBurnFromItsSidecar() throws {
        let entry = RipsStore.ManifestEntry(key: "rips/sng_abc.mp3", source: "digital",
                                            durationMs: 200_000, bpm: 120.5,
                                            musicalKey: "A min", camelot: "8A")
        let sidecar = BurnStore.buildSidecar(
            songId: "sng_abc",
            fallback: (id: "sng_abc", title: "The Song", artist: "The Artist"),
            song: nil, album: nil, entry: entry)
        try Data(sidecar.utf8).write(to: dir.appendingPathComponent("The Artist-The Song-sng_abc.txt"))
        try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent("The Artist-The Song-sng_abc.mp3"))

        let store = BurnStore(rips: RipsStore(), fileURL: indexURL)   // ledger file absent
        store.appBurnsDirOverride = dir
        XCTAssertEqual(store.adoptOrphanedBurns(), 1)
        let it = try XCTUnwrap(store.items["sng_abc"])
        XCTAssertEqual(it.title, "The Song")
        XCTAssertEqual(it.artist, "The Artist")
        XCTAssertEqual(it.audioFileName, "The Artist-The Song-sng_abc.mp3")
        XCTAssertEqual(it.sidecarFileName, "The Artist-The Song-sng_abc.txt")
        XCTAssertEqual(it.state, .ready)
        XCTAssertEqual(it.bytes, 10)
        XCTAssertEqual(it.source, "digital")
        XCTAssertEqual(it.bpm, 120.5)
        XCTAssertEqual(it.camelot, "8A")
        XCTAssertEqual(it.durationMs, 200_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path),
                      "an adoption persists the rebuilt ledger")
        // The adopted item counts like any other burn (usage sees it).
        XCTAssertEqual(store.burnedUsageBytes(), 10 + sidecar.utf8.count)
    }

    /// ANALOG: the playback source is the SHARED album file (via the manifest key's
    /// basename) with the seek offset from the Raw JSON — the per-song cut (which carries
    /// the same `-<songId>` suffix a digital file would) is recorded as the CUT, never
    /// adopted as the audio.
    func testAdoptionRecoversAnalogViaTheSharedAlbumFileNotTheCut() throws {
        let entry = RipsStore.ManifestEntry(key: "rips/alb_9.mp3", source: "analog",
                                            startMs: 62_000, durationMs: 180_000)
        let sidecar = BurnStore.buildSidecar(
            songId: "sng_a1",
            fallback: (id: "sng_a1", title: "Side A Cut", artist: "Vinyl Artist"),
            song: nil, album: nil, entry: entry)
        try Data(sidecar.utf8).write(to: dir.appendingPathComponent("Vinyl Artist-Side A Cut-sng_a1.txt"))
        try Data(repeating: 0, count: 30).write(to: dir.appendingPathComponent("Vinyl Artist-Album-1975-alb_9.mp3"))
        try Data(repeating: 0, count: 12).write(to: dir.appendingPathComponent("Vinyl Artist-Side A Cut-sng_a1.mp3"))

        let store = BurnStore(rips: RipsStore(), fileURL: indexURL)
        store.appBurnsDirOverride = dir
        XCTAssertEqual(store.adoptOrphanedBurns(), 1)
        let it = try XCTUnwrap(store.items["sng_a1"])
        XCTAssertEqual(it.source, "analog")
        XCTAssertEqual(it.audioFileName, "Vinyl Artist-Album-1975-alb_9.mp3",
                       "the shared album file is the playback source")
        XCTAssertEqual(it.startMs, 62_000, "the analog seek offset survives via the Raw JSON")
        XCTAssertEqual(it.cutFileName, "Vinyl Artist-Side A Cut-sng_a1.mp3",
                       "the per-song cut is filed as the cut, not the audio")
        XCTAssertEqual(it.bytes, 30)
    }

    /// Old/seeded naming (`<songId>.mp3` + `<songId>.txt`, no descriptive prefix) adopts
    /// too — the whole basename IS the id, and a header-only sidecar still yields
    /// title/artist from its first line.
    func testAdoptionHandlesBareSuffixNamesAndHeaderOnlySidecars() throws {
        try Data("Old Artist \u{2014} Old Song\n".utf8).write(to: dir.appendingPathComponent("sng_old.txt"))
        try Data(repeating: 0, count: 7).write(to: dir.appendingPathComponent("sng_old.mp3"))
        let store = BurnStore(rips: RipsStore(), fileURL: indexURL)
        store.appBurnsDirOverride = dir
        XCTAssertEqual(store.adoptOrphanedBurns(), 1)
        let it = try XCTUnwrap(store.items["sng_old"])
        XCTAssertEqual(it.artist, "Old Artist")
        XCTAssertEqual(it.title, "Old Song")
        XCTAssertEqual(it.audioFileName, "sng_old.mp3")
    }

    /// Safety rails: a ledgered song is NEVER overwritten by adoption, a sidecar with no
    /// locatable audio adopts nothing (conservative — the song just re-burns), and a
    /// healthy store's scan is a no-op.
    func testAdoptionNeverOverwritesAndSkipsAudiolessSidecars() throws {
        let store = try makeStore([item("s1", audio: "a-s1.mp3", bytes: 10)])
        // Orphan sidecar with NO audio anywhere on disk.
        try Data("Ghost \u{2014} Ghost\n".utf8).write(to: dir.appendingPathComponent("Ghost-Ghost-sng_ghost.txt"))
        // A rogue sidecar for the ALREADY-LEDGERED song under a different name.
        try Data("Impostor \u{2014} Impostor\n".utf8).write(to: dir.appendingPathComponent("Impostor-s1.txt"))
        XCTAssertEqual(store.adoptOrphanedBurns(), 0)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items["s1"]?.title, "T-s1", "the ledgered record is untouched")
        XCTAssertNil(store.items["sng_ghost"])
    }
}
