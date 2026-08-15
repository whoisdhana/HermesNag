import Foundation
import HermesNagCore
import UserNotifications

/// Gentle tier of the habit ladder: a standard macOS notification.
///
/// The right first touch for something that fires 30 times a day — it appears
/// in the corner, you can ignore it, and it doesn't steal focus. Only if a
/// habit is ignored does it escalate to a panel.
enum Notifications {
    private static var authorized = false

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                authorized = granted
                if let error {
                    DebugLog.write("notification auth failed: \(error.localizedDescription)")
                } else {
                    DebugLog.write("notification auth: \(granted)")
                }
            }
    }

    @MainActor
    static func send(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // UNNotificationSound can't reference /System/Library/Sounds, so a
        // custom choice ships the banner silent and the app plays the sound
        // itself. "" = system default; "none" = silent.
        if Theme.shared.notificationCarriesSound {
            content.sound = .default
        } else {
            content.sound = nil
            Theme.shared.playAlert()
        }

        // Same identifier replaces the previous nudge for this habit rather
        // than stacking a pile of "drink water" cards in Notification Centre.
        let request = UNNotificationRequest(identifier: identifier,
                                            content: content,
                                            trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DebugLog.write("notification failed: \(error.localizedDescription)")
            }
        }
    }

    static func clear(identifier: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
