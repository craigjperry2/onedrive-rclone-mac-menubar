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
