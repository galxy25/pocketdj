import Foundation
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// APNs device-token registration — asked IN CONTEXT (after an MwF create/join), never
/// at launch. The app delegates (iOS/macOS) hand the token to `handleToken`, which
/// fires `onToken` (wired at app init to re-register every live MwF session). visionOS
/// has no delegate adaptor today, so it reports unsupported and rides the 4 s poll.
@MainActor
@Observable
final class PushRegistrationService {
    /// Delegates reach it like `TransferCoordinator.shared` (adaptors are instantiated
    /// by SwiftUI, so an instance can't be threaded in).
    static let shared = PushRegistrationService()

    private(set) var deviceTokenHex: String?
    private(set) var authorizationDenied = false
    /// Fires on every token (first receipt + rotation). Wired in App.init.
    @ObservationIgnored var onToken: ((String) -> Void)?

    /// Computed, NOT fenced state — a fenced stored property is the macOS-archive trap.
    var isSupported: Bool {
        #if os(iOS) || os(macOS)
        return true
        #else
        return false        // visionOS v1: polling only (no delegate adaptor exists)
        #endif
    }

    var platformString: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }

    /// Request notification authorization, then register for remote notifications.
    /// Returns whether authorization was granted (the token still arrives async via
    /// the delegate → `handleToken`).
    @discardableResult
    func requestAndRegister() async -> Bool {
        guard isSupported else { return false }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorizationDenied = !granted
        guard granted else { return false }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
        return true
    }

    /// Called by the app delegates with the raw APNs token.
    func handleToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceTokenHex = hex
        onToken?(hex)
    }
}
