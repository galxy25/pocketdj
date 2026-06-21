import XCTest
import ZIPFoundation
@testable import PocketDJ

/// Tests for the full backup `.pocketdj.zip` (the shared-subset native owns):
/// export→import round-trip (collections + edits survive, ids reminted), the PWA's
/// schemaVersion 1|2 tolerance, and that a backup omitting items/art still imports.
final class BackupZipTests: XCTestCase {

    // MARK: Export → import round-trip (collections + edits survive, ids reminted)

    @MainActor
    func testFullBackupRoundTrip() async throws {
        let app = AppModel(loader: TestData.StubLoader())
        await app.loadIfNeeded()
        let s = makeStore()
        s.app = app
        let pocket = s.createPocket("Warmups")
        s.addSong("sng_1", toPocket: pocket.id)
        let pl = s.createPlaylist("Night Set", songIds: ["sng_1", "sng_2"])
        s.addPocketRef(pocket.id, toPlaylist: pl.id)
        _ = s.realize(playlistId: pl.id, seed: "fixed")   // a frozen setlist

        var albumEdit = AlbumEdit(); albumEdit.year = 1999
        let edits = makeEdits()
        edits.setAlbum("alb_42", albumEdit)

        let sources = [SourceConfig(name: "My Vinyl", urlString: "https://example/index.json")]

        // EXPORT
        let zipData = try BackupZip.export(sources: sources, pockets: s.pockets,
                                           playlists: s.playlists, setlists: s.setlists,
                                           editsData: try edits.exportData())

        // Manifest is PWA-shaped + native-flagged.
        let man = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(entry("manifest.json", in: zipData))) as? [String: Any])
        XCTAssertEqual(man["app"] as? String, "pocketdj")
        XCTAssertEqual(man["kind"] as? String, "backup")
        XCTAssertEqual(man["schemaVersion"] as? Int, 2)
        XCTAssertEqual(man["portable"] as? Bool, false)
        let counts = try XCTUnwrap(man["counts"] as? [String: Any])
        XCTAssertEqual(counts["items"] as? Int, 0)        // client-only: catalog omitted
        XCTAssertEqual(counts["art"] as? Int, 0)
        XCTAssertEqual(counts["pockets"] as? Int, 1)
        XCTAssertEqual(counts["playlists"] as? Int, 1)
        // Native does NOT bundle the catalog.
        XCTAssertNil(entry("items.json", in: zipData))

        // IMPORT into a FRESH store + edits.
        let s2 = makeStore()
        let edits2 = makeEdits()
        let (payload, skipped) = try BackupZip.import(data: zipData)
        let added = s2.mergeBackupCollections(pockets: payload.pockets, playlists: payload.playlists,
                                              setlists: payload.setlists)
        try edits2.importData(try XCTUnwrap(payload.editsData))

        // Collections survived…
        XCTAssertEqual(added.pockets, 1)
        XCTAssertEqual(added.playlists, 1)
        XCTAssertEqual(added.setlists, 1)
        XCTAssertEqual(s2.pockets.first?.name, "Warmups")
        XCTAssertEqual(s2.playlists.first?.name, "Night Set")
        // …with reminted ids (disjoint from the source store).
        XCTAssertNotEqual(s2.pockets.first?.id, pocket.id)
        XCTAssertNotEqual(s2.playlists.first?.id, pl.id)
        // Setlist re-pointed at the reminted playlist.
        XCTAssertEqual(s2.setlists.first?.playlistId, s2.playlists.first?.id)
        // Playlist's pocket node remapped to the reminted pocket.
        let pocketNode = s2.playlists.first?.sequences.flatMap { $0.children ?? [] }.first { $0.kind == .pocket }
        XCTAssertEqual(pocketNode?.pocketId, s2.pockets.first?.id)
        // Edits survived.
        XCTAssertEqual(edits2.albumEdit("alb_42")?.year, 1999)
        // Sources travel.
        XCTAssertEqual(payload.sources.first?.name, "My Vinyl")
        // Nothing skipped (no catalog in a native backup).
        XCTAssertEqual(skipped.items, 0)
        XCTAssertEqual(skipped.art, 0)
    }

    // MARK: A backup omitting items/art still imports (and reports skips when present)

    func testImportToleratesMissingItemsAndArt() throws {
        // Bare backup: only collections + a manifest, no items.json / art.
        let data = try makeZip([
            "manifest.json": Data(#"{"app":"pocketdj","kind":"backup","schemaVersion":2,"counts":{}}"#.utf8),
            "pockets.json": Data("[]".utf8),
            "playlists.json": Data("[]".utf8),
        ])
        let (payload, skipped) = try BackupZip.import(data: data)
        XCTAssertTrue(payload.pockets.isEmpty)
        XCTAssertEqual(skipped.items, 0)
        XCTAssertEqual(skipped.art, 0)
    }

    func testImportReportsSkippedCatalog() throws {
        // A PWA-style portable backup that bundles items + an art entry: native skips
        // them but counts them.
        let items = #"[{"id":"sng_1"},{"id":"sng_2"}]"#
        let data = try makeZip([
            "manifest.json": Data(#"{"app":"pocketdj","schemaVersion":2,"counts":{}}"#.utf8),
            "items.json": Data(items.utf8),
            "art/alb_1.webp": Data([0x00, 0x01, 0x02]),
            "pockets.json": Data("[]".utf8),
        ])
        let (_, skipped) = try BackupZip.import(data: data)
        XCTAssertEqual(skipped.items, 2)
        XCTAssertEqual(skipped.art, 1)
    }

    // MARK: PWA schemaVersion 1|2 tolerance + missing-kind backup

    func testImportToleratesV1NoCollections() throws {
        // A v1 PWA backup: sources + items only, no pockets/playlists, no `kind`.
        let data = try makeZip([
            "manifest.json": Data(#"{"app":"pocketdj","schemaVersion":1,"counts":{"sources":1,"items":3,"art":0}}"#.utf8),
            "sources.json": Data("[]".utf8),
            "items.json": Data(#"[{"id":"a"},{"id":"b"},{"id":"c"}]"#.utf8),
        ])
        let (payload, skipped) = try BackupZip.import(data: data)
        XCTAssertTrue(payload.pockets.isEmpty)
        XCTAssertTrue(payload.playlists.isEmpty)
        XCTAssertEqual(skipped.items, 3)
    }

    func testImportRejectsForeignApp() throws {
        let data = try makeZip(["manifest.json": Data(#"{"app":"someotherapp","schemaVersion":2}"#.utf8)])
        XCTAssertThrowsError(try BackupZip.import(data: data))
    }

    // MARK: Routing — a full backup is detected as .backup

    func testDetectKindBackup() throws {
        let zipData = try BackupZip.export(sources: [], pockets: [], playlists: [], setlists: [],
                                           editsData: Data("{}".utf8))
        XCTAssertEqual(CollectionsStore.detectKind(data: zipData), .backup)
    }

    func testDetectKindBackupFromPWAManifestNoKind() throws {
        // PWA backup omits `kind` but has sources/items + no playlist.json/pocket.json.
        let data = try makeZip([
            "manifest.json": Data(#"{"app":"pocketdj","schemaVersion":2,"counts":{}}"#.utf8),
            "sources.json": Data("[]".utf8),
            "items.json": Data("[]".utf8),
        ])
        XCTAssertEqual(CollectionsStore.detectKind(data: data), .backup)
    }

    // MARK: helpers

    @MainActor private func makeStore() -> CollectionsStore {
        CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-bk-\(UUID().uuidString).json"))
    }

    @MainActor private func makeEdits() -> EditsStore {
        EditsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-bk-edits-\(UUID().uuidString).json"))
    }

    private func makeZip(_ files: [String: Data]) throws -> Data {
        let archive = try XCTUnwrap(try? Archive(accessMode: .create))
        for (name, data) in files {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                let start = data.index(data.startIndex, offsetBy: Int(position))
                return data[start..<data.index(start, offsetBy: size)]
            }
        }
        return try XCTUnwrap(archive.data)
    }

    private func entry(_ name: String, in zipData: Data) -> Data? {
        guard let archive = try? Archive(data: zipData, accessMode: .read), let e = archive[name] else { return nil }
        var out = Data()
        _ = try? archive.extract(e, skipCRC32: true) { out.append($0) }
        return out
    }
}
