import Foundation
import UserNotifications

/// A problem worth a macOS notification. Each kind has a fixed identifier, so a
/// newer notification of the same kind replaces the older one in Notification Center.
struct SyncNotification: Equatable, Sendable {
    let id: String
    let title: String
    let body: String

    static let reviewHint = "Open OneDrive Sync in the menu bar to review recent activity."

    static func syncFailed(at date: Date) -> SyncNotification {
        SyncNotification(
            id: "sync-failed",
            title: "OneDrive sync needs attention",
            body: "The scheduled OneDrive sync at \(date.formatted(date: .omitted, time: .shortened)) could not finish. \(reviewHint)"
        )
    }

    static func configurationUnusable(_ reason: String) -> SyncNotification {
        SyncNotification(
            id: "configuration-unusable",
            title: "OneDrive sync needs attention",
            body: "OneDrive sync has stopped because its configuration can no longer be used: \(reason.replacingOccurrences(of: "\n", with: " ")) \(reviewHint)"
        )
    }

    static func lowDataNetwork(skips: Int) -> SyncNotification {
        SyncNotification(
            id: "low-data-network",
            title: "OneDrive has not synced",
            body: "The last \(skips) scheduled syncs were skipped because this Mac is on a low-data or metered network. Syncing resumes on a normal network, or choose Sync Now in the menu bar."
        )
    }
}

@MainActor
protocol SyncNotifying {
    func requestAuthorization()
    func post(_ notification: SyncNotification)
}

struct UserNotifier: SyncNotifying {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notification: SyncNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }
}
