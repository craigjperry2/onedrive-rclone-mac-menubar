import AppKit
import Foundation
import Testing
@testable import OneDriveRcloneMenubar

@MainActor
struct SyncCoordinatorTests {
    @Test func onlyOneRunAtATimeAcrossScheduledSyncNowAndResync() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.runner.holdNextRun()

        let scheduled = Task { await harness.scheduler.fire() }
        await harness.runner.waitForRuns(1)
        #expect(harness.coordinator.isRunning)
        #expect(harness.coordinator.status == .running)
        #expect(!harness.coordinator.canStartSync)

        await harness.scheduler.fire()
        await harness.coordinator.run(.sync)
        await harness.coordinator.run(.resync)
        #expect(await harness.runner.runs == [.sync])

        await harness.runner.releaseHeldRun()
        await scheduled.value
        #expect(await harness.runner.runs == [.sync])
        #expect(!harness.coordinator.isRunning)
        #expect(harness.coordinator.activity.entries.map(\.outcome) == [.skipped(.previousSyncRunning), .succeeded])
    }

    @Test func stoppedSyncIsRecordedAsStoppedWithoutNeedingAttentionOrNotifying() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.scheduler.fire()
        let lastSuccess = harness.clock.now
        let successfulRun = harness.coordinator.latestRun
        harness.clock.advance(by: 10 * 60)
        await harness.runner.holdNextRun()

        let scheduled = Task { await harness.scheduler.fire() }
        await harness.runner.waitForRuns(2)
        let startedAt = harness.clock.now
        #expect(harness.coordinator.runStartedAt == startedAt)
        harness.clock.advance(by: 3 * 60)
        harness.coordinator.stopSync()
        #expect(harness.coordinator.isStopping)
        await scheduled.value

        #expect(await harness.runner.stoppedRuns == 1)
        #expect(!harness.coordinator.isRunning)
        #expect(!harness.coordinator.isStopping)
        #expect(harness.coordinator.runStartedAt == nil)
        #expect(harness.coordinator.canStartSync)
        #expect(harness.coordinator.status == .healthy(lastSuccess: lastSuccess))
        #expect(harness.coordinator.activity.entries.last == SyncActivity(trigger: .scheduled, outcome: .stopped, startedAt: startedAt, finishedAt: startedAt + 3 * 60))
        #expect(harness.coordinator.latestRun == successfulRun)
        #expect(harness.coordinator.transcriptLines.isEmpty)
        #expect(harness.notifier.posted.isEmpty)
        let restarted = harness.makeCoordinator()
        await restarted.load()
        #expect(restarted.status == .healthy(lastSuccess: lastSuccess))
        #expect(restarted.activity.entries.last?.outcome == .stopped)

        // A stop between a success and a failure does not hide the failure's notification.
        await harness.runner.setExitCode(7, lastLine: "Bisync aborted")
        await harness.scheduler.fire()
        #expect(harness.notifier.posted == [.syncFailed(reason: "Bisync aborted", transcriptLines: ["Bisync aborted"], at: harness.clock.now)])
    }

    /// Stops `kind` part-way through, as choosing Stop Sync does.
    private func stopRun(_ kind: RcloneProcessRunner.RunKind, in harness: Harness) async {
        let runs = await harness.runner.runs.count
        await harness.runner.holdNextRun()
        let run = Task { await harness.coordinator.run(kind) }
        await harness.runner.waitForRuns(runs + 1)
        harness.coordinator.stopSync()
        await run.value
    }

    @Test func stoppedResyncAfterAFirstFailureStillWillTryAgain() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.scheduler.fire()
        await harness.runner.setExitCode(1, lastLine: "Failed to bisync: connection reset by peer")
        await harness.scheduler.fire()
        let retrying = SyncStatus.paused(.retrying(failure: "Failed to bisync: connection reset by peer"))
        #expect(harness.coordinator.status == retrying)

        await stopRun(.resync, in: harness)

        #expect(harness.coordinator.status == retrying)
        #expect(harness.coordinator.activity.entries.last?.outcome == .stopped)
    }

    @Test func stoppedSyncKeepsTheDiagnosisAndFixOfTheRunBeforeIt() async throws {
        let harness = try Harness()
        await harness.runner.actLikeBisync()
        await harness.coordinator.load()
        await harness.scheduler.fire()
        let needsResync = harness.coordinator.status
        #expect(needsResync == .unhealthy(reason: "rclone lost track of the last sync"))

        await stopRun(.sync, in: harness)

        #expect(harness.coordinator.status == needsResync)
        #expect(harness.coordinator.transcriptLines == RcloneOutput.needsResync)
        #expect(MenuBarView.fix(for: harness.coordinator.status, transcriptLines: harness.coordinator.transcriptLines) == .resync)
        let restarted = harness.makeCoordinator()
        await restarted.load()
        #expect(restarted.status == needsResync)
        #expect(restarted.transcriptLines == RcloneOutput.needsResync)
    }

    @Test func completedScheduledSyncIsRecordedAndRestored() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.runner.holdNextRun()
        let startedAt = harness.clock.now

        let scheduled = Task { await harness.scheduler.fire() }
        await harness.runner.waitForRuns(1)
        harness.clock.advance(by: 4 * 60)
        await harness.runner.releaseHeldRun()
        await scheduled.value

        let expected = SyncActivity(trigger: .scheduled, outcome: .succeeded, startedAt: startedAt, finishedAt: startedAt + 4 * 60)
        #expect(harness.coordinator.activity.entries == [expected])
        let restarted = harness.makeCoordinator()
        await restarted.load()
        #expect(restarted.activity.entries == [expected])
    }

    @Test func lowDataNetworkSkipsScheduledSyncsUntilTheNetworkIsNormal() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        harness.network.isLowData = true

        await harness.scheduler.fire()
        let firstSkip = harness.clock.now
        harness.clock.advance(by: 600)
        await harness.scheduler.fire()

        #expect(await harness.runner.runs.isEmpty)
        let skip = try #require(harness.coordinator.activity.entries.last)
        #expect(skip.outcome == .skipped(.lowDataNetwork))
        #expect(skip.startedAt == firstSkip)
        #expect(skip.finishedAt == harness.clock.now)
        #expect(harness.coordinator.activity.consecutiveSkips(for: .lowDataNetwork) == 2)

        harness.network.isLowData = false
        await harness.scheduler.fire()

        #expect(await harness.runner.runs == [.sync])
        #expect(harness.coordinator.activity.entries.last?.outcome == .succeeded)
        #expect(harness.coordinator.activity.consecutiveSkips(for: .lowDataNetwork) == 0)
    }

    @Test func syncNowRunsOnALowDataNetwork() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        harness.network.isLowData = true

        await harness.coordinator.run(.sync)

        #expect(await harness.runner.runs == [.sync])
        #expect(harness.coordinator.activity.entries.map(\.trigger) == [.syncNow])
    }

    @Test func scheduledRunsNeverResync() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.runner.setExitCode(7)

        await harness.scheduler.fire()
        await harness.scheduler.fire()

        #expect(await harness.runner.runs == [.sync, .sync])
    }

    @Test func failedRunWillTryAgainAndSuccessfulRunRecordsLastSuccess() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        #expect(harness.coordinator.status == .waitingForFirstSync)

        await harness.runner.setExitCode(7, lastLine: "Bisync aborted")
        await harness.coordinator.run(.sync)
        #expect(harness.coordinator.status == .paused(.retrying(failure: "Bisync aborted")))
        #expect(harness.coordinator.latestRun?.outcome == .failure)
        #expect(harness.coordinator.latestRun?.lastSuccessAt == nil)

        harness.clock.advance(by: 90)
        await harness.runner.setExitCode(0)
        await harness.coordinator.run(.resync)
        #expect(harness.coordinator.status == .healthy(lastSuccess: harness.clock.now))
        #expect(harness.coordinator.latestRun?.lastSuccessAt == harness.clock.now)
    }

    @Test func persistedRunStateIsRestoredOnLoad() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.coordinator.run(.sync)
        let successAt = harness.clock.now

        let restarted = harness.makeCoordinator()
        await restarted.load()

        #expect(restarted.latestRun == harness.coordinator.latestRun)
        #expect(restarted.latestRun?.lastSuccessAt == successAt)
        #expect(restarted.status == .healthy(lastSuccess: successAt))
    }

    @Test func existingSettingsAreNeverOverwrittenByTheTemplate() async throws {
        let harness = try Harness()
        let before = try Data(contentsOf: harness.paths.settingsFile)

        await harness.coordinator.load()

        #expect(try Data(contentsOf: harness.paths.settingsFile) == before)
    }

    @Test func missingSettingsAreCreatedFromTheTemplateAndDisableSyncing() async throws {
        let harness = try Harness()
        try FileManager.default.removeItem(at: harness.paths.settingsFile)

        await harness.coordinator.load()

        let saved = try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).load()
        #expect(saved == .initialTemplate)
        #expect(harness.coordinator.status == .disabled(reason: SyncSettings.rcloneRequired))

        await harness.scheduler.fire()
        #expect(await harness.runner.runs.isEmpty)
        #expect(harness.coordinator.activity.entries.map(\.outcome) == [.skipped(.setupRequired)])
    }

    @Test func fixedConfigurationIsPickedUpWithoutARestart() async throws {
        let harness = try Harness()
        await harness.runner.setValidationError("The configured OneDrive remote was not found.")
        await harness.coordinator.load()
        #expect(harness.coordinator.status == .disabled(reason: "The configured OneDrive remote was not found."))
        #expect(!harness.coordinator.canStartSync)
        await harness.scheduler.fire()
        #expect(await harness.runner.runs.isEmpty)

        await harness.runner.setValidationError(nil)
        await harness.checkScheduler.fire()
        #expect(harness.coordinator.status == .waitingForFirstSync)
        #expect(harness.coordinator.canStartSync)

        await harness.scheduler.fire()
        #expect(await harness.runner.runs == [.sync])
    }

    @Test func configurationThatBreaksLaterDisablesScheduledSyncs() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.scheduler.fire()

        var settings = harness.settings
        settings.remoteName = "renamed"
        try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).save(settings)
        await harness.runner.setValidationError("The configured OneDrive remote was not found.")
        await harness.checkScheduler.fire()

        #expect(harness.coordinator.status == .disabled(reason: "The configured OneDrive remote was not found."))
        await harness.scheduler.fire()
        #expect(await harness.runner.runs == [.sync])
        #expect(harness.coordinator.activity.entries.map(\.outcome) == [.succeeded, .skipped(.configurationUnusable)])
    }

    @Test func rcloneIsFoundWithoutAPathInSettings() async throws {
        let harness = try Harness()
        var settings = harness.settings
        settings.rcloneExecutablePath = ""
        try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).save(settings)
        harness.rcloneCandidates = ["/does/not/exist/rclone", "/bin/sh", "/bin/zsh"]
        let coordinator = harness.makeCoordinator()

        await coordinator.load()
        await coordinator.run(.sync)

        #expect(coordinator.status == .healthy(lastSuccess: harness.clock.now))
        // Validation at load, then validation and the run itself.
        #expect(await harness.runner.rcloneExecutablePaths == ["/bin/sh", "/bin/sh", "/bin/sh"])
    }

    @Test func loginItemWarningIsRegisteredOnceAndStaysCurrent() async throws {
        let harness = try Harness()
        harness.loginItem.currentWarning = "Allow it in Login Items."
        await harness.coordinator.load()
        #expect(harness.loginItem.registrations == 1)
        #expect(harness.coordinator.loginWarning == "Allow it in Login Items.")

        harness.loginItem.currentWarning = nil
        await harness.checkScheduler.fire()

        #expect(harness.coordinator.loginWarning == nil)
        #expect(harness.loginItem.registrations == 1)
    }

    @Test func scheduledFailureNotifiesOnceThenOnceMoreWhenSyncingWorksAgainEvenAfterARestart() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.runner.setExitCode(7, lastLine: "Bisync aborted")
        let failedAt = harness.clock.now

        await harness.scheduler.fire()
        harness.clock.advance(by: 600)
        await harness.scheduler.fire()
        let failure = SyncNotification.syncFailed(reason: "Bisync aborted", transcriptLines: ["Bisync aborted"], at: failedAt)
        #expect(harness.notifier.posted == [failure])
        #expect(failure.title == "OneDrive sync needs attention")

        let restarted = harness.makeCoordinator()
        await restarted.load()
        await harness.runner.setExitCode(0)
        await restarted.run(.sync)
        await harness.scheduler.fire()
        #expect(harness.notifier.posted == [failure, .syncRecovered])
        #expect(SyncNotification.syncRecovered.title == "OneDrive sync is working again")

        await harness.runner.setExitCode(7, lastLine: "Bisync aborted")
        await harness.scheduler.fire()
        #expect(harness.notifier.posted.count == 3)
    }

    @Test func failuresThatDidNotNotifyGetNoRecoveryNotice() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.runner.setExitCode(7)

        await harness.coordinator.run(.sync)
        await harness.coordinator.run(.resync)
        harness.network.isLowData = true
        await harness.scheduler.fire()
        harness.network.isLowData = false
        await harness.runner.setExitCode(0)
        await harness.scheduler.fire()

        #expect(harness.coordinator.activity.entries.last?.outcome == .succeeded)
        #expect(harness.notifier.posted.isEmpty)
    }

    @Test func notificationSyncNowButtonRunsAnOrdinarySync() async throws {
        let harness = try Harness()
        await harness.coordinator.load()

        harness.notifier.choose(.syncNow)

        try await waitUntil { await harness.runner.runs.count == 1 && !harness.coordinator.isRunning }
        #expect(await harness.runner.runs == [.sync])
        #expect(harness.coordinator.activity.entries.map(\.trigger) == [.syncNow])
    }

    @Test func unusableConfigurationNotifiesOnceButMissingSetupDoesNot() async throws {
        let harness = try Harness()
        await harness.runner.setValidationError(SyncSettings.readyToSetUp)
        await harness.coordinator.load()
        await harness.scheduler.fire()
        #expect(harness.coordinator.activity.consecutiveSkips(for: .setupRequired) == 1)
        #expect(harness.notifier.posted.isEmpty)

        await harness.runner.setValidationError(nil)
        await harness.checkScheduler.fire()
        await harness.scheduler.fire()
        try FileManager.default.removeItem(atPath: harness.settings.configPath)
        await harness.checkScheduler.fire()
        await harness.scheduler.fire()
        await harness.scheduler.fire()

        let notification = SyncNotification.configurationUnusable(SyncSettings.readyToSetUp)
        #expect(harness.notifier.posted == [notification])
        #expect(notification.body.contains("This Mac is ready to configure OneDrive sync. Choose Set Up OneDrive…"))
    }

    @Test func onlyTheThirdLowDataSkipInARowNotifies() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        harness.network.isLowData = true

        await harness.scheduler.fire()
        #expect(harness.coordinator.activity.consecutiveSkips(for: .lowDataNetwork) == 1)
        #expect(harness.notifier.posted.isEmpty)
        await harness.scheduler.fire()
        #expect(harness.notifier.posted.isEmpty)
        await harness.scheduler.fire()
        #expect(harness.notifier.posted == [.lowDataNetwork(skips: 3)])
        await harness.scheduler.fire()
        #expect(harness.notifier.posted.count == 1)
        #expect(harness.notifier.posted[0].body.contains("low-data or metered network"))
    }

    @Test func wakeRestartsTheFirstSyncGracePeriod() async throws {
        let harness = try Harness(awakeFor: 30 * 60)
        await harness.coordinator.load()
        #expect(harness.coordinator.status == .unhealthy(reason: "No successful sync has completed yet."))

        harness.wakeNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(harness.coordinator.status == .waitingForFirstSync)
    }

    @Test func menuSaysWhenTheFolderLastSyncedAndWhenTheScheduleSyncsNext() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        // The one-minute configuration check is not a sync.
        harness.checkScheduler.nextFireDate = harness.clock.now + 50
        func syncTimes() -> String? {
            let coordinator = harness.coordinator!
            return MenuBarView.syncTimes(
                status: coordinator.status,
                latestRun: coordinator.latestRun,
                nextScheduledSync: coordinator.nextScheduledSync,
                onLowDataNetwork: coordinator.isOnLowDataNetworkNow,
                now: harness.clock.now
            )
        }
        harness.scheduler.nextFireDate = harness.clock.now + 600
        #expect(syncTimes() == "Next sync in 10 min")

        await harness.scheduler.fire()
        harness.scheduler.nextFireDate = harness.clock.now + 600
        harness.clock.advance(by: 4 * 60 + 10)
        #expect(syncTimes() == "Synced 4 min ago · next sync in 5 min")

        harness.network.isLowData = true
        #expect(syncTimes() == "Synced 4 min ago\nNext scheduled sync will be skipped: low-data network")

        harness.network.isLowData = false
        await harness.runner.setExitCode(1, lastLine: "Failed to bisync")
        harness.clock.advance(by: 2 * 3600)
        await harness.coordinator.run(.sync)
        harness.scheduler.nextFireDate = harness.clock.now + 300
        #expect(syncTimes() == "Last good sync 2 h ago · next sync in 5 min")
    }
}

