import XCTest
@testable import PocketDJ

/// The variant-edition DATA MODEL: wire decode of the two variant catalog ids, the
/// `appleMusicId(for:)` edition accessor (variant field first, primary fallback per the
/// `explicit` flag), the `SongVariant` id convention parse/round-trip, edit-overlay
/// preservation, and the player Item's `resolveId` projection.
final class ExplicitVariantModelTests: XCTestCase {

    private func song(_ json: String) throws -> IndexSong {
        try JSONDecoder().decode(IndexSong.self, from: Data(json.utf8))
    }

    func testDecodesVariantIdsFromJSON() throws {
        let with = try song("""
        {"id":"sng_1a7f6bc854af","artist":"CG","name":"Late Night","explicit":true,
         "appleMusicId":"1771724281","appleMusicIdExplicit":"1771724281","appleMusicIdClean":"1771724690"}
        """)
        XCTAssertEqual(with.appleMusicIdExplicit, "1771724281")
        XCTAssertEqual(with.appleMusicIdClean, "1771724690")

        let without = try song("""
        {"id":"sng_1a7f6bc854af","artist":"CG","name":"Late Night","appleMusicId":"1771724281"}
        """)
        XCTAssertNil(without.appleMusicIdExplicit)
        XCTAssertNil(without.appleMusicIdClean)
    }

    func testAppleMusicIdForVariantFallsBackToPrimaryByExplicitFlag() throws {
        // Explicit primary, both variants resolved → the fields win.
        let both = try song("""
        {"id":"sng_1a7f6bc854af","artist":"CG","name":"LN","explicit":true,
         "appleMusicId":"P","appleMusicIdExplicit":"E","appleMusicIdClean":"C"}
        """)
        XCTAssertEqual(both.appleMusicId(for: .explicit), "E")
        XCTAssertEqual(both.appleMusicId(for: .clean), "C")

        // No variant fields: the primary IS its own edition per the `explicit` flag.
        let cleanPrimary = try song("""
        {"id":"sng_1a7f6bc854af","artist":"CG","name":"LN","explicit":false,"appleMusicId":"P"}
        """)
        XCTAssertEqual(cleanPrimary.appleMusicId(for: .clean), "P")
        XCTAssertNil(cleanPrimary.appleMusicId(for: .explicit))

        let explicitPrimary = try song("""
        {"id":"sng_1a7f6bc854af","artist":"CG","name":"LN","explicit":true,"appleMusicId":"P"}
        """)
        XCTAssertEqual(explicitPrimary.appleMusicId(for: .explicit), "P")
        XCTAssertNil(explicitPrimary.appleMusicId(for: .clean))

        // Unclassified (nil explicit) with no variant fields: both editions unknown.
        let unclassified = try song("""
        {"id":"sng_1a7f6bc854af","artist":"CG","name":"LN","appleMusicId":"P"}
        """)
        XCTAssertNil(unclassified.appleMusicId(for: .clean))
        XCTAssertNil(unclassified.appleMusicId(for: .explicit))
    }

    func testVariantIdParseBaseAndRoundTrip() {
        let parsed = SongVariant.parse(fromSongId: "sng_1a7f6bc854af_clean")
        XCTAssertEqual(parsed?.base, "sng_1a7f6bc854af")
        XCTAssertEqual(parsed?.variant, .clean)
        XCTAssertEqual(SongVariant.parse(fromSongId: "sng_1a7f6bc854af_explicit")?.variant, .explicit)

        // Round-trip: variantId(baseId(x)) reproduces x.
        XCTAssertEqual(SongVariant.variantId("sng_1a7f6bc854af", .clean), "sng_1a7f6bc854af_clean")
        XCTAssertEqual(SongVariant.baseId("sng_1a7f6bc854af_clean"), "sng_1a7f6bc854af")
        XCTAssertEqual(SongVariant.baseId("sng_1a7f6bc854af"), "sng_1a7f6bc854af")   // identity for plain

        // NON-matching shapes never parse (and baseId is identity for them).
        for id in ["amrec_123", "smp_x", "sng_short_clean", "sng_1a7f6bc854af",
                   "sng_1A7F6BC854AF_clean",       // uppercase hex is not the id convention
                   "sng_1a7f6bc854af_remix",       // unknown variant word
                   "pdj_1a7f6bc854af_clean"] {
            XCTAssertNil(SongVariant.parse(fromSongId: id), id)
            XCTAssertEqual(SongVariant.baseId(id), id, id)
        }
    }

