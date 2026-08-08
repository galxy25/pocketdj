import XCTest
@testable import PocketDJ

/// Music with Friends deep-link parsing — and the guaranteed NON-collision with
/// jukebox links ("mwf" is 3 chars; jukebox ids are [a-z2-7]{4,32}).
final class MwFLinkTests: XCTestCase {

    func testUniversalLinkParses() {
        let link = MwFLink(url: URL(string: "https://jukebox.pocket-dj.com/mwf/abcd2345/")!)
        XCTAssertEqual(link?.sessionId, "abcd2345")
        XCTAssertEqual(link?.guestBase?.absoluteString, "https://jukebox.pocket-dj.com")
        // Trailing paths tolerated (state.json etc.).
        XCTAssertEqual(MwFLink(url: URL(string: "https://jukebox.pocket-dj.com/mwf/abcd2345/state.json")!)?.sessionId,
                       "abcd2345")
        // Case-folded host + MWF segment.
        XCTAssertEqual(MwFLink(url: URL(string: "https://JUKEBOX.pocket-dj.com/MWF/abcd2345/")!)?.sessionId,
                       "abcd2345")
    }

    func testCustomSchemeParses() {
        XCTAssertEqual(MwFLink(url: URL(string: "pocketdj://mwf/abcd2345")!)?.sessionId, "abcd2345")
        XCTAssertNil(MwFLink(url: URL(string: "pocketdj://mwf/abcd2345")!)?.guestBase)
        // Tolerates the empty-host triple-slash form.
        XCTAssertEqual(MwFLink(url: URL(string: "pocketdj:///mwf/abcd2345")!)?.sessionId, "abcd2345")
        // A jukebox scheme link is NOT an MwF link.
        XCTAssertNil(MwFLink(url: URL(string: "pocketdj://jukebox/abcd2345")!))
    }

    func testJukeboxLinkRejectsMwfURL() {
        // The universal MwF link must never be misread as a jukebox join ("mwf" fails
        // JukeboxLink's id validation) — the onOpenURL ordering is belt-and-braces only.
        XCTAssertNil(JukeboxLink(url: URL(string: "https://jukebox.pocket-dj.com/mwf/abcd2345/")!))
        XCTAssertNil(JukeboxLink(url: URL(string: "pocketdj://mwf/abcd2345")!))
        // And the reverse: a plain jukebox URL is not an MwF link.
        XCTAssertNil(MwFLink(url: URL(string: "https://jukebox.pocket-dj.com/abcd2345/")!))
    }

    func testInvalidIdRejected() {
        XCTAssertNil(MwFLink(url: URL(string: "https://jukebox.pocket-dj.com/mwf/ab/")!), "too short")
        XCTAssertNil(MwFLink(url: URL(string: "https://jukebox.pocket-dj.com/mwf/ABCD9999/")!), "not base32 (0/1/8/9 excluded)")
        XCTAssertNil(MwFLink(url: URL(string: "https://jukebox.pocket-dj.com/mwf/")!), "no id")
        XCTAssertNil(MwFLink(url: URL(string: "https://elsewhere.example.com/mwf/abcd2345/")!), "wrong host")
        XCTAssertNil(MwFLink(url: URL(string: "https://jukebox.pocket-dj.com/.well-known/apple-app-site-association")!))
    }

    func testStateURL() {
        let universal = MwFLink(url: URL(string: "https://jukebox.pocket-dj.com/mwf/abcd2345/")!)
        XCTAssertEqual(universal?.stateURL?.absoluteString,
                       "https://jukebox.pocket-dj.com/mwf/abcd2345/state.json")
        // Custom-scheme links fall back to the canonical host.
        let scheme = MwFLink(url: URL(string: "pocketdj://mwf/abcd2345")!)
        XCTAssertEqual(scheme?.stateURL?.absoluteString,
                       "https://jukebox.pocket-dj.com/mwf/abcd2345/state.json")
    }
}
