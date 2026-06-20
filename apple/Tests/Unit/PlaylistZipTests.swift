import XCTest
import ZIPFoundation
@testable import PocketDJ

/// Tests for the PWA-compatible single-playlist transfer format
/// (`.playlist.pocketdj.zip`) — import, export, round-trip, and version tolerance.
final class PlaylistZipTests: XCTestCase {

    /// The user's REAL export, copied into the test bundle resources.
    private func sampleFixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "sample-playlist", withExtension: "playlist.pocketdj.zip")
                ?? Bundle(for: Self.self).url(forResource: "sample-playlist.playlist.pocketdj", withExtension: "zip"),
            "sample-playlist fixture missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    // MARK: Real fixture

    func testImportsRealFixture() throws {
        let data = try sampleFixtureData()
        let (playlist, pockets) = try PlaylistZip.import(data: data)

        XCTAssertEqual(playlist.name, "1 — take 3")
        XCTAssertEqual(playlist.sequences.count, 3)               // Openers / Main Event / Final Rounds
        XCTAssertEqual(playlist.sequences.map { $0.name }, ["Openers", "Main Event", "Final Rounds"])
        let songCounts = playlist.sequences.map { ($0.children ?? []).count }
        XCTAssertEqual(songCounts, [48, 38, 20])                  // 106 songs total
        XCTAssertEqual(songCounts.reduce(0, +), 106)
        XCTAssertTrue(pockets.isEmpty)                            // slim/non-portable, no pockets

        // Every node is a song node referencing a catalog id (resolved at display).
        let allNodes = playlist.sequences.flatMap { $0.children ?? [] }
        XCTAssertTrue(allNodes.allSatisfy { $0.kind == .song && $0.songId != nil })

        // Fresh ids minted: the source playlist id was pls_4116..., nodes nd_...
        XCTAssertTrue(playlist.id.hasPrefix("pls_"))
        XCTAssertNotEqual(playlist.id, "pls_41165912-0c2a-44a1-afa9-fe05844b8226")
        XCTAssertTrue(allNodes.allSatisfy { $0.nodeId.hasPrefix("nd_") })
    }

    @MainActor
    func testImportRealFixtureIntoStore() throws {
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-zip-\(UUID().uuidString).json"))
        try s.importPlaylistZip(data: try sampleFixtureData())
        XCTAssertEqual(s.playlists.count, 1)
        XCTAssertEqual(s.playlists.first?.name, "1 — take 3")
        XCTAssertEqual(s.playlists.first?.sequences.count, 3)
    }

    // MARK: Round-trip (native → zip → import)

    @MainActor
    func testRoundTripNativePlaylist() throws {
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-rt-\(UUID().uuidString).json"))
        let pl = s.createPlaylist("Set", songIds: ["sng_1", "sng_2", "sng_3"])
        s.addText("mic break", toPlaylist: pl.id)
        let original = try XCTUnwrap(s.playlist(pl.id))

        let zipData = try XCTUnwrap(try s.exportPlaylistZip(pl.id))
        let (imported, pockets) = try PlaylistZip.import(data: zipData)

        // Same STRUCTURE…
        XCTAssertEqual(imported.name, original.name)
        XCTAssertEqual(imported.sequences.count, original.sequences.count)
        XCTAssertEqual(imported.sequences.first?.children?.compactMap(\.songId), ["sng_1", "sng_2", "sng_3"])
        XCTAssertEqual(imported.sequences.first?.children?.last?.kind, .text)
        XCTAssertEqual(imported.sequences.first?.children?.last?.text, "mic break")
        XCTAssertTrue(pockets.isEmpty)

        // …with NEW ids.
        XCTAssertNotEqual(imported.id, original.id)
        let origNodeIds = Set(original.sequences.flatMap { ($0.children ?? []) + [$0] }.map(\.nodeId))
        let newNodeIds = Set(imported.sequences.flatMap { ($0.children ?? []) + [$0] }.map(\.nodeId))
        XCTAssertTrue(origNodeIds.isDisjoint(with: newNodeIds))
    }

    // MARK: Pocket DAG expansion + remap

    @MainActor
    func testExportExpandsPocketDAGAndImportRemaps() throws {
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-dag-\(UUID().uuidString).json"))
        let parent = s.createPocket("Parent")
        let child = s.createPocket("Child")
        s.addChildPocket(child.id, toPocket: parent.id)
        s.addSong("sng_1", toPocket: child.id)
        let pl = s.createPlaylist("With Pocket")
        s.addPocketRef(parent.id, toPlaylist: pl.id)              // only the parent is referenced

        let zipData = try XCTUnwrap(try s.exportPlaylistZip(pl.id))
        let (imported, pockets) = try PlaylistZip.import(data: zipData)

        // DAG-expanded: BOTH parent + child travel.
        XCTAssertEqual(Set(pockets.map(\.name)), ["Parent", "Child"])
        // Fresh pocket ids…
        XCTAssertFalse(pockets.contains { $0.id == parent.id || $0.id == child.id })
        // …and intra-bundle refs remapped: the imported parent's childPocketId points
        // at the imported child, and the playlist's pocket node at the imported parent.
        let newParent = try XCTUnwrap(pockets.first { $0.name == "Parent" })
        let newChild = try XCTUnwrap(pockets.first { $0.name == "Child" })
        XCTAssertEqual(newParent.childPocketIds, [newChild.id])
        let pocketNode = imported.sequences.flatMap { $0.children ?? [] }.first { $0.kind == .pocket }
        XCTAssertEqual(pocketNode?.pocketId, newParent.id)
    }

    // MARK: Insert into store (no clobber)

    @MainActor
    func testInsertImportedAppendsWithoutClobber() throws {
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-ins-\(UUID().uuidString).json"))
        let pl = s.createPlaylist("Set", songIds: ["sng_1"])
        let before = s.playlists.count
        try s.importPlaylistZip(data: try XCTUnwrap(try s.exportPlaylistZip(pl.id)))
        XCTAssertEqual(s.playlists.count, before + 1)
        XCTAssertNotEqual(s.playlists.last?.id, pl.id)
    }

    // MARK: Manifest version tolerance

    func testImportToleratesMissingManifest() throws {
        // A bundle with ONLY playlist.json (no manifest) still imports.
        let pl = CollectionsFactory.makePlaylist("No Manifest", now: 0)
        let data = try makeZip(["playlist.json": try JSONEncoder().encode(pl)])
        let (imported, _) = try PlaylistZip.import(data: data)
        XCTAssertEqual(imported.name, "No Manifest")
    }

    func testImportToleratesExtraManifestFields() throws {
        let pl = CollectionsFactory.makePlaylist("Future", now: 0)
        let manifest = #"{"app":"pocketdj","kind":"playlist","schemaVersion":99,"futureField":true,"playlistName":"Future","exportedAt":"x"}"#
        let data = try makeZip([
            "manifest.json": Data(manifest.utf8),
            "playlist.json": try JSONEncoder().encode(pl),
        ])
        let (imported, _) = try PlaylistZip.import(data: data)
        XCTAssertEqual(imported.name, "Future")
    }

    func testImportRejectsForeignManifest() throws {
        let pl = CollectionsFactory.makePlaylist("X", now: 0)
        let data = try makeZip([
            "manifest.json": Data(#"{"app":"someotherapp","kind":"playlist"}"#.utf8),
            "playlist.json": try JSONEncoder().encode(pl),
        ])
        XCTAssertThrowsError(try PlaylistZip.import(data: data))
    }

    func testImportRejectsMissingPlaylist() throws {
        let data = try makeZip(["manifest.json": Data(#"{"app":"pocketdj","kind":"playlist"}"#.utf8)])
        XCTAssertThrowsError(try PlaylistZip.import(data: data))
    }

    // MARK: Exported manifest shape (PWA-readable)

    @MainActor
    func testExportedManifestMatchesPWAShape() throws {
        let s = CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-man-\(UUID().uuidString).json"))
        let pl = s.createPlaylist("Shape", songIds: ["sng_1"])
        let zipData = try XCTUnwrap(try s.exportPlaylistZip(pl.id))

        let manRaw = try XCTUnwrap(entry("manifest.json", in: zipData))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: manRaw) as? [String: Any])
        XCTAssertEqual(json["app"] as? String, "pocketdj")
        XCTAssertEqual(json["kind"] as? String, "playlist")
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["portable"] as? Bool, false)
        XCTAssertEqual(json["playlistName"] as? String, "Shape")
        let counts = try XCTUnwrap(json["counts"] as? [String: Any])
        XCTAssertEqual(counts["items"] as? Int, 0)
        XCTAssertEqual(counts["pockets"] as? Int, 0)
        XCTAssertEqual(counts["setlists"] as? Int, 0)
        XCTAssertEqual(counts["art"] as? Int, 0)
        XCTAssertNotNil(json["exportedAt"] as? String)

        // playlist.json present + decodable; pockets.json an array.
        XCTAssertNotNil(entry("playlist.json", in: zipData))
        let pkts = try XCTUnwrap(entry("pockets.json", in: zipData))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: pkts) as? [Any])
    }

    // MARK: helpers

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
