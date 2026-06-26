import Foundation
import Observation
import SwitchboardSDK
import SwitchboardSuperpowered
#if os(iOS)
import AVFoundation   // iOS-only: AVAudioSession (Switchboard drives its own IO, we just set the category)
#endif

/// One-time Switchboard runtime bootstrap. Runs at app launch from BOTH platform app
/// delegates (iOS `AppDelegate`, macOS `MacAppDelegate`) — BEFORE the Mix tab can build its
/// engine — so `Switchboard.createEngine` always sees an initialized runtime. Idempotent: a
/// background relaunch (which re-enters `didFinishLaunching`) is a no-op. Reads the gitignored
/// `SwitchboardSecrets` (generated from <repo>/switchboard-credentials.json by
/// apple/scripts/setup-switchboard-secrets.sh — NEVER hardcode the secret in committed code).
enum SwitchboardRuntime {
    private static var didActivate = false

    /// Load the Superpowered extension + initialize Switchboard with the appID/appSecret and
    /// the Superpowered license. Cross-platform (no `#if os`): the same SDK initializes on
    /// iPhone, iPad, and Mac. Call from the main thread at launch (the delegates do).
    static func activate() {
        guard !didActivate else { return }
        didActivate = true
        SBSuperpoweredExtension.loadExtension()
        Switchboard.initialize(withConfig: [
            "appID": SwitchboardSecrets.appID,
            "appSecret": SwitchboardSecrets.appSecret,
            "extensions": [
                "Superpowered": ["superpoweredLicenseKey": SwitchboardSecrets.superpoweredLicenseKey],
            ],
        ])
    }
}

/// Cross-platform DJ mix engine — a SwiftUI-native port of the dj-app reference's
/// `MainAudioSystem`. Drives a two-deck Superpowered graph (see MixAudioGraph.json) entirely
/// by STRING node ids through `Switchboard.{setValue,callAction}`.
///
/// Runs on iPhone, iPad, AND Mac with NO `#if os` gating of the engine — the vendored
/// universal xcframeworks link on every platform and `RealTimeGraphRenderer` manages its own
/// audio IO (output-only, `microphoneEnabled:false`). The ONLY platform-gated code is the
/// genuinely iOS-only `AVAudioSession` category activation.
///
/// App-scoped (injected as an `@Observable` env object alongside `PlayerEngine`/`SetlistPlayer`)
/// so deck state — loaded track, rate, volume, effects, crossfader — survives tab switches. It
/// owns the `BurnStore` so a deck can resolve ONLY locally-burned files (`localURLForPlayback`),
/// holding each file's security scope while loaded and releasing it on reload / teardown.
///
/// Engine creation is LAZY (`ensureEngine`, on first use) — so the realtime audio graph is NOT
/// spun up at app launch, and it can never race the app-delegate's `Switchboard.initialize`.
@MainActor
@Observable
final class MixEngine {

    // MARK: Types

    /// The two decks. The rawValue is the node-id suffix in MixAudioGraph.json (playerA / gainA …).
    enum Deck: String, CaseIterable, Identifiable { case a = "A", b = "B"; var id: String { rawValue } }

    /// The four per-deck effects. The rawValue is the node-id prefix (compressorA, reverbA …).
    enum Effect: String, CaseIterable, Identifiable {
        case compressor, reverb, flanger, filter
        var id: String { rawValue }
        /// 2×2 grid label.
        var label: String {
            switch self {
            case .compressor: return "Comp"
            case .reverb:     return "Reverb"
            case .flanger:    return "Flanger"
            case .filter:     return "Filter"
            }
        }
        /// SF Symbol for the grid chip.
        var icon: String {
            switch self {
            case .compressor: return "waveform.path.ecg"
            case .reverb:     return "dot.radiowaves.left.and.right"
            case .flanger:    return "wind"
            case .filter:     return "line.3.horizontal.decrease.circle"
            }
        }
    }

    /// A deck's display payload — the view re-resolves artwork (via AppModel/`albumId`) +
    /// waveform from this, so the engine stays free of catalog/UI types.
    struct LoadedTrack: Equatable {
        let songId: String
        let title: String
        let artist: String
        let bpm: Double?
        let camelot: String?
        let key: String?
        let albumId: String?
    }

    // MARK: Tempo range (DECISION — see file header / PR notes)

