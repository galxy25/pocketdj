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

    private func ids(_ song: IndexSong, _ preference: Bool?) -> [String] {
        AppleMusicProvider.streamCandidates(for: song, preference: preference).map(\.id)
    }

    func testUnsetPreferenceNeverSubstitutes() {
        // The CRITICAL tri-state gate: nil preference ⇒ ONLY the primary, even when a
        // variant is resolved — the re-index must never flip existing streams by itself.
        XCTAssertEqual(ids(explicitWithClean, nil), ["P"])
        XCTAssertEqual(ids(cleanWithExplicit, nil), ["P"])
    }

    func testPreferCleanOrdersCleanVariantFirst() {
        XCTAssertEqual(ids(explicitWithClean, false), ["C", "P"])
        // Clean primary + prefer clean: the primary IS the preferred edition → just it.
        XCTAssertEqual(ids(cleanWithExplicit, false), ["P"])
    }

    func testPreferExplicitOrdersExplicitVariantFirst() {
        XCTAssertEqual(ids(cleanWithExplicit, true), ["E", "P"])
        // Explicit primary + prefer explicit: fallback resolves to the primary itself → just it.
        XCTAssertEqual(ids(explicitWithClean, true), ["P"])
    }

    func testMissingVariantFallsBackToPrimaryAlone() {
        let bare = song(#"{"id":"sng_1a7f6bc854af","artist":"A","name":"N","explicit":true,"appleMusicId":"P"}"#)
        XCTAssertEqual(ids(bare, false), ["P"])
        // No primary at all but a variant present + preference set → the variant alone.
        let variantOnly = song(#"{"id":"sng_1a7f6bc854af","artist":"A","name":"N","explicit":true,"appleMusicIdClean":"C"}"#)
        XCTAssertEqual(ids(variantOnly, false), ["C"])
        // …and with the preference unset, nothing (no primary to verify).
        XCTAssertEqual(ids(variantOnly, nil), [])
    }

    func testCandidateEditionClaims() {
        // The preference-derived variant id CLAIMS its edition (resolve must verify the
        // fetched row's isExplicit agrees); the primary carries NO claim (existence-only,
        // the pre-variant trust model). A mis-resolved / tampered appleMusicIdClean must
        // not stream unverified just because the catalog id exists.
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: explicitWithClean, preference: false),
                       [.init(id: "C", wantExplicit: false), .init(id: "P", wantExplicit: nil)])
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: cleanWithExplicit, preference: true),
                       [.init(id: "E", wantExplicit: true), .init(id: "P", wantExplicit: nil)])
        // The primary reached via the preference accessor (primary IS the preferred
        // edition) keeps its existence-only behavior — no claim attached.
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: cleanWithExplicit, preference: false),
                       [.init(id: "P", wantExplicit: nil)])
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
