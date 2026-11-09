import Foundation

enum SyncStatus: Equatable, Sendable {
    case disabled(reason: String)
    case waitingForFirstSync
    case running
    case healthy(lastSuccess: Date)
    /// Syncing has stopped for a reason that clears on its own, so nothing needs doing.
    case paused(Pause)
    /// A problem that will not clear on its own: the menu says what to do.
    case unhealthy(reason: String)

    enum Pause: Equatable, Sendable {
        case lowDataNetwork
        case volumeUnavailable
        /// The latest sync failed for the first time, so the next one may work.
        case retrying(failure: String)
    }

    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .waitingForFirstSync: "Waiting for first sync"
        case .running: "Syncing"
        case .healthy: "Healthy"
        case .paused(.lowDataNetwork): "Paused on a low-data network"
        case .paused(.volumeUnavailable): "Paused until the drive is reconnected"
        case .paused(.retrying): "Will try again"
        case .unhealthy: "Needs attention"
        }
    }

    /// The menu's first row. Needs attention and Will try again name the problem
    /// there, so it is the first thing the user reads.
    var headline: String {
        switch self {
        case let .unhealthy(reason), let .paused(.retrying(reason)): "\(title): \(reason)"
        default: title
        }
    }

    var symbolName: String {
        switch self {
        case .disabled: "slash.circle"
        case .waitingForFirstSync: "clock"
        case .running: "arrow.triangle.2.circlepath.circle"
        case .healthy: "checkmark.circle"
        case .paused(.lowDataNetwork): "wifi.exclamationmark"
        case .paused(.volumeUnavailable): "externaldrive.badge.xmark"
        case .paused(.retrying): "arrow.clockwise.circle"
        case .unhealthy: "exclamationmark.triangle.fill"
        }
    }

    /// What each state means, for the guided setup's summary of the icons.
    static let legend: [SyncStatus] = [
        .healthy(lastSuccess: .distantPast), .running, .waitingForFirstSync,
        .paused(.retrying(failure: "")), .paused(.lowDataNetwork), .paused(.volumeUnavailable),
        .unhealthy(reason: ""), .disabled(reason: ""),
    ]

    var meaning: String {
        switch self {
        case .healthy: "the latest sync worked, within the last 25 minutes."
        case .running: "a sync is copying changes right now."
        case .waitingForFirstSync: "setup is done and the first sync has not finished yet."
        case .paused(.retrying): "a sync failed, and the next one tries again."
        case .paused(.lowDataNetwork): "syncs wait for another network."
        case .paused(.volumeUnavailable): "the folder's drive is unplugged."
        case .unhealthy: "a sync failed in a way that will not fix itself, or none has worked for 25 minutes. The menu says why and what to do."
        case .disabled: "syncing is off until setup is finished or the configuration is fixed. The menu says what is missing."
        }
    }

    /// Plain-language detail shown under the title in the menu. Disabled and Needs
    /// attention explain themselves through their reason instead.
    var explanation: String? {
        switch self {
        case .waitingForFirstSync: "OneDrive sync is set up. The first sync starts soon,\nor choose Sync Now to start it."
        case .running: "Copying changes between OneDrive and your folder."
        case .healthy: "Your folder and OneDrive are in sync."
        case .paused(.retrying): "The latest sync failed. The next scheduled sync\ntries again, or choose Sync Now."
        case .paused(.lowDataNetwork): "Syncing resumes on its own on another network,\nor choose Sync Now to sync on this one."
        case .paused(.volumeUnavailable): "The external drive with your folder is not connected.\nSyncing resumes when the drive is reconnected."
        case .disabled, .unhealthy: nil
        }
    }

    var reason: String? {
        switch self {
        case let .disabled(reason), let .unhealthy(reason), let .paused(.retrying(reason)): reason
        case .waitingForFirstSync, .running, .healthy, .paused(.lowDataNetwork), .paused(.volumeUnavailable): nil
        }
    }
}

struct SyncRunRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case success, failure }

    var startedAt: Date
    var finishedAt: Date
    var outcome: Outcome
    var failureReason: String?
    var lastSuccessAt: Date?
}
