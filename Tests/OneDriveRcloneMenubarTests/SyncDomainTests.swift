import Foundation
import ServiceManagement
import Testing
@testable import OneDriveRcloneMenubar

struct SyncDomainTests {
    // MARK: Health: Healthy, Paused, or Needs attention

    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let connectionReset = "ERROR : Failed to bisync: connection reset by peer"

    /// The status after `history`, one entry a minute up to now, with the latest run
    /// as the last non-skip entry.
    func health(
        _ history: [(SyncActivity.Trigger, SyncActivity.Outcome)],
        lastSuccessMinutesAgo: Double? = 10,
        awakeMinutes: Double = 60,
        volumeError: String? = nil,
        transcript: [String] = [],
        validationError: String? = nil,
        isRunning: Bool = false
    ) -> SyncStatus {
        var log = ActivityLog()
        for (index, (trigger, outcome)) in history.enumerated() {
            let at = Self.now - Double(history.count - index) * 60
            log.record(SyncActivity(trigger: trigger, outcome: outcome, startedAt: at, finishedAt: at))
        }
        let lastRun = history.last { if case .skipped = $0.1 { false } else { true } }
        let latestRun = lastRun.map { _, outcome in
            let failure: String? = if case .failed(let reason) = outcome { reason } else { nil }
            return SyncRunRecord(startedAt: Self.now, finishedAt: Self.now, outcome: failure == nil ? .success : .failure, failureReason: failure, lastSuccessAt: lastSuccessMinutesAgo.map { Self.now - $0 * 60 })
        }
        return HealthEvaluator().status(
            validationError: validationError,
            volumeError: volumeError,
            isRunning: isRunning,
            latestRun: latestRun,
            transcript: transcript,
            activity: log,
            now: Self.now,
            awakeSince: Self.now - awakeMinutes * 60
        )
    }

    /// AC1 of issue 26: skipped scheduled syncs are not a failure, however long they go on.
    @Test func lowDataNetworkPausesWithoutNeedingAttention() {
        let skips = Array(repeating: (SyncActivity.Trigger.scheduled, SyncActivity.Outcome.skipped(.lowDataNetwork)), count: 4)
        let status = health([(.scheduled, .succeeded)] + skips, lastSuccessMinutesAgo: 40)

        #expect(status == .paused(.lowDataNetwork))
        #expect(status.title == "Paused on a low-data network")
        #expect(status.symbolName == "wifi.exclamationmark")
        // Without the skips, the same 40-minute gap needs attention.
        #expect(health([(.scheduled, .succeeded)], lastSuccessMinutesAgo: 40) == .unhealthy(reason: "No successful sync completed in the last 25 minutes."))
        // Sync Now on the low-data network ends the pause.
        #expect(health([(.scheduled, .succeeded)] + skips + [(.syncNow, .succeeded)], lastSuccessMinutesAgo: 0) == .healthy(lastSuccess: Self.now))
    }

    /// AC2 of issue 26.
    @Test func unmountedDrivePausesUntilItIsReconnected() {
        let unmounted = Array(repeating: (SyncActivity.Trigger.scheduled, SyncActivity.Outcome.failed(reason: SyncSettings.volumeUnavailable)), count: 5)
        let status = health([(.scheduled, .succeeded)] + unmounted, lastSuccessMinutesAgo: 60, volumeError: SyncSettings.volumeUnavailable)

        #expect(status == .paused(.volumeUnavailable))
        #expect(status.symbolName == "externaldrive.badge.xmark")
        #expect(status.explanation?.contains("Syncing resumes when the drive is reconnected.") == true)
        // Reconnected: the next scheduled sync runs, so nothing needs doing yet.
        #expect(health([(.scheduled, .succeeded)] + unmounted, lastSuccessMinutesAgo: 60) == .paused(.retrying(failure: SyncSettings.volumeUnavailable)))
        // Runs that found the drive missing do not count as failures in a row.
        #expect(health([(.scheduled, .succeeded)] + unmounted + [(.scheduled, .failed(reason: Self.connectionReset))]) == .paused(.retrying(failure: Self.connectionReset)))
    }