@MainActor
final class Harness {
    let root = FileManager.default.temporaryDirectory.appending(path: "sync-coordinator-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let paths: AppPaths
    let settings: SyncSettings
    let runner = FakeRcloneRunner()
    let scheduler = ManualScheduler()
    let checkScheduler = ManualScheduler()
    let wakeNotifications = NotificationCenter()
    let clock = TestClock()
    let loginItem = FakeLoginItem()
    let network = FakeNetwork()
    let notifier = FakeNotifier()
    var rcloneCandidates: [String] = []
    let awakeSince: Date
    private(set) var coordinator: SyncCoordinator!

    init(awakeFor: TimeInterval = 60, localPath: String? = nil) throws {
        paths = AppPaths(rootDirectory: root)
        try paths.createDirectories()
        let configFile = root.appending(path: "rclone.conf")
        try Data("[onedrive]\ntype = alias\n".utf8).write(to: configFile)
        settings = SyncSettings(rcloneExecutablePath: "/bin/sh", configPath: configFile.path(), remoteName: "onedrive", localPath: localPath ?? root.appending(path: "local").path(), intervalSeconds: 600)
        try JSONFileStore<SyncSettings>(fileURL: paths.settingsFile).save(settings)
        awakeSince = clock.now.addingTimeInterval(-awakeFor)
        coordinator = makeCoordinator()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Edits settings.json as a person or another app version would.
    func saveSettings(_ change: (inout SyncSettings) -> Void) throws {
        let store = JSONFileStore<SyncSettings>(fileURL: paths.settingsFile)
        var updated = try store.load() ?? settings
        change(&updated)
        try store.save(updated)
    }

    /// Makes the fake runner act like bisync over the local folder, with RCLONE_TEST
    /// on both sides as setup leaves it. Returns the local check file.
    @discardableResult
    func prepareBisync() async throws -> URL {
        let checkFile = URL(filePath: settings.localPath).appending(path: "RCLONE_TEST")
        try FileManager.default.createDirectory(at: checkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: checkFile)
        await runner.actLikeBisync()
        return checkFile
    }

    /// Puts an executable at `path`, as installing rclone there would.
    @discardableResult
    func installRclone(at path: String) throws -> String {
        try makeExecutableScript("#!/bin/sh\n", at: URL(filePath: path)).path(percentEncoded: false)
    }

    func makeCoordinator() -> SyncCoordinator {
        SyncCoordinator(
            paths: paths,
            runner: runner,
            scheduler: scheduler,
            checkScheduler: checkScheduler,
            wakeNotifications: wakeNotifications,
            loginItem: loginItem,
            rcloneCandidates: rcloneCandidates,
            isOnLowDataNetwork: { [network] in network.isLowData },
            notifier: notifier,
            now: { [clock] in clock.now },
            awakeSince: awakeSince
        )
    }
}

@MainActor
final class FakeLoginItem: LoginItemControlling {
    var currentWarning: String?
    private(set) var registrations = 0

    func registerIfNeeded() { registrations += 1 }
    func warning() -> String? { currentWarning }
}

@MainActor
final class FakeNotifier: SyncNotifying {
    private(set) var posted: [SyncNotification] = []
    private var syncNow: (@MainActor () -> Void)?

    func start(syncNow: @escaping @MainActor () -> Void) { self.syncNow = syncNow }
    func post(_ notification: SyncNotification) { posted.append(notification) }
    /// What clicking a notification's button does.
    func choose(_ action: SyncNotification.Action) {
        switch action {
        case .syncNow: syncNow?()
        case .showLog: break
        }
    }
}

@MainActor
final class FakeNetwork {
    var isLowData = false
}

@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(by interval: TimeInterval) { now += interval }
}

@MainActor
final class ManualScheduler: RepeatingScheduler {
    private var action: (@MainActor () async -> Void)?
    private(set) var interval: TimeInterval?
    /// Tests set when the schedule next fires; it does not move on its own.
    var nextFireDate: Date?

