import XCTest
@testable import PocketDJ

/// `NowPlayingPanel.isVisible` — the gate the TV Now Playing tab routes on: when it is TRUE the
/// tab mounts the sequencer's card (`TVSetlistNowPlayingCard`), so the gate deciding correctly
/// for a running collection is what makes the field "blank Now Playing during an external Apple
/// Music set" (device tvos-8E34293E) render. The card is backend-agnostic — it reads
/// `sequencer.queue[index]` and the coordinator clock — so a burned/local set and an external
/// AM stream both reach it through the same TRUE gate. These pin the gate itself (a layout
/// regression in the card is a tvOS on-device check; this guards the routing that shows it).
@MainActor
final class NowPlayingGateTests: XCTestCase {
    private var held: [Any] = []
    override func tearDown() { held = []; super.tearDown() }

    private func makeSequencer() -> SetlistPlayer {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let player = PlayerEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-npgate-burns-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let burns = BurnStore(rips: rips, fileURL: url)
        let coordinator = PlaybackCoordinator(
            ripProvider: RipServerPlaybackProvider(rips: rips, player: player),
            appleMusic: AppleMusicPlaybackProvider(provider: AppleMusicProvider()))
        let seq = SetlistPlayer(player: player, rips: rips, burns: burns, coordinator: coordinator)
        held.append(contentsOf: [rips, player, burns, coordinator, seq])
        return seq
    }

    private func makeMix() -> MixEngine {
        let rips = RipsStore(ripsBase: URL(string: "https://rips.test")!,
                             session: URLSession(configuration: .ephemeral))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdj-npgate-mix-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let mix = MixEngine(burns: BurnStore(rips: rips, fileURL: url))
        held.append(mix)
        return mix
    }

    /// A running collection with an idle mix ⇒ the panel is visible, so the TV tab shows the
    /// sequencer card (the burned/local set case — no external streaming involved).
    func testRunningSequencerIdleMixIsVisible() {
        let seq = makeSequencer()
        let mix = makeMix()
        XCTAssertFalse(NowPlayingPanel.isVisible(sequencer: seq, mix: mix), "nothing running yet")
        seq.play([.init(id: "sng_1", title: "One", artist: "A")])
        XCTAssertTrue(seq.isRunning)
        XCTAssertTrue(NowPlayingPanel.isVisible(sequencer: seq, mix: mix),
                      "a running collection routes the TV tab to the sequencer card")
    }

    /// Nothing running ⇒ not visible (the tab falls through to the empty state).
    func testNothingRunningIsNotVisible() {
        XCTAssertFalse(NowPlayingPanel.isVisible(sequencer: makeSequencer(), mix: makeMix()))
    }
}
