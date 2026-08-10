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
    /// 👍 / 👎 on the CURRENT track — the SYNC half of the recommendation tuning loop. They land
    /// in exactly the same `RecFeedbackStore` the tile's rows write to, so a decision made from
    /// the lock screen is already there when the tile is next opened. Neither one touches
    /// playback: accepting keeps playing, rejecting keeps playing.
    var acceptCurrent: (() -> Void)?
    var rejectCurrent: (() -> Void)?
}

/// Cross-process fallback: when a transport intent runs in the widget-extension process (the
/// app was fully quit), it can't reach the live `WidgetPlaybackController`, so it drops the
/// command into the shared App Group and the app drains it the moment it next becomes active.
enum WidgetCommandChannel {
    enum Command: String {
        case toggle, next, previous, favorite, cycleRepeat, toggleShuffle
        case recAccept, recReject
    }
    private static let key = "pendingTransportCommand"
    private static let atKey = "pendingTransportCommandAt"

    static func send(_ c: Command) {
        guard let d = NowPlayingShared.defaults else { return }
        d.set(c.rawValue, forKey: key)
        d.set(Date().timeIntervalSince1970, forKey: atKey)
        // Wake the running app cross-process (works even when a widget click doesn't foreground
        // the app — the App-Group write alone would sit undrained until the next scene-activation,
        // which is why widget play/pause looked dead on macOS).
        WidgetCommandBridge.post()
    }

    /// Pop the pending command if it's recent — a stale one (older than `maxAge`) is discarded
    /// so a cold launch long after the tap doesn't jolt playback unexpectedly.
    static func drain(now: TimeInterval, maxAge: TimeInterval = 30) -> Command? {
        guard let d = NowPlayingShared.defaults, let raw = d.string(forKey: key) else { return nil }
        let at = d.double(forKey: atKey)
        d.removeObject(forKey: key); d.removeObject(forKey: atKey)
        guard now - at <= maxAge, let c = Command(rawValue: raw) else { return nil }
        return c
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
    case .recAccept:     inProcess = c.acceptCurrent
    case .recReject:     inProcess = c.rejectCurrent
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

/// 👍 / 👎 on what is playing.
///
/// `AudioPlaybackIntent` like every other control here, and that choice is load-bearing rather
/// than cosmetic: it is what lets the button run WITHOUT foregrounding the app, which is the
/// whole point of putting the pair on the lock screen and in the car. They perform no transport
/// action at all — they only record — but they belong to the same playback session, so they ride
/// the same intent kind and the same in-process/command-channel dispatch as ⏯.
@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingRecAcceptIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "More Like This"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetTransport(.recAccept)
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
struct NowPlayingRecRejectIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Less Like This"
    @MainActor func perform() async throws -> some IntentResult {
        dispatchWidgetTransport(.recReject)
        return .result()
    }
}
