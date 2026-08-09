import XCTest
@testable import PocketDJ

/// REGRESSION — "explicit works when I download the song, but streaming it before the
/// download is still falling back to the non-explicit version."
///
/// The song is Big Sean "I Don't F**k With You (feat. E-40)" (`sng_72012147649f`) exactly as
/// the LIVE catalog serves it: `explicit: true`, `appleMusicId` = 1446744375 — which is the
/// CLEAN edition — and NO `appleMusicIdExplicit`. That last part is the whole bug: the
/// resolved variant ids are rebuild-lossy, so any shipped index that lacks the carry-forward
/// serves this shape for the entire library.
///
/// From that row the owner's ▶ walks: `EditionPolicy.decide` → (the substitution collapses,
/// so `variant` is nil) → `PlaybackCoordinator.projectedSong` → `streamCandidates` → the id
/// MusicKit is asked for. These tests walk that SAME chain with the production functions at
/// every hop. They deliberately do NOT hand a fully-populated `IndexSong` to the pure
/// resolver: that test already existed, it passed throughout, and it is why this shipped.
@MainActor
final class ExplicitStreamEditionRegressionTests: XCTestCase {

    /// The live-catalog row, byte-shaped like the deployed index (no variant ids).
    private let liveRow = #"""
    {"id":"sng_72012147649f","albumId":"alb_d24141b798a6","artist":"Big Sean",
     "name":"I Don't F**k With You (feat. E-40)","explicit":true,"length":284397,
     "appleMusicId":"1446744375"}
    """#

    private func song(_ json: String) -> IndexSong {
        try! JSONDecoder().decode(IndexSong.self, from: Data(json.utf8))
    }

    /// A coordinator wired the way `PocketDJApp` wires it, from a one-song catalog.
    private func coordinator(catalog: [String: IndexSong]) -> PlaybackCoordinator {
        let c = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: RipsStore(), player: PlayerEngine()),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        c.sourceOfSong = { _ in Config.appleMusicSourceName }
        c.appleMusicIdOfSong = { catalog[$0]?.appleMusicId }
        c.variantAppleMusicIdOfSong = { id, v in catalog[id]?.appleMusicId(for: v) }
        c.editionsOfSong = { id in
            let s = catalog[id]
            return (s?.explicit, s?.appleMusicIdExplicit, s?.appleMusicIdClean)
        }
        return c
    }

    /// THE REGRESSION. Walk the owner's ▶ end to end and assert the id handed to MusicKit
    /// is not taken on trust: with the toggle ON, the primary must arrive CLAIMING to be
    /// explicit so `resolve` verifies `row.isExplicit` before playing it.
    ///
    /// Before the fix the claim was nil — no verification anywhere — and the clean cut
    /// streamed while the rip (the user's own, genuinely explicit file) played correctly.
    func testRowPlayStreamsAVerifiedExplicitEditionWhenVariantIdIsMissing() {
        let s = song(liveRow)
        let c = coordinator(catalog: [s.id: s])

        // Hop 1 — the decision the row ▶ computes (CollectionSongRow.doPlay).
        let decision = EditionPolicy.decide(song: s, collectionCleanOnly: false,
                                            preferExplicitRaw: true)
        // It COLLAPSES: `appleMusicId(for: .explicit)` falls back to the primary (the
        // `explicit == true` assumption) and a substitution to the id we already have is no
        // substitution. So the variant branch — the one with the edition-verified resolve —
        // is never entered. This is the step every prior test skipped past.
        XCTAssertNil(decision.edition, "the substitution must collapse for this row shape")

        // Hop 2 — the projection the coordinator actually streams.
        let projected = c.projectedSong(id: s.id, title: s.name, artist: s.artist,
                                        variant: decision.edition)
        XCTAssertEqual(projected.id, s.id, "no variant identity — the plain song streams")
        XCTAssertEqual(projected.explicit, true)
        XCTAssertNil(projected.appleMusicIdExplicit, "the live catalog has no variant id")

        // Hop 3 — the candidate MusicKit is asked for.
        let candidates = AppleMusicProvider.streamCandidates(for: projected, preference: true)
        XCTAssertEqual(candidates.map(\.id), ["1446744375"], "only the primary id is held")
        XCTAssertEqual(candidates.first?.wantExplicit, true,
                       "the primary must PROVE it is explicit — an existence-only check is "
                       + "what streamed the clean cut with the toggle on")
    }

    /// The claim is evidence-gated: a song the index does NOT say is explicit must keep the
    /// existence-only check. Otherwise every ordinary clean song in the library would fail a
    /// check it can never pass under prefer-explicit and stop streaming altogether.
    func testNonExplicitSongKeepsExistenceOnlyCheckUnderPreferExplicit() {
        let clean = song(#"{"id":"sng_72012147649a","artist":"A","name":"N","explicit":false,"appleMusicId":"P"}"#)
        XCTAssertNil(AppleMusicProvider.streamCandidates(for: clean, preference: true).first?.wantExplicit)

        let unclassified = song(#"{"id":"sng_72012147649b","artist":"A","name":"N","appleMusicId":"P"}"#)
        XCTAssertNil(AppleMusicProvider.streamCandidates(for: unclassified, preference: true).first?.wantExplicit)
    }

    /// The tri-state gate is untouched: preference UNSET ⇒ no claim, whatever the flag says.
    /// An index that merely learned a song is explicit must not start re-verifying — and
    /// possibly re-routing — a stream the user never asked to change.
    func testUnsetPreferenceAttachesNoClaim() {
        let s = song(liveRow)
        let candidates = AppleMusicProvider.streamCandidates(for: s, preference: nil)
        XCTAssertEqual(candidates.map(\.id), ["1446744375"])
        XCTAssertNil(candidates.first?.wantExplicit)
    }

    /// Symmetry: prefer-CLEAN on a row the index says is clean also makes the primary prove
    /// it, so a mis-minted primary can't stream an explicit cut to a clean-preferring user.
    func testPreferCleanClaimsTheCleanEditionOnACleanFlaggedPrimary() {
        let clean = song(#"{"id":"sng_72012147649c","artist":"A","name":"N","explicit":false,"appleMusicId":"P"}"#)
        XCTAssertEqual(AppleMusicProvider.streamCandidates(for: clean, preference: false),
                       [.init(id: "P", wantExplicit: false)])
    }

    /// When the variant id IS present the path is unchanged: a real substitution, a variant
    /// identity, and the edition-verified resolve branch. Pins that the fix above did not
    /// disturb the healthy-data case.
    func testResolvedVariantIdStillTakesTheVariantPath() {
        let s = song(#"""
        {"id":"sng_72012147649f","artist":"Big Sean","name":"IDFWU","explicit":true,
         "appleMusicId":"1446744375","appleMusicIdExplicit":"1440831608"}
        """#)
        let c = coordinator(catalog: [s.id: s])
        let decision = EditionPolicy.decide(song: s, collectionCleanOnly: false,
                                            preferExplicitRaw: true)
        XCTAssertEqual(decision.edition, .explicit)
        let projected = c.projectedSong(id: s.id, title: s.name, artist: s.artist,
                                        variant: decision.edition)
        XCTAssertEqual(projected.id, "sng_72012147649f_explicit")
        XCTAssertEqual(projected.appleMusicId, "1440831608")
    }
}