    func start(interval: TimeInterval, action: @escaping @MainActor () async -> Void) { self.interval = interval; self.action = action }
    func stop() { action = nil; interval = nil; nextFireDate = nil }
    func fire() async { await action?() }
}

actor FakeRcloneRunner: RcloneRunning {
    private(set) var runs: [RcloneProcessRunner.RunKind] = []
    /// The rclone executable of every validation and run, in order.
    private(set) var rcloneExecutablePaths: [String] = []
    private(set) var remoteExists = false
    private(set) var authorizeCalls = 0
    private(set) var remoteCheckFiles = 0
    private var authorization: CheckedContinuation<String?, Never>?
    private var validationError: String?
    private var exitCode: Int32 = 0
    private var output: [String] = []
    private var actsLikeBisync = false
    private var hasListings = false
    private(set) var remoteHasCheckFile = true
    private var holdNext = false
    /// Resumed with true when the run is stopped, false when it is released.
    private var held: CheckedContinuation<Bool, Never>?
    /// Runs stopped by cancelling the calling task, as Stop Sync does.
    private(set) var stoppedRuns = 0
    private var runWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func setValidationError(_ error: String?) { validationError = error }
    func setExitCode(_ code: Int32, lastLine: String? = nil) { exitCode = code; output = lastLine.map { [$0] } ?? [] }
    /// From now on, runs act like the app's `rclone bisync` with what rclone 1.75
    /// prints: a sync fails until a resync has run, and any run fails while
    /// RCLONE_TEST is missing on OneDrive or in the local folder.
    func actLikeBisync() { actsLikeBisync = true }
    func deleteRemoteCheckFile() { remoteHasCheckFile = false }
    func setOutput(_ lines: [String], exitCode code: Int32) { exitCode = code; output = lines }
    /// Keeps the next run in progress until `releaseHeldRun()` or cancellation; later
    /// runs finish at once.
    func holdNextRun() { holdNext = true }
    func releaseHeldRun() { held?.resume(returning: false); held = nil }
    private func stopHeldRun() { held?.resume(returning: true); held = nil }

    /// Returns once `count` runs have started, without polling or sleeping.
    func waitForRuns(_ count: Int) async {
        guard runs.count < count else { return }
        await withCheckedContinuation { runWaiters.append((count, $0)) }
    }

    // Like the real runner, an incomplete settings file fails before rclone is asked.
    func hasRemote(_ settings: SyncSettings) async -> Bool { remoteExists }

    /// Waits like rclone does for the browser, until `finishAuthorization` or cancellation.
    func authorize(_ settings: SyncSettings, onSignInURL: @escaping @Sendable (URL) -> Void) async -> String? {
        authorizeCalls += 1
        onSignInURL(URL(string: "http://127.0.0.1:53682/auth?state=test")!)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { authorization = $0 }
        } onCancel: {
            Task { await self.finishAuthorization(failure: "terminated") }
        }
    }

