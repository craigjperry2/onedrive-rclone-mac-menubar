import Foundation
import ServiceManagement
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
    }

    @Test func runningTakesPrecedenceOverFailedStaleOrMissingSuccess() {
        let now = Date.now
        let awake = now.addingTimeInterval(-3_600)
        let failed = SyncRunRecord(startedAt: now, finishedAt: now, outcome: .failure, failureReason: "Bisync aborted", lastSuccessAt: now.addingTimeInterval(-60))
        let stale = SyncRunRecord(startedAt: now, finishedAt: now, outcome: .success, failureReason: nil, lastSuccessAt: now.addingTimeInterval(-1_800))
        let evaluator = HealthEvaluator()

        #expect(evaluator.status(validationError: nil, isRunning: true, latestRun: failed, now: now, awakeSince: awake) == .running)
        #expect(evaluator.status(validationError: nil, isRunning: true, latestRun: nil, now: now, awakeSince: now) == .running)
        #expect(evaluator.status(validationError: nil, isRunning: true, latestRun: nil, now: now, awakeSince: awake) == .running)
        #expect(evaluator.status(validationError: nil, isRunning: true, latestRun: stale, now: now, awakeSince: awake) == .running)
        #expect(evaluator.status(validationError: "No rclone", isRunning: true, latestRun: failed, now: now, awakeSince: awake) == .disabled(reason: "No rclone"))
    }

    @Test func activityLogMergesRepeatedSkipsAndKeepsTheLatestEntries() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        func skip(_ reason: SkipReason, at minutes: Double) -> SyncActivity {
            SyncActivity(trigger: .scheduled, outcome: .skipped(reason), startedAt: start + minutes * 60, finishedAt: start + minutes * 60)
        }
        var log = ActivityLog()

        log.record(skip(.lowDataNetwork, at: 0))
        log.record(skip(.lowDataNetwork, at: 10))
        log.record(skip(.lowDataNetwork, at: 20))
        #expect(log.entries.count == 1)
        #expect(log.entries[0].startedAt == start)
        #expect(log.entries[0].finishedAt == start + 20 * 60)
        #expect(log.consecutiveSkips(for: .lowDataNetwork) == 3)
        #expect(log.consecutiveSkips(for: .previousSyncRunning) == 0)

        log.record(skip(.previousSyncRunning, at: 30))
        log.record(skip(.lowDataNetwork, at: 40))
        #expect(log.entries.count == 3)
        #expect(log.consecutiveSkips(for: .lowDataNetwork) == 1)

        for minute in 0..<ActivityLog.capacity {
            log.record(SyncActivity(trigger: .syncNow, outcome: .succeeded, startedAt: start + Double(minute), finishedAt: start + Double(minute)))
        }
        #expect(log.entries.count == ActivityLog.capacity)
        #expect(log.entries.first?.outcome == .succeeded)
        #expect(log.entries.last?.startedAt == start + Double(ActivityLog.capacity - 1))
    }

    @Test func recentActivityListsNewestFirstWithPlainTimestampedSummaries() {
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5))!
        func at(_ hour: Int, _ minute: Int) -> Date { day.addingTimeInterval(Double(hour * 3600 + minute * 60)) }
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        var log = ActivityLog()
        log.record(SyncActivity(trigger: .scheduled, outcome: .skipped(.setupRequired), startedAt: at(8, 0), finishedAt: at(8, 0)))
        #expect(log.recent.isEmpty)

        log.record(SyncActivity(trigger: .scheduled, outcome: .skipped(.lowDataNetwork), startedAt: at(9, 0), finishedAt: at(9, 0)))
        log.record(SyncActivity(trigger: .scheduled, outcome: .succeeded, startedAt: at(10, 0), finishedAt: at(10, 4)))
        log.record(SyncActivity(trigger: .scheduled, outcome: .failed(reason: "bisync aborted"), startedAt: at(14, 30), finishedAt: at(14, 31)))
        let rows = log.recent.map { $0.summary(now: at(15, 0)) }

        #expect(rows == [
            "Scheduled sync needed attention at \(time(at(14, 31)))",
            "Scheduled sync succeeded at \(time(at(10, 4)))",
            "Scheduled sync skipped at \(time(at(9, 0))): low-data or metered network",
        ])

        let repeated = SyncActivity(trigger: .scheduled, outcome: .skipped(.lowDataNetwork), startedAt: at(9, 0), finishedAt: at(9, 20), count: 3)
        #expect(repeated.summary(now: at(15, 0)) == "3 scheduled syncs skipped, \(time(at(9, 0))) to \(time(at(9, 20))): low-data or metered network")
        let yesterday = SyncActivity(trigger: .syncNow, outcome: .succeeded, startedAt: at(-1, 0), finishedAt: at(-1, 0))
        #expect(yesterday.summary(now: at(15, 0)).contains(at(-1, 0).formatted(.dateTime.month(.abbreviated).day())))

        for minute in 0..<30 {
            log.record(SyncActivity(trigger: .syncNow, outcome: .succeeded, startedAt: at(16, minute), finishedAt: at(16, minute)))
        }
        #expect(log.recent.count == 20)
        #expect(log.recent.first?.finishedAt == at(16, 29))
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

    @Test func blankExecutableLeavesSettingsDisabled() {
        #expect(SyncSettings.initialTemplate.configurationError() == SyncSettings.rcloneRequired)
    }

    @Test func rcloneResolvesFromSettingsThenFirstExecutableCandidate() {
        var settings = SyncSettings.initialTemplate
        let candidates = ["/does/not/exist/rclone", "/bin/sh", "/bin/zsh"]

        #expect(settings.resolvingRclone(candidates: candidates).rcloneExecutablePath == "/bin/sh")
        #expect(settings.resolvingRclone(candidates: ["/does/not/exist/rclone"]).configurationError() == SyncSettings.rcloneRequired)

        settings.rcloneExecutablePath = "/bin/zsh"
        #expect(settings.resolvingRclone(candidates: candidates).rcloneExecutablePath == "/bin/zsh")

        // A stale explicit path, such as a garbage-collected Nix store path, falls back to detection.
        settings.rcloneExecutablePath = "/nix/store/gone-rclone/bin/rclone"
        #expect(settings.resolvingRclone(candidates: candidates).rcloneExecutablePath == "/bin/sh")
    }

    @Test func rcloneCandidatesCoverHomebrewNixAndPath() {
        let candidates = SyncSettings.rcloneCandidates(home: "/Users/alex", user: "alex", environment: ["PATH": "/usr/bin:/custom/bin"])

        #expect(Array(candidates.prefix(2)) == ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"])
        #expect(candidates.contains("/Users/alex/.nix-profile/bin/rclone"))
        #expect(candidates.contains("/etc/profiles/per-user/alex/bin/rclone"))
        #expect(candidates.contains("/run/current-system/sw/bin/rclone"))
        #expect(Array(candidates.suffix(2)) == ["/usr/bin/rclone", "/custom/bin/rclone"])
    }

    @Test func loginItemWarningExplainsEveryStateExceptEnabled() {
        #expect(LoginItemManager.warning(for: .enabled) == nil)
        #expect(LoginItemManager.warning(for: .requiresApproval)?.contains("Login Items") == true)
        #expect(LoginItemManager.warning(for: .notRegistered)?.contains("Login Items") == true)
        #expect(LoginItemManager.warning(for: .notFound)?.contains("Login Items") == true)
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
        // A space in the directory, as in "Application Support", must not break transcript creation.
        let transcriptDirectory = FileManager.default.temporaryDirectory.appending(path: "onedrive rclone runner \(UUID().uuidString)")
        let transcript = transcriptDirectory.appending(path: "latest-run.log")
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: transcriptDirectory)
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

    @Test func runnerCreatesMissingTranscriptDirectories() async {
        let subFolder = FileManager.default.temporaryDirectory.appending(path: "nested-dir-\(UUID().uuidString)")
        let transcript = subFolder.appending(path: "latest-run.log")
        defer { try? FileManager.default.removeItem(at: subFolder) }

        let settings = SyncSettings(rcloneExecutablePath: "/does/not/exist/rclone", configPath: "/tmp/test-rclone.conf", remoteName: "onedrive", localPath: "/tmp/local", intervalSeconds: 600)

        _ = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(FileManager.default.fileExists(atPath: transcript.path()))
    }

    @Test func authorizeReportsTheSignInPageAndStopsRcloneWhenCancelled() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        echo "NOTICE: If your browser doesn't open automatically go to the following link: http://127.0.0.1:53682/auth?state=abc_DEF-12"
        echo "NOTICE: Waiting for code..."
        exec sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: script) }
        let settings = SyncSettings(rcloneExecutablePath: script.path(), configPath: "/tmp/test-rclone.conf", remoteName: "onedrive", localPath: "", intervalSeconds: 600)
        let signInURL = LockedURL()
        let started = Date()

        let authorization = Task { await RcloneProcessRunner().authorize(settings) { signInURL.set($0) } }
        while signInURL.value == nil, Date().timeIntervalSince(started) < 10 { try await Task.sleep(for: .milliseconds(20)) }
        authorization.cancel()
        let failure = await authorization.value

        #expect(signInURL.value == URL(string: "http://127.0.0.1:53682/auth?state=abc_DEF-12"))
        #expect(failure != nil)
        #expect(Date().timeIntervalSince(started) < 10)
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

private final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    var value: URL? { lock.withLock { url } }
    func set(_ url: URL) { lock.withLock { self.url = url } }
}
