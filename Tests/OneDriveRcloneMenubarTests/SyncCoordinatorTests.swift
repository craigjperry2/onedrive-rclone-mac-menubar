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

    @Test func failedRunNeedsAttentionAndSuccessfulRunRecordsLastSuccess() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        #expect(harness.coordinator.status == .waitingForFirstSync)

        await harness.runner.setExitCode(7, lastLine: "Bisync aborted")
        await harness.coordinator.run(.sync)
        #expect(harness.coordinator.status == .unhealthy(reason: "Bisync aborted"))
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

    @Test func scheduledFailureNotifiesOnceUntilASyncSucceeds() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.runner.setExitCode(7, lastLine: "Bisync aborted")

        await harness.scheduler.fire()
        await harness.scheduler.fire()
        #expect(harness.notifier.posted == [.syncFailed(at: harness.clock.now)])
        let posted = try #require(harness.notifier.posted.first)
        #expect(posted.title == "OneDrive sync needs attention")
        #expect(posted.body.contains("OneDrive sync"))
        #expect(posted.body.contains("review recent activity"))

        await harness.runner.setExitCode(0)
        await harness.scheduler.fire()
        #expect(harness.notifier.posted.count == 1)

        await harness.runner.setExitCode(7)
        await harness.scheduler.fire()
        #expect(harness.notifier.posted.count == 2)
    }

    @Test func manualFailuresDoNotNotify() async throws {
        let harness = try Harness()
        await harness.coordinator.load()
        await harness.runner.setExitCode(7)

        await harness.coordinator.run(.sync)
        await harness.coordinator.run(.resync)

        #expect(harness.notifier.posted.isEmpty)
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

    func requestAuthorization() {}
    func post(_ notification: SyncNotification) { posted.append(notification) }
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

    func start(interval: TimeInterval, action: @escaping @MainActor () async -> Void) { self.action = action }
    func stop() { action = nil }
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
    private var lastLine: String?
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var runWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func setValidationError(_ error: String?) { validationError = error }
    func setExitCode(_ code: Int32, lastLine: String? = nil) { exitCode = code; self.lastLine = lastLine }
    /// Keeps the next run in progress until `releaseHeldRun()`; later runs finish at once.
    func holdNextRun() { holdNext = true }
    func releaseHeldRun() { held?.resume(); held = nil }

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

    func createRemoteCheckFile(_ settings: SyncSettings) async -> String? {
        remoteCheckFiles += 1
        return nil
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
            await withCheckedContinuation { held = $0 }
        }
        return RcloneProcessRunner.Result(exitCode: exitCode, lines: lastLine.map { [$0] } ?? [], failureReason: lastLine, persistenceWarning: nil)
    }
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