    /// Superpowered time-stretches, so pitch holds across the whole range. 0.5…2.0 (vs. a
    /// tighter ±8% DJ fader) lets the user match this catalog's widely-varied BPMs; tighten by
    /// editing these constants.
    static let rateRange: ClosedRange<Double> = 0.5...2.0
    static let rateDefault: Double = 1.0

    // MARK: Observable state

    /// Per-deck observable state. The held security-scope `release` is NOT here — it lives in a
    /// separate `@ObservationIgnored` slot so swapping it never invalidates a view.
    private struct DeckState: Equatable {
        var loaded: LoadedTrack?
        var startMs: Int?
        var isPlaying = false
        var rate: Double = MixEngine.rateDefault
        var volume: Double = 1.0
        var compressor = false
        var reverb = false
        var flanger = false
        var filter = false

        func isEnabled(_ e: Effect) -> Bool {
            switch e {
            case .compressor: return compressor
            case .reverb:     return reverb
            case .flanger:    return flanger
            case .filter:     return filter
            }
        }
        mutating func set(_ e: Effect, _ on: Bool) {
            switch e {
            case .compressor: compressor = on
            case .reverb:     reverb = on
            case .flanger:    flanger = on
            case .filter:     filter = on
            }
        }
    }

    private var deckA = DeckState()
    private var deckB = DeckState()
    /// The bottom transport state (true iff EITHER deck is playing) — mirrors the reference's
    /// single `isPlaying` that `startPlayback`/`pausePlayback` toggled for both decks.
    private(set) var isRunning = false
    /// 0 = full A, 1 = full B. Centered by default so both loaded decks are audible at equal power.
    private(set) var crossfader: Double = 0.5
    /// True once the Switchboard graph exists. The view can gate controls on it.
    var isReady: Bool { engineID != nil }

    // MARK: Private

    /// The burn store — resolves a songId → on-disk burned file + its (held) security scope.
    @ObservationIgnored private let burns: BurnStore
    /// nil until `ensureEngine` builds the graph; the engine OBJECT then persists for the app's
    /// life (teardown only `stop`s it). Returned by `Switchboard.createEngine`.
    @ObservationIgnored private var engineID: String?
    /// The held BurnStore security-scope releases — one per deck. Kept OPEN while a deck has the
    /// file loaded; called on the next load / teardown. `@ObservationIgnored`: a closure swap
    /// must never invalidate a SwiftUI view (and closures aren't Equatable).
    @ObservationIgnored private var releaseA: (() -> Void)?
    @ObservationIgnored private var releaseB: (() -> Void)?

    init(burns: BurnStore) { self.burns = burns }   // graph is built lazily in ensureEngine.

    // MARK: - Lifecycle

