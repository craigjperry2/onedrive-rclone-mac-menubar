import AppKit
import Foundation
import UserNotifications

/// A macOS notification about syncing. Each kind has a fixed identifier, so a
/// newer notification of the same kind replaces the older one in Notification Center.
struct SyncNotification: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    /// Buttons offered next to the notification. Clicking the notification itself
    /// opens the status menu.
    var actions: [Action] = []

    /// Notification buttons run at once, without a confirmation, so only actions
    /// that cannot lose files belong here. Resync can overwrite files, so it stays
    /// behind the menu's confirmation and is never a button.
    enum Action: String, CaseIterable, Sendable {
        case syncNow = "sync-now"
        case showLog = "show-log"

        var title: String {
            switch self {
            case .syncNow: "Sync Now"
            case .showLog: "Show Log"
            }
        }
    }

    /// The category that shows this notification's buttons.
    var categoryID: String { Self.categoryID(for: actions) }

    static func categoryID(for actions: [Action]) -> String { actions.map(\.rawValue).joined(separator: "+") }

    /// Every combination of buttons, so that each one's category is registered
    /// before any notification is posted.
    static var actionSets: [[Action]] {
        Action.allCases.reduce([[]]) { sets, action in sets + sets.map { $0 + [action] } }.filter { !$0.isEmpty }
    }

    static let reviewHint = "Open OneDrive Sync in the menu bar to review recent activity."

    /// The body names the problem (the failure reason, from `SyncProblem`) and the
    /// fix the menu offers for it. Sync Now is a button only when trying again is
    /// that fix; other fixes need the menu, where they ask for confirmation.
    static func syncFailed(reason: String, transcriptLines: [String], at date: Date) -> SyncNotification {
        let problem = reason.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let stopped = "\(problem). The scheduled sync at \(date.formatted(date: .omitted, time: .shortened)) stopped."
        let fix = MenuBarView.fix(for: .unhealthy(reason: reason), transcriptLines: transcriptLines) ?? .tryAgain
        let next = switch fix {
        case .tryAgain:
            ""
        case let .allowDeletes(side):
            " It did not delete them from \(side.otherSide) too. Open OneDrive Sync in the menu bar and choose Allow Deletes and Sync… if you meant to delete them, or Resync… to copy them back."
        default:
            fix.actionTitle.map { " Open OneDrive Sync in the menu bar and choose \($0)" } ?? " " + fix.advice.replacingOccurrences(of: "\n", with: " ")
        }
        let actions: [Action] = fix == .tryAgain ? [.syncNow, .showLog] : [.showLog]
        return SyncNotification(id: "sync-failed", title: "OneDrive sync needs attention", body: stopped + next, actions: actions)
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
            body: "The last \(skips) scheduled syncs were skipped because this Mac is on a low-data or metered network. Syncing resumes on a normal network, or choose Sync Now.",
            actions: [.syncNow]
        )
    }

    static let syncRecovered = SyncNotification(
        id: "sync-recovered",
        title: "OneDrive sync is working again",
        body: "The latest sync finished, so your folder and OneDrive are in sync."
    )
}

@MainActor
protocol SyncNotifying {
    /// Asks to show notifications. Their Sync Now button calls `syncNow`.
    func start(syncNow: @escaping @MainActor () -> Void)
    func post(_ notification: SyncNotification)
}

/// Posts notifications and answers them: Sync Now calls back into the app, Show
/// Log opens rclone's latest output, and clicking a notification opens the status menu.
@MainActor
final class UserNotifier: NSObject, SyncNotifying, UNUserNotificationCenterDelegate {
    private let logFile: URL
    private var syncNow: (@MainActor () -> Void)?

    init(logFile: URL = AppPaths().latestTranscriptFile) {
        self.logFile = logFile
        super.init()
        // Set while the app launches, so a click that launched the app still arrives.
        UNUserNotificationCenter.current().delegate = self
    }

    func start(syncNow: @escaping @MainActor () -> Void) {
        self.syncNow = syncNow
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(Set(SyncNotification.actionSets.map { actions in
            UNNotificationCategory(
                identifier: SyncNotification.categoryID(for: actions),
                actions: actions.map { UNNotificationAction(identifier: $0.rawValue, title: $0.title) },
                intentIdentifiers: []
            )
        }))
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notification: SyncNotification) {
        let center = UNUserNotificationCenter.current()
        // Once syncing works again, earlier problems and their buttons are out of date.
        if notification == .syncRecovered { center.removeAllDeliveredNotifications() }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = notification.categoryID
        center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let actionIdentifier = response.actionIdentifier
        await respond(to: actionIdentifier)
    }

    // macOS hides notifications from the active app unless it asks to show them,
    // and this app is active after its Resync confirmation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func respond(to actionIdentifier: String) {
        switch SyncNotification.Action(rawValue: actionIdentifier) {
        case .syncNow: syncNow?()
        case .showLog: NSWorkspace.shared.open(logFile)
        case nil where actionIdentifier == UNNotificationDefaultActionIdentifier: openStatusMenu()
        case nil: break
        }
    }

    /// SwiftUI's MenuBarExtra cannot open its menu itself, so this clicks the
    /// status item's button. Without one it shows the log instead.
    private func openStatusMenu() {
        let button = NSApp.windows.lazy.compactMap { $0.contentView.flatMap(Self.statusBarButton(in:)) }.first
        guard let button else {
            NSWorkspace.shared.open(logFile)
            return
        }
        // Deferred, so the menu's tracking loop does not hold up the notification response.
        DispatchQueue.main.async { button.performClick(nil) }
    }

    private static func statusBarButton(in view: NSView) -> NSStatusBarButton? {
        view as? NSStatusBarButton ?? view.subviews.lazy.compactMap(statusBarButton(in:)).first
    }
}
