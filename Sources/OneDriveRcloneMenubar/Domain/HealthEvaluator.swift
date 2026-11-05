import Foundation

struct HealthEvaluator: Sendable {
    let freshness: TimeInterval = 25 * 60

    func status(validationError: String?, isRunning: Bool, latestRun: SyncRunRecord?, now: Date, awakeSince: Date) -> SyncStatus {
        if let validationError { return .disabled(reason: validationError) }
        // A run in progress may be the fix for a failed or missing sync, so show it first.
        if isRunning { return .running }
        if let latestRun, latestRun.outcome == .failure { return .unhealthy(reason: latestRun.failureReason ?? "The most recent sync failed.") }
        guard let success = latestRun?.lastSuccessAt else {
            return now.timeIntervalSince(awakeSince) < freshness ? .waitingForFirstSync : .unhealthy(reason: "No successful sync has completed yet.")
        }
        if now.timeIntervalSince(awakeSince) >= freshness, now.timeIntervalSince(success) > freshness {
            return .unhealthy(reason: "No successful sync completed in the last 25 minutes.")
        }
        return .healthy(lastSuccess: success)
    }
}
