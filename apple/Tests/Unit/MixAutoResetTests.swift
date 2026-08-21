import XCTest
import AVFoundation
@testable import PocketDJ

/// Bug fix "two songs at once": starting an Auto Mix must take over BOTH decks — stop/park an
/// already-playing deck and return EVERY per-deck parameter (volume/boost, effects + strengths,
/// stem toggles, loops, gain, cue/PFL state) to default before the auto queue loads. Manual-mix
/// deck starts stay untouched (`load` keeps its documented "a load doesn't clear effects"
/// contract). Plus the `loadAuto` hardening: a queue item whose burned file vanished must not
/// claim a deck or stamp a transition duration.
@MainActor
final class MixAutoResetTests: XCTestCase {

    private func makeEngine() -> MixEngine {
        MixEngine(burns: try! MixBurnFixture.burnStore())
    }

    private func loadable(_ id: String) -> MixLoadable {
        MixLoadable(songId: id, title: "T-\(id)", artist: "A", bpm: 120,
                    camelot: "8A", key: nil, albumId: nil, lengthMs: 2_000)
    }

    private func item(_ id: String, durationMs: Int = 180_000) -> MixEngine.AutoMixItem {
        .init(loadable: loadable(id), durationMs: durationMs)
    }

    private func loadBurned(_ id: String, on deck: MixEngine.Deck, engine e: MixEngine) {
        e.load(songId: id, title: "T-\(id)", artist: "A", bpm: 120,
               camelot: nil, key: nil, albumId: nil, on: deck)
    }

    /// Dirty EVERYTHING dirtiable on a deck (the full parameter surface the reset must cover).
    private func dirtyDeck(_ deck: MixEngine.Deck, engine e: MixEngine) {
        e.setVolume(1.8, on: deck)                       // gain boost territory (>100%)
        for fx in MixEngine.Effect.allCases {
            e.setEffect(fx, enabled: true, on: deck)
            e.setEffectStrength(fx, 0.9, on: deck)
        }
        e.setCued(true, on: deck)                        // pre-fader PFL send (survives resetDeck!)
        e.setCueVolume(0.3, on: deck)
        e.setRate(1.5, on: deck)
        e.setPitch(3, on: deck)
        e.toggleStemMute("vocals", on: deck)
        e.setLoop(deck, on: true)
    }

    /// Field-by-field `DeckState()` default equality (the parameter surface, via the readouts).
    private func assertDeckAtDefaults(_ deck: MixEngine.Deck, engine e: MixEngine,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(e.volume(deck), 1.0, "volume", file: file, line: line)
        XCTAssertEqual(e.rate(deck), 1.0, "rate", file: file, line: line)
        XCTAssertEqual(e.pitch(deck), 0.0, "pitch", file: file, line: line)
        for fx in MixEngine.Effect.allCases {
            XCTAssertFalse(e.isEnabled(fx, on: deck), "\(fx) enabled", file: file, line: line)
            XCTAssertEqual(e.strength(fx, on: deck), 0.5, accuracy: 1e-9, file: file, line: line)
        }
        XCTAssertFalse(e.stemModeOn(deck), "stem mode", file: file, line: line)
        XCTAssertFalse(e.isStemMuted("vocals", on: deck), "stem mute", file: file, line: line)
        XCTAssertFalse(e.cued(deck), "cue/PFL send", file: file, line: line)
        XCTAssertEqual(e.cueVolume(deck), 1.0, "cue volume", file: file, line: line)
        XCTAssertFalse(e.loopOn(deck), "loop", file: file, line: line)
        XCTAssertEqual(e.loopUnits(deck), 2, "loop units", file: file, line: line)
    }

    /// THE bug: deck B playing a manual track + a dirtied board, then an Auto Mix with a
    /// ONE-item queue (the old `autoQueue.count > 1` gap left deck B untouched) — deck B must
    /// STOP (state AND player node) and every parameter on BOTH decks must return to default,
    /// including the cue/PFL send that a plain `resetDeck` deliberately keeps.
    func testStartAutoMixResetsEveryDeckParamAndStopsDeckB() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")

        loadBurned("b", on: .b, engine: e)
        e.play(.b)
        XCTAssertTrue(e.isPlaying(.b))
        dirtyDeck(.b, engine: e)
        dirtyDeck(.a, engine: e)
        e.setLead(.b)
        e.setCrossfader(0.8)

        e.startAutoMix([item("x")], shuffled: false, lead: 15, fade: 3)   // ONE-item queue

