import Foundation

/// One entry in the recent activity history: a run of rclone, or a scheduled sync
/// that did not run. Consecutive skips for the same reason share one entry.
struct SyncActivity: Codable, Equatable, Sendable {
    enum Outcome: Codable, Equatable, Sendable {
        case succeeded
        case failed(reason: String)
        case skipped(SkipReason)
    }

    enum Trigger: String, Codable, Sendable { case scheduled, syncNow, resync }

    var trigger: Trigger
    var outcome: Outcome
    var startedAt: Date
    /// When the run finished, or when the latest skip of a repeated skip happened.
    var finishedAt: Date
    /// How many consecutive scheduled syncs a skip entry stands for.
    var count = 1

    var isSkip: Bool {
        if case .skipped = outcome { true } else { false }
    }
}

enum SkipReason: String, Codable, Sendable {
    case setupRequired, configurationUnusable, lowDataNetwork, previousSyncRunning

    var explanation: String {
        switch self {
        case .setupRequired: "OneDrive sync is not set up yet."
        case .configurationUnusable: "The OneDrive sync configuration could not be used."
        case .lowDataNetwork: "The Mac was on a low-data or metered network."
        case .previousSyncRunning: "The previous sync was still running."
        }
    }
}

/// The recent activity history, oldest first, bounded to the latest entries.
struct ActivityLog: Codable, Equatable, Sendable {
    static let capacity = 100

    private(set) var entries: [SyncActivity] = []

    mutating func record(_ activity: SyncActivity) {
        if case .skipped = activity.outcome, var last = entries.last, last.outcome == activity.outcome {
            last.finishedAt = activity.finishedAt
            last.count += 1
            entries[entries.count - 1] = last
            return
        }
        entries.append(activity)
        entries.removeFirst(max(0, entries.count - Self.capacity))
    }

    /// How many scheduled syncs in a row, up to now, were skipped for `reason`.
    func consecutiveSkips(for reason: SkipReason) -> Int {
        guard let last = entries.last, last.outcome == .skipped(reason) else { return 0 }
        return last.count
    }
}
