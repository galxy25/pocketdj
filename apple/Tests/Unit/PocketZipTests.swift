import XCTest
import ZIPFoundation
@testable import PocketDJ

/// Tests for the standalone single-pocket transfer format (`.pocket.pocketdj.zip`):
/// round-trip, fresh ids, child-pocket DAG expansion + remap, manifest tolerance.
final class PocketZipTests: XCTestCase {

    // MARK: Round-trip (native → zip → import), fresh ids

    @MainActor
    func testRoundTripFreshIds() throws {
        let s = makeStore()
        let p = s.createPocket("Deep Cuts")
        s.addSong("sng_1", toPocket: p.id)
        s.addAlbum("alb_9", toPocket: p.id)
        let original = try XCTUnwrap(s.pocket(p.id))

        let zipData = try XCTUnwrap(try s.exportPocketZip(p.id))
        let (imported, children) = try PocketZip.import(data: zipData)

        XCTAssertEqual(imported.name, "Deep Cuts")
        XCTAssertEqual(imported.songIds, ["sng_1"])     // members travel by catalog id
        XCTAssertEqual(imported.albumIds, ["alb_9"])
        XCTAssertTrue(children.isEmpty)
        XCTAssertTrue(imported.id.hasPrefix("pkt_"))
        XCTAssertNotEqual(imported.id, original.id)     // fresh id
    }

    // MARK: Child-pocket DAG expansion + ref remap

    @MainActor
    func testExportExpandsChildDAGAndImportRemaps() throws {
        let s = makeStore()
        let root = s.createPocket("Root")
        let child = s.createPocket("Child")
        let grand = s.createPocket("Grand")
        s.addChildPocket(child.id, toPocket: root.id)
        s.addChildPocket(grand.id, toPocket: child.id)

        let zipData = try XCTUnwrap(try s.exportPocketZip(root.id))
        let (imported, children) = try PocketZip.import(data: zipData)

        // DAG-expanded: both child + grandchild travel (root excluded from children).
        XCTAssertEqual(Set(children.map(\.name)), ["Child", "Grand"])
        // Fresh ids everywhere…
        XCTAssertFalse([imported.id] + children.map(\.id) == [root.id, child.id, grand.id])
        XCTAssertNotEqual(imported.id, root.id)
        XCTAssertFalse(children.contains { $0.id == child.id || $0.id == grand.id })
        // …and refs remapped: imported root → imported child → imported grand.
        let newChild = try XCTUnwrap(children.first { $0.name == "Child" })
        let newGrand = try XCTUnwrap(children.first { $0.name == "Grand" })
        XCTAssertEqual(imported.childPocketIds, [newChild.id])
        XCTAssertEqual(newChild.childPocketIds, [newGrand.id])
    }

    // MARK: Insert into store (no clobber)

    @MainActor
    func testImportInsertsWithoutClobber() throws {
        let s = makeStore()
        let root = s.createPocket("Root")
        let child = s.createPocket("Child")
        s.addChildPocket(child.id, toPocket: root.id)
        let before = s.pockets.count

        try s.importPocketZip(data: try XCTUnwrap(try s.exportPocketZip(root.id)))
        // root + child duplicated under fresh ids.
        XCTAssertEqual(s.pockets.count, before + 2)
        XCTAssertEqual(s.pockets.filter { $0.name == "Root" }.count, 2)
    }

    // MARK: Manifest tolerance / routing

    func testImportToleratesMissingManifest() throws {
        let p = CollectionsFactory.makePocket("No Manifest", now: 0)
        let data = try makeZip(["pocket.json": try JSONEncoder().encode(p)])
        let (imported, _) = try PocketZip.import(data: data)
        XCTAssertEqual(imported.name, "No Manifest")
    }

    func testImportRejectsForeignManifest() throws {
        let p = CollectionsFactory.makePocket("X", now: 0)
        let data = try makeZip([
            "manifest.json": Data(#"{"app":"someotherapp","kind":"pocket"}"#.utf8),
            "pocket.json": try JSONEncoder().encode(p),
        ])
        XCTAssertThrowsError(try PocketZip.import(data: data))
    }

    @MainActor
    func testExportedManifestShape() throws {
        let s = makeStore()
        let root = s.createPocket("Shape")
        let child = s.createPocket("C")
        s.addChildPocket(child.id, toPocket: root.id)
        let zipData = try XCTUnwrap(try s.exportPocketZip(root.id))

        let manRaw = try XCTUnwrap(entry("manifest.json", in: zipData))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: manRaw) as? [String: Any])
        XCTAssertEqual(json["app"] as? String, "pocketdj")
        XCTAssertEqual(json["kind"] as? String, "pocket")
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["portable"] as? Bool, false)
        XCTAssertEqual(json["pocketName"] as? String, "Shape")
        let counts = try XCTUnwrap(json["counts"] as? [String: Any])
        XCTAssertEqual(counts["pockets"] as? Int, 2)   // root + 1 child
    }

    @MainActor
    func testImportAnyRoutesPocketZip() throws {
        let s = makeStore()
        let root = s.createPocket("Routed")
        let data = try XCTUnwrap(try s.exportPocketZip(root.id))
        XCTAssertEqual(CollectionsStore.detectKind(data: data), .pocket)
    }

    // MARK: helpers

    @MainActor private func makeStore() -> CollectionsStore {
        CollectionsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-pkt-\(UUID().uuidString).json"))
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