    /// AC3 of issue 26: an unknown failure needs attention once it repeats or the
    /// last success is older than 25 minutes, and only after 25 minutes awake.
    @Test(arguments: [
        ([.succeeded, .failed(reason: SyncDomainTests.connectionReset)], 10, 60, false),
        ([.succeeded, .failed(reason: "first"), .failed(reason: SyncDomainTests.connectionReset)], 10, 60, true),
        ([.failed(reason: "earlier"), .succeeded, .failed(reason: SyncDomainTests.connectionReset)], 10, 60, false),
        ([.succeeded, .failed(reason: "first"), .skipped(.previousSyncRunning), .failed(reason: SyncDomainTests.connectionReset)], 10, 60, true),
        ([.succeeded, .failed(reason: SyncDomainTests.connectionReset)], 26, 60, true),
        ([.succeeded, .failed(reason: SyncDomainTests.connectionReset)], 26, 20, false),
        ([.failed(reason: SyncDomainTests.connectionReset)], nil, 20, false),
        ([.failed(reason: SyncDomainTests.connectionReset)], nil, 26, true),
    ] as [([SyncActivity.Outcome], Double?, Double, Bool)])
    func oneTransientFailureWaitsForTheNextSync(outcomes: [SyncActivity.Outcome], lastSuccessMinutesAgo: Double?, awakeMinutes: Double, needsAttention: Bool) {
        let status = health(outcomes.map { (.scheduled, $0) }, lastSuccessMinutesAgo: lastSuccessMinutesAgo, awakeMinutes: awakeMinutes)

        #expect(status == (needsAttention ? .unhealthy(reason: Self.connectionReset) : .paused(.retrying(failure: Self.connectionReset))))
        #expect(status.reason == Self.connectionReset)
    }

    /// AC4 of issue 26: problems the next scheduled sync would hit again need
    /// attention after one failure; others get one retry.
    @Test(arguments: [
        (RcloneOutput.needsResync, true),
        (RcloneOutput.checkFileMissingOnOneDrive, true),
        (RcloneOutput.checkFileMissingLocally, true),
        (RcloneOutput.tooManyDeletes, true),
        (RcloneOutput.signInExpired, true),
        (RcloneOutput.unreachableDNS, false),
        // rclone calls this retryable, and with no known cause it gets one retry.
        (["2026/11/09 21:28:51 ERROR : \u{1B}[33mBisync aborted. Error is retryable without --resync due to --resilient mode.\u{1B}[0m", "2026/11/09 21:28:51 NOTICE: Failed to bisync: bisync aborted"], false),
    ] as [([String], Bool)])
    func failureThatWillNotClearNeedsAttentionAtOnce(transcript: [String], needsAttention: Bool) {
        let reason = "The sync failed"
        let status = health([(.scheduled, .succeeded), (.scheduled, .failed(reason: reason))], transcript: transcript)

        #expect(status == (needsAttention ? .unhealthy(reason: reason) : .paused(.retrying(failure: reason))))
    }

    /// Scheduled syncs never resync, so nothing retries a failed one.
    @Test func failedResyncNeedsAttentionAtOnce() {
        #expect(health([(.resync, .failed(reason: Self.connectionReset))], lastSuccessMinutesAgo: nil, awakeMinutes: 1) == .unhealthy(reason: Self.connectionReset))
        #expect(health([(.syncNow, .failed(reason: Self.connectionReset))], lastSuccessMinutesAgo: nil, awakeMinutes: 1) == .paused(.retrying(failure: Self.connectionReset)))
    }

    @Test func freshnessWaitsForWakeGracePeriod() {
        #expect(health([(.scheduled, .succeeded)], lastSuccessMinutesAgo: 30, awakeMinutes: 1) == .healthy(lastSuccess: Self.now - 1_800))
        #expect(health([(.scheduled, .succeeded)], lastSuccessMinutesAgo: 30, awakeMinutes: 30) == .unhealthy(reason: "No successful sync completed in the last 25 minutes."))
        #expect(health([], lastSuccessMinutesAgo: nil, awakeMinutes: 1) == .waitingForFirstSync)
        #expect(health([], lastSuccessMinutesAgo: nil, awakeMinutes: 30) == .unhealthy(reason: "No successful sync has completed yet."))
    }

