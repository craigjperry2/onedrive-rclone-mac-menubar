import Foundation
import Testing
@testable import OneDriveRcloneMenubar

/// What the user sees when something goes wrong: the menu's status and reason,
/// whether Sync Now is available, Recent Activity, notifications, and what is
/// left on disk. Each test is one situation, from cause to recovery.
@MainActor
struct FailureScenarioTests {
    // MARK: rclone is missing

    @Test func missingRcloneDisablesSyncingUntilItIsInstalled() async throws {
        let harness = try Harness()
        try harness.saveSettings { $0.rcloneExecutablePath = "" }
        let nixRclone = harness.root.appending(path: "nix-profile/bin/rclone").path(percentEncoded: false)
        harness.rcloneCandidates = [nixRclone]
        let coordinator = harness.makeCoordinator()
        await coordinator.load()

        #expect(coordinator.status == .disabled(reason: SyncSettings.rcloneRequired))
        #expect(coordinator.status.reason?.contains("brew install rclone") == true)
        #expect(!coordinator.canStartSync)
        await harness.scheduler.fire()
        await coordinator.run(.sync)
        #expect(await harness.runner.runs.isEmpty)
        #expect(coordinator.activity.entries.map(\.outcome) == [.skipped(.setupRequired)])
        #expect(coordinator.activity.recent.isEmpty)
        #expect(harness.notifier.posted.isEmpty)

        try harness.installRclone(at: nixRclone)
        await harness.checkScheduler.fire()

        #expect(coordinator.status == .waitingForFirstSync)
        await harness.scheduler.fire()
        #expect(await harness.runner.runs == [.sync])
        #expect(await harness.runner.rcloneExecutablePaths.last == nixRclone)
    }

    @Test func rcloneRemovedAfterSyncingStopsSyncingAndNotifiesOnceUntilReinstalled() async throws {
        let harness = try Harness()
        let rclone = try harness.installRclone(at: harness.root.appending(path: "homebrew/bin/rclone").path(percentEncoded: false))
        try harness.saveSettings { $0.rcloneExecutablePath = rclone }
        await harness.coordinator.load()
        await harness.scheduler.fire()
        #expect(harness.coordinator.status == .healthy(lastSuccess: harness.clock.now))

        try FileManager.default.removeItem(atPath: rclone)
        await harness.checkScheduler.fire()
        #expect(harness.coordinator.status == .disabled(reason: SyncSettings.rcloneRequired))
        await harness.scheduler.fire()
        await harness.scheduler.fire()

        #expect(await harness.runner.runs == [.sync])
        #expect(harness.coordinator.activity.entries.map(\.outcome) == [.succeeded, .skipped(.configurationUnusable)])
        #expect(harness.coordinator.activity.consecutiveSkips(for: .configurationUnusable) == 2)
        #expect(harness.notifier.posted == [.configurationUnusable(SyncSettings.rcloneRequired)])
        #expect(harness.notifier.posted.first?.body.contains("brew install rclone") == true)

        try harness.installRclone(at: rclone)
        await harness.checkScheduler.fire()
        await harness.scheduler.fire()

        #expect(await harness.runner.runs == [.sync, .sync])
        #expect(harness.coordinator.status == .healthy(lastSuccess: harness.clock.now))
        #expect(harness.notifier.posted.count == 1)
    }

    /// Such as `nix profile remove rclone` on a Mac that also has Homebrew's rclone.
    @Test func rcloneRemovedFromNixFallsBackToAnotherInstall() async throws {
        let harness = try Harness()
        let nix = try harness.installRclone(at: harness.root.appending(path: "nix-profile/bin/rclone").path(percentEncoded: false))
        let homebrew = try harness.installRclone(at: harness.root.appending(path: "homebrew/bin/rclone").path(percentEncoded: false))
        try harness.saveSettings { $0.rcloneExecutablePath = "" }
        harness.rcloneCandidates = [nix, homebrew]
        let coordinator = harness.makeCoordinator()
        await coordinator.load()
        await harness.scheduler.fire()

        try FileManager.default.removeItem(atPath: nix)
        // The schedule can fire before the once-a-minute configuration check notices.
        await harness.scheduler.fire()
        await withKnownIssue("A scheduled sync between rclone disappearing and the next configuration check is skipped, with a notification, instead of using the other install") {
            #expect(await harness.runner.runs == [.sync, .sync])
            #expect(harness.notifier.posted.isEmpty)
        }

        await harness.checkScheduler.fire()
        await harness.scheduler.fire()
        #expect(await harness.runner.rcloneExecutablePaths.last == homebrew)
        #expect(coordinator.status == .healthy(lastSuccess: harness.clock.now))
    }

    /// Such as the remote being deleted from rclone.conf moments before a scheduled sync.
    @Test func remoteRemovedJustBeforeAScheduledSyncStopsSyncingAndNotifies() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.scheduler.fire()
        await harness.runner.setValidationError(SyncSettings.readyToSetUp)

        await harness.scheduler.fire()

