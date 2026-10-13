import XCTest
@testable import PocketDJ

/// The In the Pocket feedback mic, against a FAKE recognizer: the live transcript is appended to
/// what was typed, a second tap stops, denied / unavailable degrade to a typed-only field with an
/// explanation, and an engine failure surfaces a message.
@MainActor
final class FeedbackDictationTests: XCTestCase {

    @MainActor
    private final class FakeEngine: FeedbackSpeechEngine {
        var isAvailable = true
        var auth: FeedbackDictationAuthorization = .authorized
        var startThrows = false
        private(set) var starts = 0
        private(set) var stops = 0
        private var onTranscript: (@MainActor (String) -> Void)?
        private var onFinish: (@MainActor (String?) -> Void)?

        func requestAuthorization() async -> FeedbackDictationAuthorization { auth }
        func start(onTranscript: @escaping @MainActor (String) -> Void,
                   onFinish: @escaping @MainActor (String?) -> Void) throws {
            if startThrows { throw NSError(domain: "fake", code: 1) }
            starts += 1
            self.onTranscript = onTranscript
            self.onFinish = onFinish
        }
        func stop() { stops += 1 }
        func say(_ text: String) { onTranscript?(text) }
        func finish(_ error: String?) { onFinish?(error) }
    }

    func testTranscriptAppendsToTypedTextLiveAndASecondTapStops() async {
        let engine = FakeEngine()
        let c = FeedbackDictationController(engine: engine)
        var field = "Good groove."
        XCTAssertTrue(c.isAvailable)
        await c.toggle(current: field) { field = $0 }
        XCTAssertEqual(c.state, .listening)
        XCTAssertEqual(engine.starts, 1)
        engine.say("the second")
        XCTAssertEqual(field, "Good groove. the second")
        engine.say("the second song dragged")   // partials carry the WHOLE transcript so far
        XCTAssertEqual(field, "Good groove. the second song dragged")
        await c.toggle(current: field) { field = $0 }
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(engine.stops, 1)
        engine.say("late partial after stop")
        XCTAssertEqual(field, "Good groove. the second song dragged", "nothing lands after stop")
        XCTAssertNil(c.explanation)
    }

    func testDeniedPermissionKeepsTypingWithAnExplanation() async {
        let engine = FakeEngine()
        engine.auth = .denied
        let c = FeedbackDictationController(engine: engine)
        var field = "typed"
        await c.toggle(current: field) { field = $0 }
        XCTAssertEqual(c.state, .denied)
        XCTAssertEqual(engine.starts, 0)
        XCTAssertEqual(field, "typed")
        XCTAssertNotNil(c.explanation)
        XCTAssertTrue(c.explanation?.contains("type") == true)
    }

    func testNoRecognizerHidesTheMic() async {
        let none = FeedbackDictationController(engine: nil)
        XCTAssertFalse(none.isAvailable)
        await none.toggle(current: "") { _ in XCTFail("no text without an engine") }
        XCTAssertEqual(none.state, .unavailable)
        let engine = FakeEngine()
        engine.isAvailable = false
        XCTAssertFalse(FeedbackDictationController(engine: engine).isAvailable)
        engine.isAvailable = true
        engine.auth = .unavailable
        let c = FeedbackDictationController(engine: engine)
        await c.toggle(current: "") { _ in }
        XCTAssertEqual(c.state, .unavailable)
    }

    func testEngineFailureAndCleanFinish() async {
        let engine = FakeEngine()
        let c = FeedbackDictationController(engine: engine)
        var field = ""
        await c.toggle(current: field) { field = $0 }
        engine.say("hello")
        engine.finish(nil)
        XCTAssertEqual(c.state, .idle, "the recognizer ending on its own returns to idle")
        XCTAssertEqual(field, "hello")
        await c.toggle(current: field) { field = $0 }
        engine.finish("Dictation stopped — try again.")
        XCTAssertEqual(c.state, .failed("Dictation stopped — try again."))
        XCTAssertEqual(c.explanation, "Dictation stopped — try again.")
        engine.startThrows = true
        await c.toggle(current: field) { field = $0 }
        XCTAssertEqual(c.state, .failed("Couldn't start dictation."))
    }

    func testJoin() {
        XCTAssertEqual(FeedbackDictationController.join("", "hi"), "hi")
        XCTAssertEqual(FeedbackDictationController.join("typed ", ""), "typed ")
        XCTAssertEqual(FeedbackDictationController.join("a ", "b"), "a b")
        XCTAssertEqual(FeedbackDictationController.join("line\n", "b"), "line\nb")
    }
}
