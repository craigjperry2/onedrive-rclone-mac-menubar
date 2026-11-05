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

    private let paths: AppPaths
    private let runner: any RcloneRunning
    private let evaluator = HealthEvaluator()
    private let scheduler: any RepeatingScheduler
    private let checkScheduler: any RepeatingScheduler
    private let registerLoginItem: @MainActor () -> String?
    private let now: @MainActor () -> Date
    private var settings: SyncSettings?
    private var remoteValidationError: String?
    private var validatedConfiguration: ConfigurationSnapshot?
    private var scheduledInterval: TimeInterval?
    private var awakeSince: Date
    private var running = false
    private var didLoad = false

    private var settingsStore: JSONFileStore<SyncSettings> { JSONFileStore(fileURL: paths.settingsFile) }
    private var runStateStore: JSONFileStore<SyncRunRecord> { JSONFileStore(fileURL: paths.runStateFile) }
    private var transcriptStore: TranscriptStore { TranscriptStore(fileURL: paths.latestTranscriptFile) }

    /// The defaults are the real dependencies; tests pass fakes so that no rclone
    /// process, timer, login item, or wall-clock time is involved.
    init(
        paths: AppPaths = AppPaths(),
        runner: any RcloneRunning = RcloneProcessRunner(),
        scheduler: any RepeatingScheduler = SyncScheduler(),
        checkScheduler: any RepeatingScheduler = SyncScheduler(),
        // NSWorkspace posts wake notifications on its own center, not the default one.
        wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        registerLoginItem: @escaping @MainActor () -> String? = LoginItemManager.register,
        now: @escaping @MainActor () -> Date = Date.init,
        awakeSince: Date = SystemWakeTime.current()
    ) {
        self.paths = paths
        self.runner = runner
        self.scheduler = scheduler
        self.checkScheduler = checkScheduler
        self.registerLoginItem = registerLoginItem
        self.now = now
        self.awakeSince = awakeSince
        wakeNotifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteWake() }
        }
        // Opening the status menu picks up configuration fixed while the app runs.
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
            loginWarning = registerLoginItem()
        } catch {
            status = .disabled(reason: error.localizedDescription)
        }
        checkScheduler.start(interval: 60) { [weak self] in await self?.reloadConfiguration() }
        await reloadConfiguration()
    }

    func noteWake() { awakeSince = now(); refreshStatus() }

    func syncNow() { Task { await run(.sync) } }
    func resync() { Task { await run(.resync) } }

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
        if let validation = remoteValidationError ?? settings.configurationError() {
            status = evaluatedStatus(validationError: validation)
        } else if let availabilityError = settings.availabilityError() {
            status = .unhealthy(reason: availabilityError)
        } else {
            status = evaluatedStatus(validationError: nil)
        }
    }

    /// Rereads settings.json and revalidates the rclone configuration, so fixing
    /// either while the app runs enables syncing, and breaking either disables it.
    /// rclone is asked again only when the settings or the rclone config file changed
    /// since the last successful validation.
    func reloadConfiguration() async {
        guard !running else { return }
        do {
            settings = try settingsStore.load()
        } catch {
            settings = nil
            validatedConfiguration = nil
            stopScheduledSyncs()
            status = .disabled(reason: "settings.json could not be read: \(error.localizedDescription)")
            return
        }
        guard let settings else {
            validatedConfiguration = nil
            stopScheduledSyncs()
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
        guard validation == nil, let settings else {
            validatedConfiguration = nil
            stopScheduledSyncs()
            return
        }
        validatedConfiguration = snapshot
        guard scheduledInterval != settings.intervalSeconds else { return }
        scheduledInterval = settings.intervalSeconds
        scheduler.start(interval: settings.intervalSeconds) { [weak self] in await self?.run(.sync) }
    }

    private func stopScheduledSyncs() {
        scheduler.stop()
        scheduledInterval = nil
    }

    /// Runs rclone unless a run is already in progress. Scheduled runs, Sync Now,
    /// and Resync all go through here, so only one rclone process runs at a time.
    func run(_ kind: RcloneProcessRunner.RunKind) async {
        guard !running else { return }
        guard let settings else { return }
        running = true
        refreshStatus()
        if let availabilityError = settings.availabilityError() {
            finishUnavailableRun(reason: availabilityError)
            return
        }
        if let validation = await runner.validate(settings) {
            running = false
            applyValidation(validation, snapshot: nil)
            status = .disabled(reason: validation)
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
        running = false
        status = evaluatedStatus(validationError: nil)
    }

    private func finishUnavailableRun(reason: String) {
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
        running = false
        status = .unhealthy(reason: reason)
    }

    private func evaluatedStatus(validationError: String?) -> SyncStatus {
        evaluator.status(
            validationError: validationError,
            isRunning: running,
            latestRun: latestRun,
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
