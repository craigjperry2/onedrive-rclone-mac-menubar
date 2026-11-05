import Foundation

enum SyncStatus: Equatable, Sendable {
    case disabled(reason: String)
    case waitingForFirstSync
    case running
    case healthy(lastSuccess: Date)
    case unhealthy(reason: String)

    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .waitingForFirstSync: "Waiting for first sync"
        case .running: "Syncing"
        case .healthy: "Healthy"
        case .unhealthy: "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .disabled: "pause.circle"
        case .waitingForFirstSync: "clock"
        case .running: "arrow.triangle.2.circlepath.circle"
        case .healthy: "checkmark.circle"
        case .unhealthy: "exclamationmark.triangle"
        }
    }

    /// What each state means, for the guided setup's summary of the icons.
    static let legend: [SyncStatus] = [.healthy(lastSuccess: .distantPast), .running, .waitingForFirstSync, .unhealthy(reason: ""), .disabled(reason: "")]

    var meaning: String {
        switch self {
        case .healthy: "the latest sync worked, within the last 25 minutes."
        case .running: "a sync is copying changes right now."
        case .waitingForFirstSync: "setup is done and the first sync has not finished yet."
        case .unhealthy: "a sync failed, or none has worked for 25 minutes. The menu says why and what to do."
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
        case .disabled, .unhealthy: nil
        }
    }

    var reason: String? {
        switch self {
        case let .disabled(reason), let .unhealthy(reason): reason
        case .waitingForFirstSync, .running, .healthy: nil
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