    /// Build the two-deck graph from the bundled MixAudioGraph.json ON FIRST USE and start
    /// rendering. Idempotent — later calls (a slider move, a play) are no-ops once built. Safe to
    /// call from `MixView.task`/`onAppear` (`prepare()`) so the engine warms up when the tab opens.
    func ensureEngine() {
        guard engineID == nil else { return }
        #if os(iOS)
        activateAudioSession()   // genuinely iOS-only; Switchboard still owns the actual IO
        #endif
        guard let url = Bundle.main.url(forResource: "MixAudioGraph", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { assertionFailure("MixAudioGraph.json missing or invalid"); return }

        let result = Switchboard.createEngine(withConfig: config)
        guard let id = result.value as? String else { assertionFailure("createEngine failed"); return }
        engineID = id

        // Mirror MainAudioSystem: loop each deck (so a finished track doesn't dead-end the mix)
        // and declare A↔B tempo sync (benign without active beat-matching; enables it later).
        Switchboard.setValue(true, forKey: "isLoopingEnabled", onObject: playerID(.a))
        Switchboard.setValue(true, forKey: "isLoopingEnabled", onObject: playerID(.b))
        Switchboard.callAction(withObject: playerID(.a), actionName: "setNodeToSyncWith",
                               params: ["nodeID": playerID(.b)])

        // Push whatever state the UI already set (e.g. a slider moved before the tab built the
        // engine) so the graph matches the observable model, then start rendering.
        pushDeckState(.a)
        pushDeckState(.b)
        applyMixGains()
        Switchboard.callAction(withObject: id, actionName: "start", params: nil)
    }

    /// View-facing warm-up alias (call from `.task`/`.onAppear`).
    func prepare() { ensureEngine() }

    /// Stop rendering and RELEASE both held BurnStore security scopes. For explicit reset / app
    /// teardown — NOT tab switches (the engine is app-scoped; deck state + loaded files survive
    /// navigation). The engine object itself persists; a later `ensureEngine` is a no-op and
    /// play/start resumes it.
    func teardown() {
        pauseBoth()
        if let id = engineID { Switchboard.callAction(withObject: id, actionName: "stop", params: nil) }
        releaseA?(); releaseA = nil
        releaseB?(); releaseB = nil
        mutate(.a) { $0.loaded = nil; $0.startMs = nil }
        mutate(.b) { $0.loaded = nil; $0.startMs = nil }
    }

    // MARK: - Loading

    /// Load a LOCAL (burned) track onto a deck. Resolves the on-disk file through
    /// `BurnStore.localURLForPlayback` — which returns the url WITH its security scope already
    /// OPEN plus a `release` closure — and HOLDS `release` until the next load / teardown so the
    /// deck can read the file throughout playback. A non-loadable song (no burned file) is a
    /// no-op (degrade gracefully). `bpm` arms the beatgrid for tempo sync.
    func load(songId: String, title: String, artist: String, bpm: Double?,
              camelot: String?, key: String?, albumId: String?, on deck: Deck) {
        guard let handle = burns.localURLForPlaybackPreferringCut(forSong: songId) else { return }   // not local → skip
        ensureEngine()
        let player = playerID(deck)
        Switchboard.callAction(withObject: player, actionName: "open", params: ["path": handle.url.path])
        // Now that the NEW file is open, release the PREVIOUS file's scope and hold the new one.
        release(deck)?()
        setRelease(deck, handle.release)

        if let bpm {
            Switchboard.callAction(withObject: player, actionName: "setBeatGridInformation",
                                   params: ["originalBPM": bpm, "firstBeatMs": 0.0])
        }
        // A per-song CUT file (handle.isCut) already IS the song and plays from 0:00 — no offset.
        // The shared-album fallback (an analog whole-side mp3 with NO cut exported) has no confirmed
        // seek action in the vendored Superpowered headers, so it plays from the side's start; we
        // keep its startMs only for the UI's waveform window.  // TODO(seek) — only the no-cut case.
        let startMs = handle.isCut ? nil : burns.startMs(forSong: songId)
        mutate(deck) {
            $0.loaded = LoadedTrack(songId: songId, title: title, artist: artist,
                                    bpm: bpm, camelot: camelot, key: key, albumId: albumId)
            $0.startMs = startMs
        }
    }

    // MARK: - Transport (per deck + both)

    func play(_ deck: Deck) {
        ensureEngine()
        guard let id = engineID else { return }
        Switchboard.callAction(withObject: playerID(deck), actionName: "play", params: nil)
        Switchboard.callAction(withObject: id, actionName: "start", params: nil)   // ensure rendering
        mutate(deck) { $0.isPlaying = true }
        refreshTransport()
    }

    func pause(_ deck: Deck) {
        Switchboard.callAction(withObject: playerID(deck), actionName: "pause", params: nil)
        mutate(deck) { $0.isPlaying = false }   // leave the engine running — the other deck may play
        refreshTransport()
    }

    func togglePlay(_ deck: Deck) { state(deck).isPlaying ? pause(deck) : play(deck) }

    /// The bottom Play/Pause: start/stop BOTH decks together (mirrors the reference's
    /// startPlayback/pausePlayback).
    func playBoth() {
        ensureEngine()
        guard let id = engineID else { return }
        Switchboard.callAction(withObject: playerID(.a), actionName: "play", params: nil)
        Switchboard.callAction(withObject: playerID(.b), actionName: "play", params: nil)
        Switchboard.callAction(withObject: id, actionName: "start", params: nil)
        mutate(.a) { $0.isPlaying = true }
        mutate(.b) { $0.isPlaying = true }
        refreshTransport()
    }

    func pauseBoth() {
        Switchboard.callAction(withObject: playerID(.a), actionName: "pause", params: nil)
        Switchboard.callAction(withObject: playerID(.b), actionName: "pause", params: nil)
        mutate(.a) { $0.isPlaying = false }
        mutate(.b) { $0.isPlaying = false }
        refreshTransport()
    }

    func toggleAll() { isRunning ? pauseBoth() : playBoth() }

    // MARK: - Tempo / volume / effects / crossfader

    func setRate(_ rate: Double, on deck: Deck) {
        let r = min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        mutate(deck) { $0.rate = r }
        if isReady { Switchboard.setValue(r, forKey: "playbackRate", onObject: playerID(deck)) }
    }

    func setVolume(_ volume: Double, on deck: Deck) {
        mutate(deck) { $0.volume = min(max(volume, 0), 1) }
        applyMixGains()   // volume feeds the equal-power law — re-derive both gains
    }

    func setEffect(_ effect: Effect, enabled: Bool, on deck: Deck) {
        mutate(deck) { $0.set(effect, enabled) }
        if isReady {
            Switchboard.setValue(enabled, forKey: "enabled", onObject: effectNodeID(effect, deck))
        }
    }

    /// Equal-power crossfade. Subsumes the reference's `setCrossfader(value:volumeA:volumeB:)` —
    /// the engine OWNS the per-deck volumes, so the view passes only the fader position.
    func setCrossfader(_ value: Double) {
        crossfader = min(max(value, 0), 1)
        applyMixGains()
    }

    // MARK: - Readers (for the UI)

    func loaded(_ deck: Deck) -> LoadedTrack? { state(deck).loaded }
    func isPlaying(_ deck: Deck) -> Bool { state(deck).isPlaying }
    func rate(_ deck: Deck) -> Double { state(deck).rate }
    func volume(_ deck: Deck) -> Double { state(deck).volume }
    func isEnabled(_ effect: Effect, on deck: Deck) -> Bool { state(deck).isEnabled(effect) }

    // MARK: - Internals

    private func state(_ deck: Deck) -> DeckState { deck == .a ? deckA : deckB }

    /// Equal-power law (cosine), writing the resulting gains through the gain nodes and flipping
    /// `isMaster` to whichever deck the fader favours — exactly the reference's math, but driven
    /// from stored state so volume + crossfader stay consistent.
    private func applyMixGains() {
        guard isReady else { return }
        let v = Float(crossfader)
        let gainA = Float(deckA.volume) * cosf(.pi / 2 * v)
        let gainB = Float(deckB.volume) * cosf(.pi / 2 * (1 - v))
        Switchboard.setValue(gainA, forKey: "gain", onObject: gainID(.a))
        Switchboard.setValue(gainB, forKey: "gain", onObject: gainID(.b))
        Switchboard.setValue(crossfader <= 0.5, forKey: "isMaster", onObject: playerID(.a))
    }

    /// Re-assert a deck's rate + effect toggles onto the graph (used after `ensureEngine` builds
    /// it, so any pre-build UI changes land). Gains are pushed separately by `applyMixGains`.
    private func pushDeckState(_ deck: Deck) {
        let s = state(deck)
        Switchboard.setValue(s.rate, forKey: "playbackRate", onObject: playerID(deck))
        for e in Effect.allCases {
            Switchboard.setValue(s.isEnabled(e), forKey: "enabled", onObject: effectNodeID(e, deck))
        }
    }

    private func refreshTransport() { isRunning = deckA.isPlaying || deckB.isPlaying }

    private func mutate(_ deck: Deck, _ body: (inout DeckState) -> Void) {
        switch deck {
        case .a: body(&deckA)
        case .b: body(&deckB)
        }
    }

    private func setRelease(_ deck: Deck, _ r: (() -> Void)?) {
        switch deck {
        case .a: releaseA = r
        case .b: releaseB = r
        }
    }
    private func release(_ deck: Deck) -> (() -> Void)? { deck == .a ? releaseA : releaseB }

    // Node-id helpers — derived from the rawValues so they always match MixAudioGraph.json.
    private func playerID(_ d: Deck) -> String { "player\(d.rawValue)" }
    private func gainID(_ d: Deck) -> String { "gain\(d.rawValue)" }
    private func effectNodeID(_ e: Effect, _ d: Deck) -> String { "\(e.rawValue)\(d.rawValue)" }

    #if os(iOS)
    /// iOS-only: route to `.playback` so the mix plays through the speaker / in silent mode and
    /// keeps going in the background (the app already declares the `audio` UIBackgroundMode).
    /// Non-fatal on failure — Switchboard still manages its own IO. Guarded `#if os(iOS)` because
    /// `AVAudioSession` does not exist on macOS (the one platform difference the task calls out).
    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* non-fatal */ }
    }
    #endif
}
