import XCTest
@testable import PocketDJ

/// The pure edition-selection statics on AppleMusicProvider: `streamCandidates` ordering
/// under the tri-state preference (nil = unset = primary only), and the tight
/// `editionMatches` filter the variant resolve + VariantResolver share. No MusicKit.
@MainActor
final class AppleMusicProviderCandidatesTests: XCTestCase {

    private func song(_ json: String) -> IndexSong {
        try! JSONDecoder().decode(IndexSong.self, from: Data(json.utf8))
    }

    // Explicit primary with a resolved clean sibling.
    private var explicitWithClean: IndexSong {
        song(#"{"id":"sng_1a7f6bc854af","artist":"A","name":"N","explicit":true,"appleMusicId":"P","appleMusicIdClean":"C"}"#)
    }
    // Clean primary with a resolved explicit sibling.
    private var cleanWithExplicit: IndexSong {
        song(#"{"id":"sng_1a7f6bc854af","artist":"A","name":"N","explicit":false,"appleMusicId":"P","appleMusicIdExplicit":"E"}"#)
    }

    func testUnsetPreferenceNeverSubstitutes() {
        // The CRITICAL tri-state gate: nil preference ⇒ ONLY the primary, even when a
        // variant is resolved — the re-index must never flip existing streams by itself.
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: explicitWithClean, preference: nil), ["P"])
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: cleanWithExplicit, preference: nil), ["P"])
    }

    func testPreferCleanOrdersCleanVariantFirst() {
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: explicitWithClean, preference: false),
                       ["C", "P"])
        // Clean primary + prefer clean: the primary IS the preferred edition → just it.
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: cleanWithExplicit, preference: false),
                       ["P"])
    }

    func testPreferExplicitOrdersExplicitVariantFirst() {
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: cleanWithExplicit, preference: true),
                       ["E", "P"])
        // Explicit primary + prefer explicit: fallback resolves to the primary itself → just it.
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: explicitWithClean, preference: true),
                       ["P"])
    }

    func testMissingVariantFallsBackToPrimaryAlone() {
        let bare = song(#"{"id":"sng_1a7f6bc854af","artist":"A","name":"N","explicit":true,"appleMusicId":"P"}"#)
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: bare, preference: false), ["P"])
        // No primary at all but a variant present + preference set → the variant alone.
        let variantOnly = song(#"{"id":"sng_1a7f6bc854af","artist":"A","name":"N","explicit":true,"appleMusicIdClean":"C"}"#)
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: variantOnly, preference: false), ["C"])
        // …and with the preference unset, nothing (no primary to verify).
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: variantOnly, preference: nil), [])
    }

    // MARK: editionMatches — the tight edition filter

    private func row(title: String, artist: String, seconds: Double?, explicitFlag: Bool) -> AppleMusicSongRow {
        AppleMusicSongRow(storeID: "1", title: title, artist: artist, albumTitle: nil,
                          trackNumber: nil, year: nil, durationSeconds: seconds,
                          isExplicit: explicitFlag, artworkURL: nil)
    }

    func testEditionMatchesRequiresEditionTitleArtistAndDuration() {
        // Same recording, right edition, in-duration → match. Paren tails are cosmetic.
        XCTAssertTrue(AppleMusicProvider.editionMatches(
            row(title: "Late Night (feat. Jaden)", artist: "Childish Gambino", seconds: 289, explicitFlag: true),
            name: "Late Night", artist: "Childish Gambino", lengthMs: 289_000, wantExplicit: true))
        // Wrong edition → never.
        XCTAssertFalse(AppleMusicProvider.editionMatches(
            row(title: "Late Night", artist: "Childish Gambino", seconds: 289, explicitFlag: false),
            name: "Late Night", artist: "Childish Gambino", lengthMs: 289_000, wantExplicit: true))
        // Different title → never.
        XCTAssertFalse(AppleMusicProvider.editionMatches(
            row(title: "Late Night II", artist: "Childish Gambino", seconds: 289, explicitFlag: true),
            name: "Late Night", artist: "Childish Gambino", lengthMs: 289_000, wantExplicit: true))
        // Duration off by more than 7 s (both known) → never.
        XCTAssertFalse(AppleMusicProvider.editionMatches(
            row(title: "Late Night", artist: "Childish Gambino", seconds: 289 + 8, explicitFlag: true),
            name: "Late Night", artist: "Childish Gambino", lengthMs: 289_000, wantExplicit: true))
        // Unknown length on our side → duration gate waived (both-known rule).
        XCTAssertTrue(AppleMusicProvider.editionMatches(
            row(title: "Late Night", artist: "Childish Gambino", seconds: 289, explicitFlag: true),
            name: "Late Night", artist: "Childish Gambino", lengthMs: nil, wantExplicit: true))
        // Artist containment (feat. spillover) passes.
        XCTAssertTrue(AppleMusicProvider.editionMatches(
            row(title: "Late Night", artist: "Childish Gambino & Jaden", seconds: 289, explicitFlag: true),
            name: "Late Night", artist: "Childish Gambino", lengthMs: 289_000, wantExplicit: true))
    }
}
