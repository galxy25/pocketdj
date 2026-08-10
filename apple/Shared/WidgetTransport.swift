import Foundation
import AppIntents

/// In-process bridge for the widget's transport buttons. An `AudioPlaybackIntent` triggered
/// from a widget runs in the **app's** process whenever the app is alive (which it is while
/// audio plays — the whole point of the widget), so the app wires these closures at launch
/// and the button drives real playback DIRECTLY with no latency. In the widget-extension
/// process (app fully quit) the closures are nil, and the intent falls back to the command
/// channel below.
@MainActor
final class WidgetPlaybackController {
    static let shared = WidgetPlaybackController()
    private init() {}
    /// Play/pause the current track (mirrors the lock-screen toggle command).
    var toggle: (() -> Void)?
    /// Advance / step back in the running set (mirrors the lock-screen ⏭/⏮).
    var next: (() -> Void)?
    var previous: (() -> Void)?
    /// Flip the CURRENT track's favorite (♥) state (mirrors the in-app `FavoriteToggle`).
    var toggleFavorite: (() -> Void)?
    /// Cycle the whole-session repeat mode off → all → one (mirrors the deck's repeat button).
    var cycleRepeat: (() -> Void)?
    /// Toggle live shuffle of the running set's upcoming tail (mirrors the deck's shuffle button).
    var toggleShuffle: (() -> Void)?
    /// 👍 / 👎 the CURRENT track as a recommendation (mirrors the in-app `RecFeedbackButtons`).
    /// These write the SAME `RecFeedbackStore` row every other surface writes — the widget is an
    /// entry point to one decision model, not a second one. Neither touches the transport.
    var acceptCurrent: (() -> Void)?
    var rejectCurrent: (() -> Void)?
}

/// Cross-process fallback: when an intent runs in the widget-extension process (the app was fully
/// quit), it can't reach the live `WidgetPlaybackController`, so it drops the command into the
/// shared App Group and the app drains it the moment it next becomes active.
///
/// ── WHY THIS IS A QUEUE AND NOT A SLOT, AND WHY VERDICTS CARRY THEIR TARGET ──────────────────
/// It used to be ONE slot with a 30-second expiry, applied to whatever was current at DRAIN time.
/// That is defensible for a transport command — a stale ⏯ arriving after a cold launch would jolt
/// playback, and losing one when a second is tapped on top of it costs nothing — but it is exactly
/// wrong for a 👍/👎:
///
///   · **Overwrite.** Thumbs-down then ⏭ replaced the thumbs-down. A lost transport tap is
///     obvious (nothing happened); a lost LEARNING signal is invisible — the listener saw the
///     glyph fill and the engine never heard it. So: an append-only queue, capped.
///   · **Expiry.** Thirty seconds is long enough to lose a verdict tapped on the lock screen just
///     before the phone was pocketed. Transport commands still expire; verdicts never do.
///   · **Drift.** Applying the verdict to whatever is playing at drain time files it against the
///     WRONG SONG — and after a cold launch the app cannot even resolve which tile the track came
///     from, so the verdict was dropped entirely. So a verdict carries its own `songId`, `scope`,
///     verdict and TAP timestamp; nothing about it is resolved at drain time.
///
/// The write is a read-modify-write on App Group `UserDefaults`, so two processes appending in the
/// same instant can in principle lose one. In practice only the WIDGET process ever appends (the
/// app dispatches through the in-process closure and never touches this channel), which is why the
/// simple encoding is enough — and it is strictly safer than the single slot it replaces.
enum WidgetCommandChannel {
    enum Command: String {
        case toggle, next, previous, favorite, cycleRepeat, toggleShuffle
    }

    /// One queued item. `kind` is a `Command` rawValue, or `verdictKind` for a 👍/👎.
    /// NEVER rename a shipped value — a queued item is read by whatever build drains it.
    struct Pending: Codable, Equatable, Sendable {
        var kind: String
        /// Epoch SECONDS, matching the transport channel's existing clock.
        var at: TimeInterval
        /// Verdict payload — nil for a transport command.
        var songId: String?
        var scope: String?
        /// `RecFeedbackStore.Verdict` rawValue ("accepted" / "rejected").
        var verdict: String?

