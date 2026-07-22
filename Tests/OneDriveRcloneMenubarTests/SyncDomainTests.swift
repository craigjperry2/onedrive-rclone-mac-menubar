import Foundation
import Testing
@testable import OneDriveRcloneMenubar

struct SyncDomainTests {
    @Test func failedRunIsUnhealthyImmediately() {
        let now = Date.now
        let run = SyncRunRecord(startedAt: now, finishedAt: now, outcome: .failure, failureReason: "Volume unavailable", lastSuccessAt: now.addingTimeInterval(-60))

        #expect(HealthEvaluator().status(validationError: nil, isRunning: false, latestRun: run, now: now, awakeSince: now.addingTimeInterval(-100)) == .unhealthy(reason: "Volume unavailable"))
    }

    @Test func freshnessWaitsForWakeGracePeriod() {
        let now = Date.now
        let lastSuccess = now.addingTimeInterval(-1_800)
        let run = SyncRunRecord(startedAt: now, finishedAt: now, outcome: .success, failureReason: nil, lastSuccessAt: lastSuccess)
        let evaluator = HealthEvaluator()

        #expect(evaluator.status(validationError: nil, isRunning: false, latestRun: run, now: now, awakeSince: now.addingTimeInterval(-60)) == .healthy(lastSuccess: lastSuccess))
        #expect(evaluator.status(validationError: nil, isRunning: false, latestRun: run, now: now, awakeSince: now.addingTimeInterval(-1_800)) == .unhealthy(reason: "No successful sync completed in the last 25 minutes."))
        #expect(evaluator.status(validationError: nil, isRunning: true, latestRun: run, now: now, awakeSince: now.addingTimeInterval(-1_800)) == .unhealthy(reason: "No successful sync completed in the last 25 minutes."))
    }

    @Test func transcriptStoreReturnsOnlyLatestThirtyLines() throws {
        let file = URL(filePath: "/tmp/onedrive-rclone-transcript-test.log")
        try (1...35).map(String.init).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let lines = TranscriptStore(fileURL: file).displayLines()
        #expect(lines.count == 30)
        #expect(lines.first == "6")
        #expect(lines.last == "35")
    }

    @Test func transcriptStoreTrimsPersistedOutput() throws {
        let file = URL(filePath: "/tmp/onedrive-rclone-transcript-trim-test.log")
        let line = String(repeating: "x", count: 1024)
        try Array(repeating: line, count: 100).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let store = TranscriptStore(fileURL: file)
        store.trimToRecentBytes()
        #expect(try Data(contentsOf: file).count <= TranscriptStore.maximumStoredBytes)
        #expect(store.displayLines().count == 30)
    }

    @Test func blankExecutableLeavesSettingsDisabled() {
        #expect(SyncSettings.initialTemplate.validationError() == "Set rcloneExecutablePath in settings.json.")
    }
}
