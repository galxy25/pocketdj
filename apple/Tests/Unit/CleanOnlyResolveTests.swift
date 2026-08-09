import XCTest
@testable import PocketDJ

/// The pure clean-versions-only resolution (`CleanOnly`): non-explicit and unclassified
/// pass; explicit-with-clean-id substitutes; explicit-without drops; studio/profile/
/// unknown ids pass through; ripIds produces variant-suffixed ids for substitutions.
final class CleanOnlyResolveTests: XCTestCase {

    private func song(_ json: String) -> IndexSong {
        try! JSONDecoder().decode(IndexSong.self, from: Data(json.utf8))
    }

    /// sng_c clean · sng_u unclassified · sng_s explicit WITH a clean id ·
    /// sng_k explicit WITHOUT one · sng_p explicit whose PRIMARY is its own clean proof-case.
    private var songsById: [String: IndexSong] {
        [
            "sng_00000000000c": song(#"{"id":"sng_00000000000c","artist":"A","name":"Clean","explicit":false}"#),
            "sng_00000000000u": song(#"{"id":"sng_00000000000u","artist":"A","name":"Unclassified"}"#),
            "sng_00000000000d": song(#"{"id":"sng_00000000000d","artist":"A","name":"Sub","explicit":true,"appleMusicId":"P","appleMusicIdClean":"C"}"#),
            "sng_00000000000e": song(#"{"id":"sng_00000000000e","artist":"A","name":"Skip","explicit":true,"appleMusicId":"P"}"#),
        ]
    }

    func testNonExplicitAndUnclassifiedPassThrough() {
        let r = CleanOnly.resolve(ids: ["sng_00000000000c", "sng_00000000000u"], songsById: songsById)
        XCTAssertEqual(r.ids, ["sng_00000000000c", "sng_00000000000u"])
        XCTAssertTrue(r.variants.isEmpty)
    }

    func testExplicitWithCleanIdSubstitutesVariant() {
        let r = CleanOnly.resolve(ids: ["sng_00000000000d"], songsById: songsById)
        XCTAssertEqual(r.ids, ["sng_00000000000d"])
        XCTAssertEqual(r.variants["sng_00000000000d"], .clean)
    }

    func testExplicitWithoutCleanIdDrops() {
        let r = CleanOnly.resolve(ids: ["sng_00000000000c", "sng_00000000000e"], songsById: songsById)
        XCTAssertEqual(r.ids, ["sng_00000000000c"])   // the skip case is GONE, not substituted
        XCTAssertTrue(r.variants.isEmpty)
        XCTAssertTrue(CleanOnly.isSkipped(songsById["sng_00000000000e"]))
        XCTAssertFalse(CleanOnly.isSkipped(songsById["sng_00000000000c"]))
        XCTAssertFalse(CleanOnly.isSkipped(nil))
    }

    /// An explicit==false primary is ALREADY clean — never substituted (no variant stamp).
    func testExplicitPrimaryCleanFlagFalseUsesPrimaryAsClean() {
        let s = song(#"{"id":"sng_00000000000f","artist":"A","name":"P","explicit":false,"appleMusicId":"P"}"#)
        let r = CleanOnly.resolve(ids: [s.id], songsById: [s.id: s])
        XCTAssertEqual(r.ids, [s.id])
        XCTAssertNil(r.variants[s.id])
    }

    func testStudioProfileUnknownIdsPassThrough() {
        let ids = ["smp_abc", "lp_def", "pdj_xyz", "sng_unknown_id00"]
        let r = CleanOnly.resolve(ids: ids, songsById: songsById)
        XCTAssertEqual(r.ids, ids)                 // not in songsById → pass untouched
        XCTAssertTrue(r.variants.isEmpty)
    }

    func testRipIdsProduceVariantSuffixedIds() {
        let out = CleanOnly.ripIds(
            ids: ["sng_00000000000c", "sng_00000000000d", "sng_00000000000e"],
            songsById: songsById)
        XCTAssertEqual(out, ["sng_00000000000c", "sng_00000000000d_clean"])
    }
}

/// THE PRECEDENCE TABLE (`EditionPolicy`) — the one function every play/store/acquire path
/// routes through, plus the edition-keyed storage ladder it drives:
///   • clean-only flag + prefer-explicit  → CLEAN (the collection beats the global toggle),
///   • no flag + prefer-explicit          → EXPLICIT,
///   • no flag + no preference (nil)      → UNCHANGED,
/// and each of those when the wanted edition is ABSENT from storage.
final class EditionPolicyTests: XCTestCase {

    private func song(_ json: String) -> IndexSong {
        try! JSONDecoder().decode(IndexSong.self, from: Data(json.utf8))
    }

    /// The owner's Big Sean shape: explicit song whose PRIMARY id is the clean cut, with the
    /// explicit edition resolved. `sng_72012147649f` / 1446744375 / 1440831608.
    private var bigSean: IndexSong {
        song(#"{"id":"sng_72012147649f","artist":"Big Sean","name":"IDFWU","explicit":true,"appleMusicId":"1446744375","appleMusicIdExplicit":"1440831608","appleMusicIdClean":"1446744375"}"#)
    }
    private let base = "sng_72012147649f"

    // MARK: The table

    func testCleanOnlyFlagBeatsPreferExplicit() {
        let d = EditionPolicy.decide(song: bigSean, collectionCleanOnly: true, preferExplicitRaw: true)
        XCTAssertNil(d.edition, "the primary already IS the clean cut — nothing to substitute")
        // …and with a DISTINCT clean id the substitution is clean, never explicit.
        let s = song(#"{"id":"sng_000000000001","artist":"A","name":"N","explicit":true,"appleMusicId":"E","appleMusicIdExplicit":"E","appleMusicIdClean":"C"}"#)
        let d2 = EditionPolicy.decide(song: s, collectionCleanOnly: true, preferExplicitRaw: true)
        XCTAssertEqual(d2.edition, .clean, "clean-only WINS over prefer-explicit")
        XCTAssertEqual(d2.catalogId, "C")
        XCTAssertEqual(d2.reason, .collectionCleanOnly)
        XCTAssertFalse(d2.allowsStoredFallback, "a restriction never falls back to another edition")
    }

    func testNoFlagPlusPreferExplicitPicksExplicit() {
        let d = EditionPolicy.decide(song: bigSean, collectionCleanOnly: false, preferExplicitRaw: true)
        XCTAssertEqual(d.edition, .explicit)
        XCTAssertEqual(d.catalogId, "1440831608")
        XCTAssertEqual(d.reason, .globalPreference)
        XCTAssertTrue(d.allowsStoredFallback, "a preference degrades gracefully")
    }

    func testNoFlagPlusNoPreferenceIsUnchanged() {
        let d = EditionPolicy.decide(song: bigSean, collectionCleanOnly: false, preferExplicitRaw: nil)
        XCTAssertEqual(d, .unchanged, "the tri-state nil never substitutes")
    }

    func testPreferCleanPicksClean() {
        let s = song(#"{"id":"sng_000000000002","artist":"A","name":"N","explicit":true,"appleMusicId":"E","appleMusicIdClean":"C"}"#)
        let d = EditionPolicy.decide(song: s, collectionCleanOnly: false, preferExplicitRaw: false)
        XCTAssertEqual(d.edition, .clean)
        XCTAssertEqual(d.catalogId, "C")
    }

    func testNoSubstitutionWhenThePrimaryAlreadyIsThatEdition() {
        let s = song(#"{"id":"sng_000000000003","artist":"A","name":"N","explicit":true,"appleMusicId":"E"}"#)
        XCTAssertEqual(EditionPolicy.decide(song: s, collectionCleanOnly: false, preferExplicitRaw: true),
                       .unchanged, "the base rip IS the explicit edition — no duplicate storage")
    }

    func testUnknownSongAndUnknownEditionNeverSubstitute() {
        XCTAssertEqual(EditionPolicy.decide(song: nil, collectionCleanOnly: true, preferExplicitRaw: true),
                       .unchanged, "studio / profile / unknown ids carry no explicitness")
        // Explicit song, clean edition unresolved: no catalog id ⇒ nothing may be acquired.
        let s = song(#"{"id":"sng_000000000004","artist":"A","name":"N","explicit":true,"appleMusicId":"E"}"#)
        let d = EditionPolicy.decide(song: s, collectionCleanOnly: true, preferExplicitRaw: nil)
        XCTAssertNil(d.catalogId)
        XCTAssertNil(EditionPolicy.lazyRipId(base: s.id, decision: d, isStored: { _ in false }),
                     "an edition we cannot NAME is never enqueued")
    }

    // MARK: The streaming half must agree — same condition, same id

    @MainActor
    func testStreamCandidatesAgreeWithTheDecision() {
        for pref in [true, false, nil] as [Bool?] {
            let d = EditionPolicy.decide(song: bigSean, collectionCleanOnly: false, preferExplicitRaw: pref)
            let c = AppleMusicProvider.streamCandidates(for: bigSean, preference: pref)
            if let want = d.catalogId {
                XCTAssertEqual(c.first?.id, want, "stream + storage must name the same id (pref \(String(describing: pref)))")
                XCTAssertEqual(c.first?.wantExplicit, d.edition == .explicit)
            } else {
                XCTAssertEqual(c.first?.id, bigSean.appleMusicId, "no substitution ⇒ the primary leads")
                XCTAssertNil(c.first?.wantExplicit)
            }
        }
    }

    // MARK: The storage ladder (edition-keyed, backward compatible)

    func testStorageLadderUnchangedIsTheBareBaseId() {
        XCTAssertEqual(EditionPolicy.storageIds(base: base, edition: nil, allowFallback: true), [base],
                       "no substitution ⇒ byte-for-byte today's lookup")
    }

    func testStorageLadderPreferenceFallsBackLegacyThenOtherEdition() {
        XCTAssertEqual(
            EditionPolicy.storageIds(base: base, edition: .explicit, allowFallback: true),
            ["\(base)_explicit", base, "\(base)_clean"],
            "wanted edition, then the LEGACY un-suffixed rip, then the other edition")
    }

    func testStorageLadderCleanOnlyIsSkipNotFallback() {
        XCTAssertEqual(
            EditionPolicy.storageIds(base: base, edition: .clean, allowFallback: false),
            ["\(base)_clean"],
            "a clean-only collection takes its edition or nothing")
    }

    func testResolveStoredEditionKeyedRoundTrip() {
        let d = EditionPolicy.decide(song: bigSean, collectionCleanOnly: false, preferExplicitRaw: true)
        let hit = EditionPolicy.resolveStored(base: base, decision: d,
                                              isStored: { $0 == "\(base)_explicit" })
        XCTAssertEqual(hit?.id, "\(base)_explicit")
        XCTAssertTrue(hit?.isWanted == true)
    }

    func testResolveStoredBackwardCompatibleWithALegacyRip() {
        // ONLY the pre-edition, un-suffixed rip exists. It must still play, and be reported as
        // a fallback so the caller lazily acquires the wanted edition.
        let d = EditionPolicy.decide(song: bigSean, collectionCleanOnly: false, preferExplicitRaw: true)
        let hit = EditionPolicy.resolveStored(base: base, decision: d, isStored: { $0 == base })
        XCTAssertEqual(hit?.id, base, "a legacy rip is never orphaned")
        XCTAssertFalse(hit?.isWanted == true)
    }

    func testResolveStoredFallsBackToTheOtherEditionRatherThanSilence() {
        let d = EditionPolicy.decide(song: bigSean, collectionCleanOnly: false, preferExplicitRaw: true)
        let hit = EditionPolicy.resolveStored(base: base, decision: d,
                                              isStored: { $0 == "\(base)_clean" })
        XCTAssertEqual(hit?.id, "\(base)_clean", "play the edition that exists rather than go silent")
        XCTAssertFalse(hit?.isWanted == true)
    }

    func testCleanOnlyNeverResolvesOntoAnExplicitFile() {
        let s = song(#"{"id":"sng_000000000005","artist":"A","name":"N","explicit":true,"appleMusicId":"E","appleMusicIdClean":"C"}"#)
        let d = EditionPolicy.decide(song: s, collectionCleanOnly: true, preferExplicitRaw: true)
        // Both the legacy base rip AND the explicit variant are on disk; neither may be used.
        let hit = EditionPolicy.resolveStored(base: s.id, decision: d,
                                              isStored: { $0 == s.id || $0 == "\(s.id)_explicit" })
        XCTAssertNil(hit, "skip-not-fallback: a clean-only row goes silent rather than play explicit")
    }

    // MARK: The lazy-rip gate

    func testLazyRipIdWantsTheMissingEditionOnly() {
        let d = EditionPolicy.decide(song: bigSean, collectionCleanOnly: false, preferExplicitRaw: true)
        XCTAssertEqual(EditionPolicy.lazyRipId(base: base, decision: d, isStored: { _ in false }),
                       "\(base)_explicit")
        XCTAssertNil(EditionPolicy.lazyRipId(base: base, decision: d,
                                             isStored: { $0 == "\(base)_explicit" }),
                     "already stored ⇒ nothing enqueued")
        XCTAssertNil(EditionPolicy.lazyRipId(base: base, decision: .unchanged, isStored: { _ in false }),
                     "no substitution ⇒ nothing enqueued")
    }
}