        var command: Command? { Command(rawValue: kind) }
    }

    static let verdictKind = "recVerdict"
    /// Plenty for a burst of taps between two app wakes; the oldest are shed first.
    static let maxQueued = 32
    private static let queueKey = "pendingWidgetCommands"
    // The pre-queue single-slot keys, still read once on drain so a command queued by the previous
    // build is honoured after the update rather than silently stranded.
    private static let legacyKey = "pendingTransportCommand"
    private static let legacyAtKey = "pendingTransportCommandAt"

    static func send(_ c: Command, now: TimeInterval = Date().timeIntervalSince1970) {
        enqueue(Pending(kind: c.rawValue, at: now))
    }

    /// Queue a SELF-CONTAINED 👍/👎: which song, in which list, and when it was tapped.
    static func sendVerdict(songId: String, scope: String, verdict: String,
                            now: TimeInterval = Date().timeIntervalSince1970) {
        guard !songId.isEmpty, !scope.isEmpty else { return }
        enqueue(Pending(kind: verdictKind, at: now, songId: songId, scope: scope, verdict: verdict))
    }

    private static func enqueue(_ p: Pending) {
        guard let d = NowPlayingShared.defaults else { return }
        var queue = read(d)
        queue.append(p)
        if queue.count > maxQueued { queue.removeFirst(queue.count - maxQueued) }
        write(queue, d)
        // Wake the running app cross-process (a widget click doesn't foreground the app, so the
        // App-Group write alone would sit undrained until the next scene-activation — which is why
        // widget play/pause looked dead on macOS).
        WidgetCommandBridge.post()
    }

    /// Pop everything queued, oldest first.
    ///
    /// Transport commands older than `transportMaxAge` are dropped — a cold launch long after the
    /// tap must not jolt playback. VERDICTS ARE NEVER DROPPED BY AGE: a judgement the listener made
    /// is still what they think an hour later, and it already names the song it applies to, so
    /// there is nothing stale about it.
    static func drain(now: TimeInterval, transportMaxAge: TimeInterval = 30) -> [Pending] {
        guard let d = NowPlayingShared.defaults else { return [] }
        var queue = read(d)
        if let raw = d.string(forKey: legacyKey) {
            queue.insert(Pending(kind: raw, at: d.double(forKey: legacyAtKey)), at: 0)
            d.removeObject(forKey: legacyKey); d.removeObject(forKey: legacyAtKey)
        }
        d.removeObject(forKey: queueKey)
        return queue.filter {
            if $0.kind == verdictKind { return $0.songId?.isEmpty == false }
            guard $0.command != nil else { return false }
            return now - $0.at <= transportMaxAge
        }
    }

    private static func read(_ d: UserDefaults) -> [Pending] {
        guard let data = d.data(forKey: queueKey),
              let rows = try? JSONDecoder().decode([Pending].self, from: data) else { return [] }
        return rows
    }

    private static func write(_ rows: [Pending], _ d: UserDefaults) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        d.set(data, forKey: queueKey)
    }
}

/// A cross-process Darwin notification that wakes the RUNNING app the instant a widget drops a
/// transport command, so it drains immediately instead of waiting for the app to be foregrounded.
/// Darwin notifications are process-global on both iOS and macOS, so the widget-extension process
/// posts and the app process (which holds the audio) receives — no shared memory needed.
enum WidgetCommandBridge {
    private static let name = "com.levi.pocketdj.widget.command" as CFString

    /// Posted by the widget when a transport button is tapped.
    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name), nil, nil, true)
    }

    /// Set by the app; invoked on the main actor whenever a widget command arrives.
    @MainActor static var onCommand: (() -> Void)?

    /// Start listening (app side). Idempotent-enough for one app launch.
    static func observe() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let callback: CFNotificationCallback = { _, _, _, _, _ in
            Task { @MainActor in WidgetCommandBridge.onCommand?() }
        }
        CFNotificationCenterAddObserver(center, nil, callback, name, nil, .deliverImmediately)
    }
}