        #expect(await harness.runner.runs == [.sync])
        #expect(harness.coordinator.status == .disabled(reason: SyncSettings.readyToSetUp))
        #expect(harness.coordinator.activity.entries.map(\.outcome) == [.succeeded, .skipped(.configurationUnusable)])
        #expect(harness.notifier.posted == [.configurationUnusable(SyncSettings.readyToSetUp)])
    }

    // MARK: Syncs that fail

    @Test func failureWithoutOutputExplainsTheExitStatus() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.runner.setExitCode(3)

        await harness.coordinator.run(.sync)

        #expect(harness.coordinator.status == .unhealthy(reason: "rclone exited with status 3."))
        #expect(harness.coordinator.canStartSync)
    }

    @Test func needsAttentionSurvivesARestart() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.runner.setExitCode(7, lastLine: "Bisync aborted")
        await harness.scheduler.fire()

        let restarted = harness.makeCoordinator()
        await restarted.load()

        #expect(restarted.status == .unhealthy(reason: "Bisync aborted"))
        #expect(restarted.activity.recent.first?.outcome == .failed(reason: "Bisync aborted"))
    }

    @Test func noSuccessfulSyncFor25MinutesNeedsAttention() async throws {
        let harness = try Harness(awakeFor: 60 * 60)
        await harness.coordinator.load()
        await harness.coordinator.run(.sync)
        let success = harness.clock.now

        harness.clock.advance(by: 24 * 60)
        await harness.checkScheduler.fire()
        #expect(harness.coordinator.status == .healthy(lastSuccess: success))

        harness.clock.advance(by: 2 * 60)
        await harness.checkScheduler.fire()
        #expect(harness.coordinator.status == .unhealthy(reason: "No successful sync completed in the last 25 minutes."))
    }

    @Test func unmountedExternalDriveNeedsAttentionWithoutRunningRclone() async throws {
        let harness = try Harness(localPath: "/Volumes/not-mounted-\(UUID().uuidString)/OneDrive")
        let reason = "The configured external volume is unavailable."
        await harness.coordinator.load()
        #expect(harness.coordinator.status == .unhealthy(reason: reason))

        await harness.scheduler.fire()

        #expect(await harness.runner.runs.isEmpty)
        #expect(harness.coordinator.status == .unhealthy(reason: reason))
        #expect(harness.coordinator.latestRun?.outcome == .failure)
        #expect(harness.coordinator.transcriptLines == [reason])
        #expect(TranscriptStore(fileURL: harness.paths.latestTranscriptFile).displayLines() == [reason])
        #expect(harness.coordinator.activity.entries.map(\.outcome) == [.failed(reason: reason)])
        #expect(harness.notifier.posted == [.syncFailed(at: harness.clock.now)])
    }

    // MARK: Files the app keeps

    @Test func stateThatCannotBeSavedIsReportedInTheMenu() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        // A directory in the way makes the atomic replace of each file fail.
        try FileManager.default.createDirectory(at: harness.paths.runStateFile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: harness.paths.activityFile, withIntermediateDirectories: true)

        await harness.coordinator.run(.sync)

        let warning = try #require(harness.coordinator.persistenceWarning)
        #expect(warning.contains("The latest run state could not be saved"))
        #expect(warning.contains("Recent activity could not be saved"))
        #expect(harness.coordinator.status == .healthy(lastSuccess: harness.clock.now))
    }

    @Test func unreadableSettingsDisableSyncingUntilFixed() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.coordinator.run(.sync)
        let broken = Data(#"{"remoteName": "onedrive","#.utf8)
        try broken.write(to: harness.paths.settingsFile)

        let restarted = harness.makeCoordinator()
        await restarted.load()

        guard case .disabled(let reason) = restarted.status else {
            Issue.record("Expected Disabled, got \(restarted.status)")
            return
        }
        #expect(reason.hasPrefix("settings.json could not be read: "))
        #expect(!restarted.canStartSync)
        await harness.scheduler.fire()
        #expect(await harness.runner.runs == [.sync])
        #expect(try Data(contentsOf: harness.paths.settingsFile) == broken)
        withKnownIssue("An unreadable settings.json stops load() before it restores the latest run and history, so the next skip overwrites activity.json and the login item is not registered") {
            #expect(restarted.latestRun?.outcome == .success)
            #expect(restarted.activity.entries.map(\.outcome) == [.succeeded, .skipped(.configurationUnusable)])
            #expect(harness.loginItem.registrations == 2)
        }

        try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).save(harness.settings)
        await harness.checkScheduler.fire()
        await harness.scheduler.fire()
        #expect(await harness.runner.runs == [.sync, .sync])
        #expect(restarted.status == .healthy(lastSuccess: harness.clock.now))
    }

    @Test func unreadableRunStateKeepsHistoryAndLoginItem() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.coordinator.run(.sync)
        try Data("not json".utf8).write(to: harness.paths.runStateFile)

        let restarted = harness.makeCoordinator()
        await restarted.load()

        #expect(restarted.status == .waitingForFirstSync)
        withKnownIssue("An unreadable run-state.json stops load() before it restores history and registers the login item") {
            #expect(restarted.activity.entries.map(\.outcome) == [.succeeded])
            #expect(harness.loginItem.registrations == 2)
        }
    }

    @Test func unreadableActivityStartsANewHistory() async throws {
        let harness = try Harness()
        try Data("not json".utf8).write(to: harness.paths.activityFile)
        await harness.coordinator.load()
        #expect(harness.coordinator.status == .waitingForFirstSync)
        #expect(harness.coordinator.activity.entries.isEmpty)

        await harness.coordinator.run(.sync)

        #expect(try JSONFileStore<ActivityLog>(fileURL: harness.paths.activityFile).load()?.entries.map(\.outcome) == [.succeeded])
    }

    @Test func syncIntervalFollowsSettings() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        #expect(harness.scheduler.interval == 600)
        #expect(harness.checkScheduler.interval == 60)

        try harness.saveSettings { $0.intervalSeconds = 120 }
        await harness.checkScheduler.fire()
        #expect(harness.scheduler.interval == 120)

        try harness.saveSettings { $0.intervalSeconds = 0 }
        await harness.checkScheduler.fire()
        #expect(harness.scheduler.interval == 600)
        #expect(harness.coordinator.status == .disabled(reason: "Set a positive sync interval in settings.json."))
        await harness.scheduler.fire()
        #expect(await harness.runner.runs.isEmpty)
    }
}
