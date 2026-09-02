import Foundation
import UserNotifications

/// Routes tapped MwF pushes into the app: the payload's `pdj.sessionId` lands on
/// `onOpenMwFSession`, which App.init wires to `friends.pendingOpenId` — RootView's
/// consume then opens the Games tab with the session screen pushed (cold launches
/// covered by the launch-task consume). Foreground pushes still show as banners.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Hop to the MainActor inside — the delegate callbacks aren't isolated.
    var onOpenMwFSession: ((String) -> Void)?

    /// Install as the notification-center delegate (App.init; harmless on platforms
    /// where no pushes ever arrive).
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    // tvOS's UserNotifications surface has no banners or tap-through responses —
    // the delegate installs fine but these callbacks don't exist there.
    #if !os(tvOS)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let pdj = userInfo["pdj"] as? [String: Any],
              (pdj["kind"] as? String) == "mwf",
              let sessionId = pdj["sessionId"] as? String, !sessionId.isEmpty else { return }
        onOpenMwFSession?(sessionId)
    }
    #endif
}
