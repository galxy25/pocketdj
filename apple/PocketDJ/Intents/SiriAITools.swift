import AppIntents

// ── SIRI AI TOOLS (Siri AI Developer Preview, iOS / macOS / visionOS 27.3) ─────────────────────
//
// Conforming an intent to `ToolIntent` makes it a tool Siri AI can call from natural language
// ("add Make Me Proud to Workout", "mute the vocals") — no fixed phrase. Apple's spelling is the
// `@AppIntent(.tool)` macro, whose only expansion is this same conformance; it's written out as
// extensions here because `ToolIntent` is `@available(iOS 27.3, …)` while these intents deploy
// back to iOS 18 (the macro on the iOS-18 struct fails "only available in iOS 27.3 or newer").
//
// COMPILE GATE: `canImport(AppIntents, _version: 301.2)`. The release Xcode 27.2 SDK ships
// AppIntents 301.1.16 and has no `ToolIntent`; the Xcode 27.3 beta SDK ships 301.2.7.2 and does.
// The App Store build (Xcode 27.2) therefore compiles none of this — its intents still work through
// App Shortcuts phrases, Shortcuts and Spotlight — and the internal-TestFlight build (Xcode 27.3
// beta) compiles it in. (The Swift compiler is 6.4.2 in both, so `#if compiler(…)` can't tell them
// apart, and `SiriEvaluations` lives in the platform's Developer frameworks, invisible to an app
// target's `canImport`.) tvOS has no ToolIntent at all.
//
// WHICH intents are tools (per "Bringing custom actions and content to Siri"):
//  • YES — the custom actions: add to collection (both), Mix Mode, mute/unmute stem, play my
//    pocket, play/shuffle a collection, auto-mix start/pause/resume, create a pocket.
//  • NO — intents that already conform to a Siri-supported schema (`AudioSchema27`'s
//    `.audio.playAudio` / `.audio.addToPlaylist`, `SearchLibraryIntent`'s `.system.search`), the
//    Spotlight `OpenIntent`s (navigation, not an action), and the per-kind Play/Shuffle
//    Playlist/Pocket intents, kept only so saved shortcuts keep working (the collection intents
//    supersede them — two tools for one action only confuse the planner).

#if canImport(AppIntents, _version: 301.2) && !os(tvOS)

@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension AddSongToCollectionIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension AddCurrentSongToCollectionIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension SetMixModeIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension MuteStemIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension UnmuteStemIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension PlayCollectionIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension ShuffleCollectionIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension PlayPocketForNowIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension StartAutoMixIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension PauseAutoMixIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension ResumeAutoMixIntent: ToolIntent {}
@available(iOS 27.3, macOS 27.3, visionOS 27.3, *)
extension CreatePocketIntent: ToolIntent {}

/// True in the build that carries the Siri AI tools (diagnostics / tests read it).
let siriAIToolsCompiledIn = true

#else

let siriAIToolsCompiledIn = false

#endif