    func finishAuthorization(failure: String?) {
        if failure == nil { remoteExists = true }
        authorization?.resume(returning: failure)
        authorization = nil
    }

    var isWaitingForAuthorization: Bool { authorization != nil }

    private var remoteCheckFileFailure: String?
    func setRemoteCheckFileFailure(_ failure: String?) { remoteCheckFileFailure = failure }

    func createRemoteCheckFile(_ settings: SyncSettings) async -> String? {
        remoteCheckFiles += 1
        if remoteCheckFileFailure == nil { remoteHasCheckFile = true }
        return remoteCheckFileFailure
    }

    func validate(_ settings: SyncSettings) async -> String? {
        rcloneExecutablePaths.append(settings.rcloneExecutablePath)
        return settings.configurationError() ?? validationError
    }

    func run(_ kind: RcloneProcessRunner.RunKind, settings: SyncSettings, transcriptURL: URL) async -> RcloneProcessRunner.Result {
        runs.append(kind)
        rcloneExecutablePaths.append(settings.rcloneExecutablePath)
        runWaiters.filter { $0.count <= runs.count }.forEach { $0.continuation.resume() }
        runWaiters.removeAll { $0.count <= runs.count }
        if holdNext {
            holdNext = false
            // Like rclone after SIGTERM: bisync shuts down gracefully and exits 128 + 15.
            let stopped = await withTaskCancellationHandler {
                await withCheckedContinuation { held = $0 }
            } onCancel: {
                Task { await self.stopHeldRun() }
            }
            if stopped {
                stoppedRuns += 1
                let lines = ["NOTICE: Signal received: terminated", "NOTICE: Graceful shutdown completed successfully."]
                try? Data(lines.map { $0 + "\n" }.joined().utf8).write(to: transcriptURL)
                return RcloneProcessRunner.Result(exitCode: 143, lines: lines, failureReason: lines.last, persistenceWarning: nil)
            }
        }
        let (exitCode, lines) = actsLikeBisync ? bisync(kind, localPath: settings.localPath) : (exitCode, output)
        // Like the real runner: each run replaces the transcript, the result has its last
        // 30 lines, and bisync failures are reported by the problem they name.
        try? Data(lines.map { $0 + "\n" }.joined().utf8).write(to: transcriptURL)
        return RcloneProcessRunner.Result(exitCode: exitCode, lines: lines.suffix(30), failureReason: actsLikeBisync ? SyncProblem(rcloneOutput: lines)?.name : lines.last, persistenceWarning: nil)
    }

    // A resync that fails the access check also loses the listings, as in rclone.
    private func bisync(_ kind: RcloneProcessRunner.RunKind, localPath: String) -> (Int32, [String]) {
        if kind == .sync, !hasListings { return (7, RcloneOutput.needsResync) }
        let folderHasCheckFile = FileManager.default.fileExists(atPath: URL(filePath: localPath).appending(path: "RCLONE_TEST").path(percentEncoded: false))
        switch (remoteHasCheckFile, folderHasCheckFile) {
        case (true, true): hasListings = hasListings || kind == .resync; return (0, [])
        case (false, true): hasListings = hasListings && kind == .sync; return (7, RcloneOutput.checkFileMissingOnOneDrive)
        case (true, false): hasListings = hasListings && kind == .sync; return (7, RcloneOutput.checkFileMissingLocally)
        case (false, false): hasListings = hasListings && kind == .sync; return (7, RcloneOutput.checkFileMissingOnBothSides)
        }
    }

    func version(_ settings: SyncSettings) async -> String? { "rclone v1.75.2" }
}

private struct ConditionTimedOut: Error {}

/// Lets queued main-actor work run until `condition` holds, without sleeping.
@MainActor
func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<10_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw ConditionTimedOut()
}
