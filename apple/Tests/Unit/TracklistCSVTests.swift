import XCTest
@testable import PocketDJ

/// TracklistCSV — the universal (`#,Title,Artist,Album,Year,Genre`) export format + CSV escaping.
final class TracklistCSVTests: XCTestCase {

    func testHeaderRowsAndEscaping() {
        let rows = [
            TracklistCSV.Row(title: "Song A", artist: "Artist", album: "Album", year: 1999, genre: "Rock"),
            TracklistCSV.Row(title: "No, Comma", artist: "A \"B\"", album: "", year: nil, genre: "Jazz"),
        ]
        let csv = String(data: TracklistCSV.data(rows: rows), encoding: .utf8)!
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "#,Title,Artist,Album,Year,Genre")
        XCTAssertEqual(lines[1], "1,Song A,Artist,Album,1999,Rock")   // 1-indexed play position
        // A comma-containing cell is quoted; a quote-containing cell is quoted with inner quotes doubled.
        XCTAssertEqual(lines[2], "2,\"No, Comma\",\"A \"\"B\"\"\",,,Jazz")
        XCTAssertTrue(csv.hasSuffix("\r\n"), "trailing CRLF, matching the PWA")
    }

    func testEmptyIsHeaderOnly() {
        let csv = String(data: TracklistCSV.data(rows: []), encoding: .utf8)!
        XCTAssertEqual(csv, "#,Title,Artist,Album,Year,Genre\r\n")
    }
}
