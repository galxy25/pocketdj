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

    /// The payload crosses a process boundary (any app can author the UTI), so a junk id
    /// beyond any real namespaced-id length never reaches the persisted document.
    func testSongDropDropsOverlongIds() {
        let long = "smp_" + String(repeating: "x", count: SongDrop.maxIdLength)
        let ids = SongDrop.acceptableIds([SongTransfer(songIds: [long, "sng_1"], text: nil)]) { _ in true }
        XCTAssertEqual(ids, ["sng_1"])
    }

    /// A hostile payload can't balloon the document either — total accepted ids are capped.
    func testSongDropCapsTotalCount() {
        let ids = (0..<(SongDrop.maxIds + 5)).map { "sng_\($0)" }
        let out = SongDrop.acceptableIds([SongTransfer(songIds: ids, text: nil)]) { _ in true }
        XCTAssertEqual(out.count, SongDrop.maxIds)
        XCTAssertEqual(out.first, "sng_0")                 // order preserved; the TAIL is dropped
    }

    /// The paste decode boundary refuses oversized foreign blobs BEFORE JSONDecoder
    /// materializes them; a legitimate payload still round-trips.
    func testPasteboardDecodeEnforcesByteCap() throws {
        let legit = try JSONEncoder().encode(SongTransfer(songIds: ["sng_1", "sng_2"], text: nil))
        XCTAssertEqual(SongPasteboard.decode(legit)?.songIds, ["sng_1", "sng_2"])
        // VALID JSON past the cap — only the byte gate (not a decode failure) can reject it.
        let oversized = try JSONEncoder().encode(SongTransfer(
            songIds: ["sng_1"], text: String(repeating: "x", count: SongPasteboard.maxPayloadBytes)))
        XCTAssertGreaterThan(oversized.count, SongPasteboard.maxPayloadBytes)
        XCTAssertNil(SongPasteboard.decode(oversized))
    }
}
