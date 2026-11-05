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

    /// The Recent Activity row. Times from before today also show the day.
    func summary(now: Date) -> String {
        let name = switch trigger {
        case .scheduled: "Scheduled sync"
        case .syncNow: "Sync Now"
        case .resync: "Resync"
        }
        switch outcome {
        case .succeeded:
            return "\(name) succeeded at \(Self.time(finishedAt, now: now))"
        case .failed:
            return "\(name) needed attention at \(Self.time(finishedAt, now: now))"
        case .skipped(let reason) where count == 1:
            return "Scheduled sync skipped at \(Self.time(startedAt, now: now)): \(reason.label)"
        case .skipped(let reason):
            return "\(count) scheduled syncs skipped, \(Self.time(startedAt, now: now)) to \(Self.time(finishedAt, now: now)): \(reason.label)"
        }
    }

    private static func time(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
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

    var label: String {
        switch self {
        case .setupRequired: "not set up yet"
        case .configurationUnusable: "configuration could not be used"
        case .lowDataNetwork: "low-data or metered network"
        case .previousSyncRunning: "previous sync still running"
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

    /// What Recent Activity lists: the latest 20 entries, newest first. Skips from
    /// before setup stay in the log but are not listed, because they are not syncs,
    /// so an app that has been set up but has not synced shows no activity.
    var recent: [SyncActivity] {
        Array(entries.reversed().filter { $0.outcome != .skipped(.setupRequired) }.prefix(20))
    }

    /// How many scheduled syncs in a row, up to now, were skipped for `reason`.
    func consecutiveSkips(for reason: SkipReason) -> Int {
        guard let last = entries.last, last.outcome == .skipped(reason) else { return 0 }
        return last.count
    }
}
