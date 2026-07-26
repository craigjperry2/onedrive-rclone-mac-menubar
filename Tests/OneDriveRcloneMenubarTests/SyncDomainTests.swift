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
        let file = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-transcript-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        try (1...35).map(String.init).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let lines = TranscriptStore(fileURL: file).displayLines()
        #expect(lines.count == 30)
        #expect(lines.first == "6")
        #expect(lines.last == "35")
    }

    @Test func transcriptStoreTrimsPersistedOutput() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-transcript-trim-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
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

    @Test func externalVolumeAvailabilityIsNotAConfigurationError() {
        var settings = SyncSettings.initialTemplate
        settings.rcloneExecutablePath = "/bin/sh"
        settings.configPath = "/dev/null"
        settings.localPath = "/Volumes/definitely-not-mounted-\(UUID().uuidString)/OneDrive"

        #expect(settings.configurationError() == nil)
        #expect(settings.availabilityError() == "The configured external volume is unavailable.")
    }

    @Test func runnerUsesExpectedBisyncContractAndBoundsOutput() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        i=1
        while [ "$i" -le 35 ]; do
          printf 'line-%s\\n' "$i"
          i=$((i + 1))
        done
        printf 'config=%s\\n' "$RCLONE_CONFIG"
        printf 'arg=%s\\n' "$@"
        """)
        let transcript = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-runner-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: transcript)
        }
        let settings = SyncSettings(rcloneExecutablePath: script.path(), configPath: "/tmp/test-rclone.conf", remoteName: "onedrive", localPath: "/tmp/local mirror", intervalSeconds: 600)

        let result = await RcloneProcessRunner().run(.resync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode == 0)
        #expect(result.lines.count == 30)
        #expect(result.lines.contains("config=/tmp/test-rclone.conf"))
        #expect(result.lines.contains("arg=bisync"))
        #expect(result.lines.contains("arg=onedrive:"))
        #expect(result.lines.contains("arg=/tmp/local mirror"))
        #expect(result.lines.contains("arg=--resync"))
        #expect(TranscriptStore(fileURL: transcript).displayLines() == result.lines)
    }

    @Test func runnerReportsTimeoutAheadOfProcessOutput() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        trap 'exit 0' TERM
        echo 'last ordinary output line'
        while true; do :; done
        """)
        let transcript = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-timeout-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: transcript)
        }
        let settings = SyncSettings(rcloneExecutablePath: script.path(), configPath: "/tmp/test-rclone.conf", remoteName: "onedrive", localPath: "/tmp/local", intervalSeconds: 600)

        let result = await RcloneProcessRunner(timeout: 0.05).run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode == -1)
        #expect(result.failureReason?.contains("timed out") == true)
    }

    @Test func runnerPreservesNonzeroExitAndLastOutputLine() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        echo 'rclone reported a failure'
        exit 23
        """)
        let transcript = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-failure-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: transcript)
        }
        let settings = SyncSettings(rcloneExecutablePath: script.path(), configPath: "/tmp/test-rclone.conf", remoteName: "onedrive", localPath: "/tmp/local", intervalSeconds: 600)

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode == 23)
        #expect(result.failureReason == "rclone reported a failure")
    }

    @Test func runnerReportsLaunchFailure() async {
        let transcript = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-launch-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let settings = SyncSettings(rcloneExecutablePath: "/does/not/exist/rclone", configPath: "/tmp/test-rclone.conf", remoteName: "onedrive", localPath: "/tmp/local", intervalSeconds: 600)

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode == -1)
        #expect(result.failureReason?.isEmpty == false)
    }

    @Test func systemWakeTimeNeverFallsAfterNow() {
        let now = Date()
        #expect(SystemWakeTime.current(now: now) <= now)
    }

    private func makeExecutableScript(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-script-\(UUID().uuidString).sh")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path())
        return url
    }
}