    @Test func runningTakesPrecedenceOverPausedFailedStaleOrMissingSuccess() {
        let failed: [(SyncActivity.Trigger, SyncActivity.Outcome)] = [(.scheduled, .failed(reason: "a")), (.scheduled, .failed(reason: "b"))]

        #expect(health(failed, isRunning: true) == .running)
        #expect(health([], lastSuccessMinutesAgo: nil, isRunning: true) == .running)
        #expect(health([(.scheduled, .succeeded)], lastSuccessMinutesAgo: 30, isRunning: true) == .running)
        #expect(health([(.scheduled, .skipped(.lowDataNetwork))], isRunning: true) == .running)
        #expect(health([], volumeError: SyncSettings.volumeUnavailable, isRunning: true) == .running)
        #expect(health(failed, volumeError: SyncSettings.volumeUnavailable, validationError: "No rclone", isRunning: true) == .disabled(reason: "No rclone"))
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
        log.record(SyncActivity(trigger: .syncNow, outcome: .stopped, startedAt: at(14, 40), finishedAt: at(14, 43)))
        let rows = log.recent.map { $0.summary(now: at(15, 0)) }

        #expect(rows == [
            "Sync Now stopped by you at \(time(at(14, 43)))",
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

    /// The notification names the problem and the fix the menu offers for it, and
    /// offers Sync Now only when trying again is that fix.
    @Test(arguments: [
        (RcloneOutput.checkFileMissingOnOneDrive, "The RCLONE_TEST check file is missing from OneDrive. ", " Open OneDrive Sync in the menu bar and choose Recreate Check File on OneDrive…", [.showLog]),
        (RcloneOutput.checkFileMissingLocally, "The RCLONE_TEST check file is missing from your folder. ", " Open OneDrive Sync in the menu bar and choose Recreate Check File in Your Folder…", [.showLog]),
        // rclone also asks for a resync here, but only the check file fixes it.
        (RcloneOutput.resyncWithCheckFileMissingOnOneDrive, "The RCLONE_TEST check file is missing from OneDrive. ", " Open OneDrive Sync in the menu bar and choose Recreate Check File on OneDrive…", [.showLog]),
        (RcloneOutput.needsResync, "rclone lost track of the last sync. ", " Open OneDrive Sync in the menu bar and choose Resync…", [.showLog]),
        (RcloneOutput.signInExpired, "The OneDrive sign-in has expired. ", " Every sync fails until rclone signs in again.", [.showLog]),
        (RcloneOutput.unreachableDNS, "OneDrive cannot be reached. ", " stopped.", [.syncNow, .showLog]),
    ] as [([String], String, String, [SyncNotification.Action])])
    func failureNotificationNamesTheProblemAndOffersOnlyFixesThatCanHelp(output: [String], bodyStart: String, bodyEnd: String, actions: [SyncNotification.Action]) throws {
        let reason = try #require(SyncProblem(rcloneOutput: output)).name

        let notification = SyncNotification.syncFailed(reason: reason, transcriptLines: output, at: .now)

        #expect(notification.body.hasPrefix(bodyStart + "The scheduled sync at "))
        #expect(notification.body.hasSuffix(bodyEnd))
        #expect(notification.actions == actions)
    }

    @Test func unpluggedDriveNotificationSaysSyncingResumesWithoutOfferingSyncNow() {
        let reason = SyncSettings.volumeUnavailable
        let notification = SyncNotification.syncFailed(reason: reason, transcriptLines: [reason], at: .now)

        #expect(notification.body.hasPrefix("The configured external volume is unavailable. The scheduled sync at "))
        #expect(notification.body.hasSuffix(" stopped. Syncing resumes when the drive is connected again."))
        #expect(notification.actions == [.showLog])
    }

    /// Buttons run without a confirmation, so Resync, which can overwrite files,
    /// must never become one.
    @Test func notificationButtonsAreOnlySyncNowAndShowLog() {
        #expect(SyncNotification.Action.allCases.map(\.title) == ["Sync Now", "Show Log"])
        #expect(SyncNotification.actionSets.map(SyncNotification.categoryID(for:)).sorted() == ["show-log", "sync-now", "sync-now+show-log"])
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

    @Test(arguments: [
        (RcloneOutput.needsResync, .needsResync),
        (["2026/11/09 10:00:00 ERROR : Bisync aborted. Must run --resync to recover.", "2026/11/09 10:00:00 NOTICE: Failed to bisync: bisync aborted"], .needsResync),
        (RcloneOutput.checkFileMissingOnOneDrive, .checkFileMissing(.oneDrive)),
        (RcloneOutput.checkFileMissingLocally, .checkFileMissing(.localFolder)),
        (["2026/11/09 10:00:00 ERROR : Access test failed: Path1 count 0, Path2 count 0 - RCLONE_TEST"], .checkFileMissing(.both)),
        (RcloneOutput.signInExpired, .signInExpired),
        (RcloneOutput.tooManyDeletes, .tooManyDeletes),
        (RcloneOutput.unreachableDNS, .oneDriveUnreachable),
        (RcloneOutput.unreachableConnectionRefused, .oneDriveUnreachable),
        // An expired token that cannot be refreshed while offline is a network problem, not a sign-in problem.
        (RcloneOutput.unreachableDuringTokenRefresh, .oneDriveUnreachable),
    ] as [([String], SyncProblem)])
    func knownRcloneFailuresAreNamed(output: [String], problem: SyncProblem) {
        #expect(SyncProblem(rcloneOutput: output) == problem)
    }

    @Test func differentProblemsHaveDifferentNames() {
        let problems: [SyncProblem] = [.needsResync, .checkFileMissing(.oneDrive), .checkFileMissing(.localFolder), .checkFileMissing(.both), .signInExpired, .tooManyDeletes, .oneDriveUnreachable]

        #expect(Set(problems.map(\.name)).count == problems.count)
    }

    @Test(arguments: [
        // The first ERROR line, not the generic abort lines after it.
        ([
            "2026/11/09 10:00:00 NOTICE: bisync is IN BETA. Don't use in production!",
            "2026/11/09 10:00:01 ERROR : \u{1B}[31mBisync critical error: path1 and path2 are the same\u{1B}[0m",
            "2026/11/09 10:00:01 ERROR : \u{1B}[33mBisync aborted. Error is retryable without --resync due to --resilient mode.\u{1B}[0m",
            "2026/11/09 10:00:01 NOTICE: Failed to bisync: bisync aborted",
        ], "Bisync critical error: path1 and path2 are the same"),
        (["2026/11/09 21:30:24 CRITICAL: Failed to create file system for \"onedrive:\": didn't find section in config file (\"onedrive\")"], "Failed to create file system for \"onedrive:\": didn't find section in config file (\"onedrive\")"),
        // bisync lists changed files in NOTICE lines; a file name is not a diagnosis.
        (["2026/11/09 10:00:00 NOTICE: - Path1    File is new    - notes/connection refused.txt", "2026/11/09 10:00:01 ERROR : Bisync critical error: something new"], "Bisync critical error: something new"),
        // Without an ERROR line, the last line that says anything.
        (["2026/11/09 10:00:01 NOTICE: Failed to bisync: bisync aborted", ""], "Failed to bisync: bisync aborted"),
        (["rclone reported a failure"], "rclone reported a failure"),
    ] as [([String], String)])
    func unknownFailuresShowTheFirstErrorWithoutTimestampOrColour(output: [String], reason: String) {
        #expect(SyncProblem(rcloneOutput: output) == .unrecognized(reason))
    }

    @Test(arguments: [[], [""], ["", " "]] as [[String]])
    func noOutputNamesNoProblem(output: [String]) {
        #expect(SyncProblem(rcloneOutput: output) == nil)
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
}

/// Real output of rclone 1.75.2 on macOS, run with the app's bisync arguments
/// against the fake OneDrive (docs/testing-with-fake-onedrive.md), or against a
/// onedrive remote with a made-up token for the sign-in and network failures.
enum RcloneOutput {
    /// Sync Now before the first Resync.
    static let needsResync = [
        "2026/11/09 21:26:30 ERROR : \u{1B}[31mBisync critical error: cannot find prior Path1 or Path2 listings, likely due to critical error on prior run ",
        "\u{1B}[35mTip: here are the filenames we were looking for. Do they exist? ",
        "\u{1B}[0m\u{1B}[36mPath1: \u{1B}[94m/Users/runner/Library/Caches/rclone/bisync/Users_runner_onedrive-fake_remote..Users_runner_onedrive-fake_local.path1.lst\u{1B}[0m",
        "\u{1B}[0m\u{1B}[36mPath2: \u{1B}[94m/Users/runner/Library/Caches/rclone/bisync/Users_runner_onedrive-fake_remote..Users_runner_onedrive-fake_local.path2.lst\u{1B}[0m",
        "\u{1B}[0m\u{1B}[35mTry running this command to inspect the work dir: ",
        "\u{1B}[0m\u{1B}[96mrclone lsl \"/Users/runner/Library/Caches/rclone/bisync\"\u{1B}[0m\u{1B}[0m",
        "2026/11/09 21:26:30 ERROR : \u{1B}[33mBisync aborted. Error is retryable without --resync due to --resilient mode.\u{1B}[0m",
        "2026/11/09 21:26:30 NOTICE: Failed to bisync: bisync aborted",
    ]
    /// RCLONE_TEST deleted from the fake OneDrive after a successful sync.
    static let checkFileMissingOnOneDrive = [
        "2026/11/09 21:26:30 ERROR : Access test failed: Path1 count 0, Path2 count 1 - RCLONE_TEST",
        "2026/11/09 21:26:30 ERROR : - \u{1B}[34m\u{1B}[0m         \u{1B}[35mAccess test failed: Path2 file not found in Path1\u{1B}[0m - \u{1B}[36mRCLONE_TEST\u{1B}[0m",
        "2026/11/09 21:26:30 ERROR : \u{1B}[31mBisync critical error: check file check failed\u{1B}[0m",
        "2026/11/09 21:26:30 ERROR : \u{1B}[33mBisync aborted. Error is retryable without --resync due to --resilient mode.\u{1B}[0m",
        "2026/11/09 21:26:30 NOTICE: Failed to bisync: bisync aborted",
    ]
    /// RCLONE_TEST deleted from the local folder after a successful sync.
    static let checkFileMissingLocally = [
        "2026/11/09 21:26:30 ERROR : Access test failed: Path1 count 1, Path2 count 0 - RCLONE_TEST",
        "2026/11/09 21:26:30 ERROR : - \u{1B}[34m\u{1B}[0m         \u{1B}[35mAccess test failed: Path1 file not found in Path2\u{1B}[0m - \u{1B}[36mRCLONE_TEST\u{1B}[0m",
        "2026/11/09 21:26:30 ERROR : \u{1B}[31mBisync critical error: check file check failed\u{1B}[0m",
        "2026/11/09 21:26:30 ERROR : \u{1B}[33mBisync aborted. Error is retryable without --resync due to --resilient mode.\u{1B}[0m",
        "2026/11/09 21:26:30 NOTICE: Failed to bisync: bisync aborted",
    ]
    /// RCLONE_TEST deleted from both sides after a successful sync.
    static let checkFileMissingOnBothSides = [
        "2026/11/09 21:29:24 NOTICE: --check-access: \u{1B}[31mFailed to find any files named \u{1B}[36mRCLONE_TEST\u{1B}[0m",
        " More info: \u{1B}[34mhttps://rclone.org/bisync/#check-access\u{1B}[0m\u{1B}[0m",
        "2026/11/09 21:29:24 ERROR : Access test failed: Path1 count 0, Path2 count 0 - RCLONE_TEST",
        "2026/11/09 21:29:24 ERROR : \u{1B}[31mBisync critical error: check file check failed\u{1B}[0m",
        "2026/11/09 21:29:24 ERROR : \u{1B}[33mBisync aborted. Error is retryable without --resync due to --resilient mode.\u{1B}[0m",
        "2026/11/09 21:29:24 NOTICE: Failed to bisync: bisync aborted",
    ]
    /// A resync with the check file missing on OneDrive: rclone asks for another
    /// resync, which fails the same way until the file is back.
    static let resyncWithCheckFileMissingOnOneDrive = [
        "2026/11/09 21:29:24 ERROR : Access test failed: Path1 count 0, Path2 count 1 - RCLONE_TEST",
        "2026/11/09 21:29:24 ERROR : - \u{1B}[34m\u{1B}[0m         \u{1B}[35mAccess test failed: Path2 file not found in Path1\u{1B}[0m - \u{1B}[36mRCLONE_TEST\u{1B}[0m",
        "2026/11/09 21:29:24 ERROR : \u{1B}[31mBisync critical error: check file check failed\u{1B}[0m",
        "2026/11/09 21:29:24 ERROR : \u{1B}[31mBisync aborted. Must run --resync to recover.\u{1B}[0m",
        "2026/11/09 21:29:24 NOTICE: Failed to bisync: bisync aborted",
    ]
    /// 6 of 8 files deleted from the fake OneDrive, over bisync's default --max-delete of 50%.
    static let tooManyDeletes = [
        "2026/11/09 21:26:35 ERROR : Safety abort: too many deletes (>50%, 6 of 8) on Path1 \"/Users/runner/onedrive-fake/remote/\". Run with --force if desired.",
        "2026/11/09 21:26:35 NOTICE: \u{1B}[31mBisync aborted. Please try again.\u{1B}[0m",
        "2026/11/09 21:26:35 NOTICE: Failed to bisync: too many deletes",
    ]
    /// An expired access token whose refresh token Microsoft rejected.
    static let signInExpired = [
        "2026/11/09 21:26:55 CRITICAL: Failed to create file system for \"onedrive:\": failed to get root: Get \"https://graph.microsoft.com/v1.0/drives/0123456789abcdef/root\": couldn't fetch token: invalid_grant: maybe token expired? - try refreshing with \"rclone config reconnect onedrive{HkZ8H}:\"",
    ]
    static let unreachableDNS = [
        "2026/11/09 21:26:55 CRITICAL: Failed to create file system for \"onedrive:\": failed to get root: Get \"https://graph.microsoft.com/v1.0/drives/0123456789abcdef/root\": proxyconnect tcp: dial tcp: lookup proxy.invalid: no such host",
    ]
    static let unreachableConnectionRefused = [
        "2026/11/09 21:26:55 CRITICAL: Failed to create file system for \"onedrive:\": failed to get root: Get \"https://graph.microsoft.com/v1.0/drives/0123456789abcdef/root\": proxyconnect tcp: dial tcp 127.0.0.1:9: connect: connection refused",
    ]
    static let unreachableDuringTokenRefresh = [
        "2026/11/09 21:28:02 CRITICAL: Failed to create file system for \"onedrive:\": failed to get root: Get \"https://graph.microsoft.com/v1.0/drives/0123456789abcdef/root\": couldn't fetch token: Post \"https://login.microsoftonline.com/common/oauth2/v2.0/token\": proxyconnect tcp: dial tcp 127.0.0.1:9: connect: connection refused",
    ]
}

/// Writes a shell script that stands in for rclone and returns its location.
func makeExecutableScript(_ contents: String, at url: URL = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-script-\(UUID().uuidString).sh")) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    return url
}

private final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    var value: URL? { lock.withLock { url } }
    func set(_ url: URL) { lock.withLock { self.url = url } }
}
