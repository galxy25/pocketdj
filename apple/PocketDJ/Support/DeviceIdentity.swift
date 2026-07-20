import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A stable, per-INSTALL device id — random, persisted, minted on first access.
///
/// Distinct from the PROFILE id (which follows the Apple ID across a user's devices, see
/// `ProfileStore`): this identifies THIS install of the app, so the per-user backend can tell
/// a user's iPhone from their Mac from their Vision Pro. Rides on every authenticated server
/// call as the `X-PocketDJ-Device` header (see `PDJIdentityHeaders`).
///
/// Persisted in `UserDefaults.standard` under `pdj.device.id`. On iOS/visionOS the first mint
/// seeds from `UIDevice.identifierForVendor` when available (already stable per-vendor per-device);
/// macOS has no `UIDevice`, so it uses a fresh random UUID. Either way the VALUE is frozen at first
/// access — even if the vendor id later changes — and only a `reset()` mints a new one.
///
/// Dependency-free and NOT `@MainActor`: a plain value source any thread can read.
enum DeviceIdentity {
    private static let defaultsKey = "pdj.device.id"

    /// This install's device id, minting + persisting one on first access.
    static var current: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let minted = mint()
        defaults.set(minted, forKey: defaultsKey)
        return minted
    }

    /// Forget the stored id so the NEXT `current` access mints a fresh one. Used by account
    /// deletion: a reinstalled / rejoined user presents to the backend as a brand-new install.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// The seed for a first mint: the vendor id on iOS/visionOS (stable per-vendor per-device)
    /// when available, else a fresh random UUID. macOS (no UIKit) always uses a random UUID.
    private static func mint() -> String {
        #if canImport(UIKit)
        if let vendor = UIDevice.current.identifierForVendor?.uuidString, !vendor.isEmpty {
            return vendor
        }
        #endif
        return UUID().uuidString
    }
}

/// The two forward-compatible per-user identity headers PocketDJ rides on every authenticated
/// server call (rip / sync / jukebox), ADDITIVE to the shared `Authorization: Bearer <token>`.
///
/// A current server that ignores unknown headers is unaffected; the per-user backend reads them
/// to attribute a call to a profile + install. `profileId` empty ⇒ the profile header is omitted
/// (there is no identity to attribute yet); the device header always rides.
enum PDJIdentityHeaders {
    static let profileHeader = "X-PocketDJ-Profile"
    static let deviceHeader = "X-PocketDJ-Device"

    /// Stamp the profile + device headers onto `request` (does NOT touch `Authorization`).
    static func apply(to request: inout URLRequest, profileId: String) {
        let pid = profileId.trimmingCharacters(in: .whitespaces)
        if !pid.isEmpty { request.setValue(pid, forHTTPHeaderField: profileHeader) }
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: deviceHeader)
    }
}