        XCTAssertTrue(e.autoMixing)
        XCTAssertFalse(e.isPlaying(.b), "deck B must stop — no two songs at once")
        XCTAssertFalse(e.playerNodeIsPlayingForTesting(.b), "the NODE really stopped, not just intent")
        XCTAssertNil(e.loaded(.b), "the leftover manual track is ejected")
        XCTAssertEqual(e.loaded(.a)?.songId, "x", "the auto queue owns deck A now")
        XCTAssertTrue(e.isPlaying(.a))
        assertDeckAtDefaults(.a, engine: e)
        assertDeckAtDefaults(.b, engine: e)
        XCTAssertNil(e.leadDeck, "lead role cleared")
        XCTAssertEqual(e.crossfader, 0.0, accuracy: 1e-9, "auto starts hard-A")
        e.teardown()
    }

    /// The parked-player watchdog must find NOTHING to resurrect on deck B after the auto
    /// take-over (its `isPlaying` intent is false, so the heal pass skips it).
    func testWatchdogDoesNotResurrectDeckBAfterAutoStart() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")

        loadBurned("b", on: .b, engine: e)
        e.play(.b)
        e.startAutoMix([item("x")], shuffled: false, lead: 15, fade: 3)
        XCTAssertFalse(e.isPlaying(.b))

        e.healParkedPlayersForTesting()               // the tick's heal pass

        XCTAssertFalse(e.isPlaying(.b), "no intent — nothing to heal")
        XCTAssertFalse(e.playerNodeIsPlayingForTesting(.b), "deck B stays silent")
        XCTAssertTrue(e.isPlaying(.a), "the auto deck keeps playing")
        e.teardown()
    }

    /// Regression guard for the untouched half: a MANUAL deck load keeps volume/effects/cue
    /// (the documented "a load doesn't clear effects" contract) while rate/pitch/stems reset.
    func testManualLoadKeepsEffectsAndVolume() throws {
        let e = makeEngine()
        e.ensureEngine()
        try XCTSkipUnless(e.isReady, "no audio device on this test host")

        loadBurned("a", on: .a, engine: e)
        e.setVolume(0.3, on: .a)
        e.setEffect(.reverb, enabled: true, on: .a)
        e.setEffectStrength(.reverb, 0.9, on: .a)
        e.setCued(true, on: .a)
        e.setRate(1.5, on: .a)
        e.setPitch(3, on: .a)

        loadBurned("y", on: .a, engine: e)            // manual load — NOT an auto take-over

        XCTAssertEqual(e.loaded(.a)?.songId, "y")
        XCTAssertEqual(e.volume(.a), 0.3, "volume survives a manual load")
        XCTAssertTrue(e.isEnabled(.reverb, on: .a), "effects survive a manual load")
        XCTAssertEqual(e.strength(.reverb, on: .a), 0.9, accuracy: 1e-9)
        XCTAssertTrue(e.cued(.a), "the cue send survives a manual load")
        XCTAssertEqual(e.rate(.a), 1.0, "tempo resets on load (as today)")
        XCTAssertEqual(e.pitch(.a), 0.0, "pitch resets on load (as today)")
        XCTAssertFalse(e.stemModeOn(.a), "stem mode resets on load (as today)")
        e.teardown()
    }

    /// A queue item whose burned file is gone must not claim a deck: `startAutoMix` drops it and
    /// loads the next LOADABLE item (without stamping the failed item's duration); a queue of
    /// ONLY unloadable items ends cleanly (no mix, no phantom 3-minute transition clock).
    func testLoadAutoFailureSkipsItemWithoutStampingDuration() throws {
        let e = makeEngine()
        e.ensureEngine()

        e.startAutoMix([item("ghost-no-burn", durationMs: 111_000), item("x", durationMs: 222_000)],
                       shuffled: false, lead: 15, fade: 3)

        XCTAssertTrue(e.autoMixing, "the loadable item carries the mix")
        XCTAssertEqual(e.loaded(.a)?.songId, "x", "the unloadable leading item is dropped")
        XCTAssertEqual(e.autoQueueCountForTesting, 1, "the ghost item left the queue")
        XCTAssertEqual(e.autoDeckDurationMsForTesting(.a), 222_000,
                       "deck A's clock is the LOADED item's duration — never the ghost's")

        e.stopAutoMix()
        e.startAutoMix([item("ghost-no-burn", durationMs: 111_000)], shuffled: false, lead: 15, fade: 3)
        XCTAssertFalse(e.autoMixing, "ALL unloadable ⇒ no mix (the empty-queue guard's twin)")
        XCTAssertNil(e.loaded(.a), "nothing claimed a deck")
        XCTAssertNil(e.autoDeckDurationMsForTesting(.a), "no duration stamped for a failed load")
        e.teardown()
    }
}
