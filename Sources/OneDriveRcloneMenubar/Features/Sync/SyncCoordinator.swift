import AppKit
import Darwin
import Foundation

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .disabled(reason: "Loading settings…")
    @Published private(set) var latestRun: SyncRunRecord?
    @Published private(set) var transcriptLines: [String] = []
    @Published private(set) var loginWarning: String?
    @Published private(set) var persistenceWarning: String?
    @Published private(set) var activity = ActivityLog()

    private let paths: AppPaths
    let runner: any RcloneRunning
    private let evaluator = HealthEvaluator()
    private let scheduler: any RepeatingScheduler
    private let checkScheduler: any RepeatingScheduler
    private let loginItem: any LoginItemControlling
    private let rcloneCandidates: [String]
    private let isOnLowDataNetwork: @MainActor () -> Bool
    private let notifier: any SyncNotifying
    private let now: @MainActor () -> Date
    private(set) var settings: SyncSettings?
    private var remoteValidationError: String?
    private var validatedConfiguration: ConfigurationSnapshot?
    private var scheduledInterval: TimeInterval?
    private var awakeSince: Date
    private var running = false
    private var didLoad = false

    private var settingsStore: JSONFileStore<SyncSettings> { JSONFileStore(fileURL: paths.settingsFile) }
    private var runStateStore: JSONFileStore<SyncRunRecord> { JSONFileStore(fileURL: paths.runStateFile) }
    private var transcriptStore: TranscriptStore { TranscriptStore(fileURL: paths.latestTranscriptFile) }
    private var activityStore: JSONFileStore<ActivityLog> { JSONFileStore(fileURL: paths.activityFile) }

    /// The defaults are the real dependencies; tests pass fakes so that no rclone
    /// process, timer, login item, rclone installation, network, notification, or
    /// wall-clock time is involved.
    init(
        paths: AppPaths = AppPaths(),
        runner: any RcloneRunning = RcloneProcessRunner(),
        scheduler: any RepeatingScheduler = SyncScheduler(),
        checkScheduler: any RepeatingScheduler = SyncScheduler(),
        // NSWorkspace posts wake notifications on its own center, not the default one.
        wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        loginItem: any LoginItemControlling = LoginItemManager(),
        rcloneCandidates: [String] = SyncSettings.rcloneCandidates(),
        isOnLowDataNetwork: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isLowDataNetwork },
        notifier: any SyncNotifying = UserNotifier(),
        now: @escaping @MainActor () -> Date = Date.init,
        awakeSince: Date = SystemWakeTime.current()
    ) {
        self.paths = paths
        self.runner = runner
        self.scheduler = scheduler
        self.checkScheduler = checkScheduler
        self.loginItem = loginItem
        self.rcloneCandidates = rcloneCandidates
        self.isOnLowDataNetwork = isOnLowDataNetwork
        self.notifier = notifier
        self.now = now
        self.awakeSince = awakeSince
        wakeNotifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteWake() }
        }
        // Opening the status menu picks up configuration and login item changes made
        // while the app runs.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reloadConfiguration() }
        }
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            try paths.createDirectories()
            if try settingsStore.load() == nil { try settingsStore.save(.initialTemplate) }
            latestRun = try runStateStore.load()
            transcriptLines = transcriptStore.displayLines()
            // History is informational, so an unreadable file starts a new one.
            activity = (try? activityStore.load()) ?? ActivityLog()
            loginItem.registerIfNeeded()
            notifier.start { [weak self] in self?.syncNow() }
        } catch {
            status = .disabled(reason: error.localizedDescription)
        }
        checkScheduler.start(interval: 60) { [weak self] in await self?.reloadConfiguration() }
        await reloadConfiguration()
    }

    func noteWake() { awakeSince = now(); refreshStatus() }

    func syncNow() { Task { await run(.sync) } }
    func resync() { Task { await run(.resync) } }

    /// Puts back the RCLONE_TEST file that bisync's --check-access found missing,
    /// then syncs. Returns why the file could not be created, or nil. A missing
    /// local folder is not recreated, since that is a different problem.
    func recreateCheckFile(missingFrom side: SyncProblem.Side) async -> String? {
        guard !running, let settings else { return nil }
        if side != .oneDrive {
            let checkFile = URL(filePath: settings.localPath).appending(path: "RCLONE_TEST")
            if !FileManager.default.fileExists(atPath: checkFile.path(percentEncoded: false)) {
                do {
                    try Data().write(to: checkFile)
                } catch {
                    return "RCLONE_TEST could not be created in \(settings.localPath): \(error.localizedDescription)"
                }
            }
        }
        if side != .localFolder, let failure = await runner.createRemoteCheckFile(settings) { return failure }
        await run(.sync)
        return nil
    }

    var canStartSync: Bool {
        guard !running else { return false }
        if case .disabled = status { return false }
        return true
    }

    var isRunning: Bool { running }

    func refreshStatus() {
        guard let settings else {
            status = .disabled(reason: "No valid rclone configuration was found.")
            return
        }
        status = evaluatedStatus(validationError: remoteValidationError ?? settings.configurationError())
    }

    /// Rereads settings.json and revalidates the rclone configuration, so fixing
    /// either while the app runs enables syncing, and breaking either disables it.
    /// rclone is asked again only when the settings or the rclone config file changed
    /// since the last successful validation. The login item state is refreshed too.
    func reloadConfiguration() async {
        loginWarning = loginItem.warning()
        guard !running else { return }
        do {
            settings = try settingsStore.load()?.resolvingRclone(candidates: rcloneCandidates)
        } catch {
            settings = nil
            validatedConfiguration = nil
            scheduleSyncs(every: nil)
            status = .disabled(reason: "settings.json could not be read: \(error.localizedDescription)")
            return
        }
        scheduleSyncs(every: settings?.intervalSeconds)
        guard let settings else {
            validatedConfiguration = nil
            refreshStatus()
            return
        }
        let snapshot = ConfigurationSnapshot(settings: settings)
        if snapshot != validatedConfiguration {
            let validation = await runner.validate(settings)
            // A newer reload or a run may have replaced the settings while rclone ran.
            guard !running, self.settings == settings else { return }
            applyValidation(validation, snapshot: snapshot)
        }
        refreshStatus()
    }

    private func applyValidation(_ validation: String?, snapshot: ConfigurationSnapshot?) {
        remoteValidationError = validation
        validatedConfiguration = validation == nil ? snapshot : nil
    }

    /// The schedule keeps firing while the configuration is unusable, so each
    /// scheduled sync that cannot run is recorded with the reason.
    private func scheduleSyncs(every interval: TimeInterval?) {
        let interval = interval.flatMap { $0 > 0 ? $0 : nil } ?? SyncSettings.initialTemplate.intervalSeconds
        guard scheduledInterval != interval else { return }
        scheduledInterval = interval
        scheduler.start(interval: interval) { [weak self] in await self?.runScheduledSync() }
    }

    private var configurationProblem: String? {
        guard let settings else { return "No settings" }
        return remoteValidationError ?? settings.configurationError()
    }

    /// The settings guided setup starts from: the saved ones, or the template, with
    /// rclone found as usual.
    func setupSettings() -> SyncSettings {
        ((try? settingsStore.load()) ?? .initialTemplate).resolvingRclone(candidates: rcloneCandidates)
    }

    /// Saves the folder chosen in guided setup and applies the configuration at once.
    /// The rest of settings.json, including an empty rclone path, is kept.
    func completeSetup(localPath: String) async throws {
        var saved = try settingsStore.load() ?? .initialTemplate
        saved.localPath = localPath
        try settingsStore.save(saved)
        await reloadConfiguration()
    }

    /// What the schedule does when it fires: starts a sync, or records why it did not.
    /// Only scheduled syncs avoid low-data networks; Sync Now always runs.
    func runScheduledSync() async {
        if running { return recordSkip(.previousSyncRunning) }
        if configurationProblem != nil { return recordConfigurationSkip() }
        if isOnLowDataNetwork() {
            recordSkip(.lowDataNetwork)
            return refreshStatus()
        }
        await run(.sync, scheduled: true)
    }

    /// A configuration that has never synced still needs setup; one that has synced
    /// before has stopped working.
    private func recordConfigurationSkip() {
        recordSkip(latestRun == nil ? .setupRequired : .configurationUnusable)
    }

    private func recordSkip(_ reason: SkipReason) {
        let at = now()
        recordActivity(SyncActivity(trigger: .scheduled, outcome: .skipped(reason), startedAt: at, finishedAt: at))
    }

    private func recordActivity(_ entry: SyncActivity) {
        let previousRunFailed = activity.entries.last { !$0.isSkip }.map { $0.outcome != .succeeded } ?? false
        activity.record(entry)
        let notification = notification(for: entry, previousRunFailed: previousRunFailed)
        if let notification { activity.problemNotified = notification != .syncRecovered }
        do {
            try activityStore.save(activity)
        } catch {
            persistenceWarning = joinedWarning(persistenceWarning, "Recent activity could not be saved: \(error.localizedDescription)")
        }
        if let notification { notifier.post(notification) }
    }

    /// Only problems with scheduled syncs notify, since the user is watching when they
    /// choose Sync Now or Resync. Each problem notifies once when it starts, not on
    /// every scheduled sync while it lasts, and a single low-data skip stays quiet.
    /// The first sync of any kind to succeed after a notified problem says so once.
    private func notification(for entry: SyncActivity, previousRunFailed: Bool) -> SyncNotification? {
        switch (entry.trigger, entry.outcome) {
        case (_, .succeeded) where activity.problemNotified == true:
            .syncRecovered
        case (.scheduled, .failed(let reason)) where !previousRunFailed:
            .syncFailed(reason: reason, transcriptLines: transcriptLines, at: entry.startedAt)
        case (.scheduled, .skipped(.configurationUnusable)) where activity.consecutiveSkips(for: .configurationUnusable) == 1:
            .configurationUnusable(configurationProblem ?? SkipReason.configurationUnusable.explanation)
        case (.scheduled, .skipped(.lowDataNetwork)) where activity.consecutiveSkips(for: .lowDataNetwork) == Self.lowDataSkipsBeforeNotifying:
            .lowDataNetwork(skips: Self.lowDataSkipsBeforeNotifying)
        default:
            nil
        }
    }

    static let lowDataSkipsBeforeNotifying = 3

    /// Runs rclone unless a run is already in progress. Scheduled runs, Sync Now,
    /// and Resync all go through here, so only one rclone process runs at a time.
    func run(_ kind: RcloneProcessRunner.RunKind, scheduled: Bool = false) async {
        guard !running else { return }
        guard let settings else { return }
        let trigger: SyncActivity.Trigger = scheduled ? .scheduled : kind == .resync ? .resync : .syncNow
        running = true
        refreshStatus()
        if let availabilityError = settings.availabilityError() {
            finishUnavailableRun(reason: availabilityError, trigger: trigger)
            return
        }
        if let validation = await runner.validate(settings) {
            running = false
            applyValidation(validation, snapshot: nil)
            status = .disabled(reason: validation)
            if scheduled { recordConfigurationSkip() }
            return
        }
        applyValidation(nil, snapshot: ConfigurationSnapshot(settings: settings))
        let startedAt = now()
        let result = await runner.run(kind, settings: settings, transcriptURL: paths.latestTranscriptFile)
        let finishedAt = now()
        let previousSuccess = latestRun?.lastSuccessAt
        let succeeded = result.exitCode == 0
        let failureReason = succeeded
            ? nil
            : result.failureReason ?? "rclone exited with status \(result.exitCode)."
        let lastSuccessAt = succeeded ? finishedAt : previousSuccess
        let record = SyncRunRecord(
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: succeeded ? .success : .failure,
            failureReason: failureReason,
            lastSuccessAt: lastSuccessAt
        )
        latestRun = record
        persistenceWarning = result.persistenceWarning
        do {
            try runStateStore.save(record)
        } catch {
            persistenceWarning = joinedWarning(persistenceWarning, "The latest run state could not be saved: \(error.localizedDescription)")
        }
        transcriptLines = result.lines
        recordActivity(SyncActivity(trigger: trigger, outcome: failureReason.map { SyncActivity.Outcome.failed(reason: $0) } ?? .succeeded, startedAt: startedAt, finishedAt: finishedAt))
        running = false
        status = evaluatedStatus(validationError: nil)
    }

    private func finishUnavailableRun(reason: String, trigger: SyncActivity.Trigger) {
        let finishedAt = now()
        let record = SyncRunRecord(
            startedAt: finishedAt,
            finishedAt: finishedAt,
            outcome: .failure,
            failureReason: reason,
            lastSuccessAt: latestRun?.lastSuccessAt
        )
        latestRun = record
        let data = Data((reason + "\n").utf8)
        transcriptLines = [reason]
        do {
            try transcriptStore.replace(with: data)
            try runStateStore.save(record)
            persistenceWarning = nil
        } catch {
            persistenceWarning = "The failed run could not be fully saved: \(error.localizedDescription)"
        }
        recordActivity(SyncActivity(trigger: trigger, outcome: .failed(reason: reason), startedAt: finishedAt, finishedAt: finishedAt))
        running = false
        status = evaluatedStatus(validationError: nil)
    }

    private func evaluatedStatus(validationError: String?) -> SyncStatus {
        evaluator.status(
            validationError: validationError,
            volumeError: settings?.availabilityError(),
            isRunning: running,
            latestRun: latestRun,
            transcript: transcriptLines,
            activity: activity,
            now: now(),
            awakeSince: awakeSince
        )
    }
}

/// The inputs that rclone validation depends on. The config file's modification
/// date stands in for its contents, so editing rclone.conf triggers revalidation.
private struct ConfigurationSnapshot: Equatable {
    let settings: SyncSettings
    let configModified: Date?

    init(settings: SyncSettings) {
        self.settings = settings
        configModified = (try? FileManager.default.attributesOfItem(atPath: settings.configPath))?[.modificationDate] as? Date
    }
}

private func joinedWarning(_ first: String?, _ second: String) -> String {
    first.map { "\($0) \(second)" } ?? second
}

enum SystemWakeTime {
    static func current(now: Date = Date()) -> Date {
        var wakeTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.waketime", &wakeTime, &size, nil, 0) == 0 else { return now }
        let wakeDate = Date(timeIntervalSince1970: TimeInterval(wakeTime.tv_sec) + TimeInterval(wakeTime.tv_usec) / 1_000_000)
        return wakeDate <= now && wakeDate.timeIntervalSince1970 > 0 ? wakeDate : now
    }
}
