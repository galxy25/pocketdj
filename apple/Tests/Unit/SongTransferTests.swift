import XCTest
import UniformTypeIdentifiers
@testable import PocketDJ

/// The drag/clipboard payload + pasteboard twin + drop validation.
final class SongTransferTests: XCTestCase {

    private func catalog(_ count: Int) -> [String: IndexSong] {
        var byId: [String: IndexSong] = [:]
        for i in 1...count {
            byId["sng_\(i)"] = IndexSong.minimal(id: "sng_\(i)", name: "Song \(i)", artist: "Artist \(i)")
        }
        return byId
    }

    func testCodableRoundTrip() throws {
        let t = SongTransfer(songIds: ["sng_1", "smp_9"], text: "A — B")
        let back = try JSONDecoder().decode(SongTransfer.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
    }

    /// Mirrors the existing pocketDJCollection identifier guard: the exported-as string
    /// must match the project.yml UTExportedTypeDeclaration exactly.
    func testUTTypeIdentifierIsSonglist() {
        XCTAssertEqual(UTType.pocketDJSongList.identifier, "com.pocketdj.songlist")
        XCTAssertEqual(UTType.pocketDJSongList.identifier, SongPasteboard.utiString)
        XCTAssertTrue(UTType.pocketDJSongList.conforms(to: .json))
    }

    func testPasteboardWriteReadRoundTrip() {
        let t = SongTransfer.make(ids: ["sng_1", "sng_2"], songsById: catalog(2))
        SongPasteboard.write(t)
        let back = SongPasteboard.read()
        XCTAssertEqual(back?.songIds, ["sng_1", "sng_2"])
        XCTAssertEqual(back?.text, "Artist 1 — Song 1\nArtist 2 — Song 2")
    }

    func testHasSongsReflectsPasteboard() {
        SongPasteboard.write(SongTransfer(songIds: ["sng_1"], text: nil))
        XCTAssertTrue(SongPasteboard.hasSongs)
    }

    /// 201 resolvable ids → the text fallback caps at 200 lines + "…and 1 more", but the
    /// PAYLOAD keeps all 201 ids (a capped drag must still drop every song).
    func testMakeCapsTextAt200Lines() {
        let ids = (1...201).map { "sng_\($0)" }
        let t = SongTransfer.make(ids: ids, songsById: catalog(201))
        XCTAssertEqual(t.songIds.count, 201)
        let lines = (t.text ?? "").components(separatedBy: "\n")
        XCTAssertEqual(lines.count, SongTransfer.textLineCap + 1)
        XCTAssertEqual(lines.last, "…and 1 more")
    }

    func testPlainTextFallsBackToIdsWhenNoTitles() {
        let t = SongTransfer.make(ids: ["sng_x", "sng_y"], songsById: [:])
        XCTAssertNil(t.text)
        XCTAssertEqual(t.plainTextExport, "sng_x\nsng_y")
    }

    func testSongDropAcceptableIdsFiltersDedupsPreservesOrder() {
        let items = [SongTransfer(songIds: ["sng_2", "sng_unknown", "sng_1"], text: nil),
                     SongTransfer(songIds: ["sng_1", "smp_7"], text: nil)]
        let known: Set<String> = ["sng_1", "sng_2"]
        let ids = SongDrop.acceptableIds(items) { known.contains($0) || $0.hasPrefix("smp_") }
        XCTAssertEqual(ids, ["sng_2", "sng_1", "smp_7"])   // unknown dropped, dup deduped, order kept
    }
}
