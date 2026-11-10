import Foundation

struct HealthEvaluator: Sendable {
    let freshness: TimeInterval = 25 * 60

    /// - Parameters:
    ///   - volumeError: Why the folder's external volume cannot be used, if it cannot.
    ///   - transcript: What rclone printed during the latest run.
    func status(
        validationError: String?,
        volumeError: String?,
        isRunning: Bool,
        latestRun: SyncRunRecord?,
        transcript: [String],
        activity: ActivityLog,
        now: Date,
        awakeSince: Date
    ) -> SyncStatus {
        if let validationError { return .disabled(reason: validationError) }
        // A run in progress may be the fix for a failed or missing sync, so show it first.
        if isRunning { return .running }
        // Pauses that clear by themselves never alarm, however long they last.
        if volumeError != nil { return .paused(.volumeUnavailable) }
        if activity.consecutiveSkips(for: .lowDataNetwork) > 0 { return .paused(.lowDataNetwork) }
        let success = latestRun?.lastSuccessAt
        let stale = now.timeIntervalSince(awakeSince) >= freshness && (success.map { now.timeIntervalSince($0) > freshness } ?? true)
        if let latestRun, latestRun.outcome == .failure {
            let reason = latestRun.failureReason ?? "The most recent sync failed."
            // The drive is back, so the next scheduled sync runs.
            if reason == SyncSettings.volumeUnavailable { return .paused(.retrying(failure: reason)) }
            if stale || Self.failuresInARow(activity) > 1 || Self.wontClearOnItsOwn(activity: activity, transcript: transcript) {
                return .unhealthy(reason: reason)
            }
            return .paused(.retrying(failure: reason))
        }
        guard let success else { return stale ? .unhealthy(reason: "No successful sync has completed yet.") : .waitingForFirstSync }
        if stale { return .unhealthy(reason: "No successful sync completed in the last 25 minutes.") }
        return .healthy(lastSuccess: success)
    }

    /// Failed runs since the last success, not counting skips or an unmounted drive.
    private static func failuresInARow(_ activity: ActivityLog) -> Int {
        activity.entries.reversed()
            .filter { !$0.isSkip && $0.outcome != .failed(reason: SyncSettings.volumeUnavailable) }
            .prefix { $0.outcome != .succeeded }
            .count
    }

    /// Scheduled syncs never resync, so a failed resync stays failed, as does a run
    /// whose problem the next sync would hit again.
    private static func wontClearOnItsOwn(activity: ActivityLog, transcript: [String]) -> Bool {
        if activity.entries.last(where: { !$0.isSkip })?.trigger == .resync { return true }
        switch SyncProblem(rcloneOutput: transcript) {
        case .needsResync, .checkFileMissing, .signInExpired, .tooManyDeletes: return true
        case .oneDriveUnreachable, .unrecognized, nil: return false
        }
    }
}