    func testApplyingSongEditPreservesVariantIds() throws {
        let s = try song("""
        {"id":"sng_1a7f6bc854af","artist":"CG","name":"LN","explicit":true,
         "appleMusicId":"P","appleMusicIdExplicit":"E","appleMusicIdClean":"C"}
        """)
        let edited = s.applying(SongEdit(name: "Renamed", bpm: 120))
        XCTAssertEqual(edited.name, "Renamed")
        XCTAssertEqual(edited.appleMusicIdExplicit, "E")   // applying() must not drop them
        XCTAssertEqual(edited.appleMusicIdClean, "C")
        XCTAssertEqual(edited.appleMusicId, "P")
    }

    @MainActor
    func testSetlistPlayerItemResolveId() {
        let plain = SetlistPlayer.Item(id: "sng_1a7f6bc854af", title: "LN", artist: "CG")
        XCTAssertEqual(plain.resolveId, "sng_1a7f6bc854af")
        let clean = SetlistPlayer.Item(id: "sng_1a7f6bc854af", title: "LN", artist: "CG",
                                       variant: .clean)
        XCTAssertEqual(clean.resolveId, "sng_1a7f6bc854af_clean")
        // Variant is a playback parameter, not row identity — equality ignores it.
        XCTAssertEqual(plain, clean)
    }

    /// The end-of-track / jump ownership test: a substituted row answers to BOTH its ids —
    /// a stream/rip resolves under the VARIANT id while a burned file plays under the BASE
    /// id — but a plain row never answers to a variant id (a foreign edition stays foreign).
    @MainActor
    func testSetlistPlayerItemMatches() {
        let plain = SetlistPlayer.Item(id: "sng_1a7f6bc854af", title: "LN", artist: "CG")
        XCTAssertTrue(plain.matches("sng_1a7f6bc854af"))
        XCTAssertFalse(plain.matches("sng_1a7f6bc854af_clean"),
                       "a plain row never answers to a variant id")

        let clean = SetlistPlayer.Item(id: "sng_1a7f6bc854af", title: "LN", artist: "CG",
                                       variant: .clean)
        XCTAssertTrue(clean.matches("sng_1a7f6bc854af"), "burned-file plays stamp the base id")
        XCTAssertTrue(clean.matches("sng_1a7f6bc854af_clean"), "stream/rip plays stamp the variant id")
        XCTAssertFalse(clean.matches("sng_1a7f6bc854af_explicit"), "a different edition is a foreign play")
        XCTAssertFalse(clean.matches("sng_ffffffffffff"), "a different song is a foreign play")
    }

    /// LATE STAMPING vs. the `matches` invariant. `SetlistPlayer.stampEditions` applies the
    /// global "Prefer explicit versions" preference at `play()`, so a row that was PLAIN when
    /// the caller built it can acquire a `variant` — and therefore a `resolveId` — before the
    /// first end-of-track guard runs. That widening is only safe because a row answers to a
    /// variant id ONLY for the edition it actually plays:
    ///   • a prefer-explicit row answers to its own `_explicit` id (that is what makes
    ///     auto-advance work at all once the preference is on) but NOT to `_clean`;
    ///   • a clean-locked row answers to `_clean` but NOT to `_explicit`, so an explicit cut
    ///     of the same song played from another surface stays a FOREIGN play and can never
    ///     advance or reposition a clean-only run.
    /// If either half of this ever flips, `matches` has to be widened deliberately rather than
    /// by drift — see the note on `SetlistPlayer.Item.matches`.
    @MainActor
    func testLateEditionStampingKeepsForeignEditionsForeign() {
        let base = "sng_1a7f6bc854af"
        // Stamped by the PREFERENCE (what stampEditions does to a previously-plain row).
        var preferred = SetlistPlayer.Item(id: base, title: "LN", artist: "CG")
        preferred.variant = .explicit
        preferred.editionCatalogId = "1440831608"
        XCTAssertTrue(preferred.matches(base), "burned-file plays still stamp the base id")
        XCTAssertTrue(preferred.matches("\(base)_explicit"), "its own stream/rip play is NOT foreign")
        XCTAssertFalse(preferred.matches("\(base)_clean"),
                       "the OTHER edition stays foreign even after late stamping")

        // Stamped as a RESTRICTION (a clean-only run locks its rows wholesale).
        var locked = SetlistPlayer.Item(id: base, title: "LN", artist: "CG")
        locked.variant = .clean
        locked.editionLocked = true
        XCTAssertFalse(locked.matches("\(base)_explicit"),
                       "an explicit cut played elsewhere can never advance a clean-only run")
        XCTAssertEqual(locked.editionDecision.reason, .collectionCleanOnly,
                       "a locked row rebuilds as a RESTRICTION, so it never falls back to another edition")
        XCTAssertFalse(locked.editionDecision.allowsStoredFallback)

        // An unlocked stamp rebuilds as a PREFERENCE, which may degrade onto a stored edition.
        XCTAssertEqual(preferred.editionDecision.reason, .globalPreference)
        XCTAssertTrue(preferred.editionDecision.allowsStoredFallback)
    }
}