// MARK: - Widget transport intents (Button(intent:))

/// Route a widget transport command to the in-process controller, or the App Group fallback.
@MainActor
private func dispatchWidgetTransport(_ command: WidgetCommandChannel.Command) {
    let c = WidgetPlaybackController.shared
    let inProcess: (() -> Void)?
    switch command {
    case .toggle:        inProcess = c.toggle
    case .next:          inProcess = c.next
    case .previous:      inProcess = c.previous
    case .favorite:      inProcess = c.toggleFavorite
    case .cycleRepeat:   inProcess = c.cycleRepeat
    case .toggleShuffle: inProcess = c.toggleShuffle
    }
    // Which PROCESS an intent ran in is the crux of widget-button debugging: in the app
    // process the closure is wired (direct drive); in the widget process it's nil → the
    // App-Group command channel + Darwin-notification wake-up.
    NPLog.trace("intent \(command.rawValue) via \(inProcess != nil ? "in-process closure" : "command channel")")
    if let inProcess { inProcess() } else { WidgetCommandChannel.send(command) }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingToggleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetTransport(.toggle)
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Track"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetTransport(.next)
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingPreviousIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Track"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetTransport(.previous)
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingFavoriteIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Favorite"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetTransport(.favorite)
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingRepeatIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Repeat"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetTransport(.cycleRepeat)
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingShuffleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetTransport(.toggleShuffle)
        return .result()
    }
}

/// 👍 / 👎 ON WHAT IS PLAYING, from a widget or the lock screen.
///
/// `AudioPlaybackIntent` like the transport buttons rather than a plain `AppIntent`, for one
/// concrete reason: on iOS an `AudioPlaybackIntent` invoked from a widget is run IN THE APP'S
/// PROCESS whenever the app is alive — which it is while audio plays, i.e. exactly when these two
/// controls are meaningful. That is what lets the tap reach the live `RecFeedbackStore` directly
/// instead of round-tripping through the App Group, and it is why they never foreground the app.
///
/// ── THE COLD PATH IS THE ONE THAT HAD TO BE DESIGNED ────────────────────────────────────────
/// With the app fully quit the intent runs in the WIDGET's process, where there is no store, no
/// player and no idea which tile the track came from. So the intent does not ask: it reads the
/// snapshot the widget is already rendering — the same one that decided which thumb to draw
/// filled — and queues a verdict naming that `songId`, that `scope` and the tap time. The app
/// applies it verbatim on the next wake. Nothing is resolved at drain time, which is what stops a
/// judgement made on the lock screen from landing on whatever happens to be playing later.
///
/// They deliberately do NOT skip, pause, or otherwise touch playback — see `RecFeedbackButtons`.
@MainActor
private func dispatchWidgetVerdict(_ verdict: String) {
    let c = WidgetPlaybackController.shared
    let inProcess: (() -> Void)? = verdict == "accepted" ? c.acceptCurrent : c.rejectCurrent
    NPLog.trace("intent recVerdict \(verdict) via \(inProcess != nil ? "in-process closure" : "command channel")")
    if let inProcess { inProcess(); return }
    // WIDGET PROCESS: the snapshot is the only truth available, and it is exactly the truth the
    // button was drawn from. A snapshot with no scope means the running queue is not a
    // recommendation list, so there is nothing honest to record — the widget hides the pair in
    // that case, and this guard is the belt to that braces.
    let snap = NowPlayingShared.read()
    guard let songId = snap.songId, !songId.isEmpty, !snap.recScope.isEmpty else { return }
    WidgetCommandChannel.sendVerdict(songId: songId, scope: snap.recScope, verdict: verdict)
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingRecAcceptIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "More Like This"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetVerdict("accepted")
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingRecRejectIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Not For Me"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetVerdict("rejected")
        return .result()
    }
}
