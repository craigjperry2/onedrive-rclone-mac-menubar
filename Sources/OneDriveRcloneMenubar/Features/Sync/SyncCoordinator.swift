import AppKit
import Foundation

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .disabled(reason: "Loading settings…")
    @Published private(set) var latestRun: SyncRunRecord?
    @Published private(set) var transcriptLines: [String] = []
    @Published private(set) var loginWarning: String?

    private let paths: AppPaths
    private let runner = RcloneProcessRunner()
    private let evaluator = HealthEvaluator()
    private let scheduler = SyncScheduler()
    private var settings: SyncSettings?
    private var awakeSince = Date()
    private var running = false
    private var didLoad = false

    private var settingsStore: JSONFileStore<SyncSettings> { JSONFileStore(fileURL: paths.settingsFile) }
    private var runStateStore: JSONFileStore<SyncRunRecord> { JSONFileStore(fileURL: paths.runStateFile) }
    private var transcriptStore: TranscriptStore { TranscriptStore(fileURL: paths.latestTranscriptFile) }

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.noteWake() }
        }
    }

    func load() {
        guard !didLoad else { return }
        didLoad = true
        do {
            try paths.createDirectories()
            if let saved = try settingsStore.load() { settings = saved } else {
                try settingsStore.save(.initialTemplate)
                settings = .initialTemplate
            }
            latestRun = try runStateStore.load()
            transcriptLines = transcriptStore.displayLines()
            refreshStatus()
            Task { await validateConfiguration() }
            loginWarning = LoginItemManager.register()
        } catch {
            status = .disabled(reason: error.localizedDescription)
        }
    }

    func noteWake() { awakeSince = Date(); refreshStatus() }

    func syncNow() { Task { await start(.sync) } }
    func resync() { Task { await start(.resync) } }

    var canStartSync: Bool {
        guard !running else { return false }
        if case .disabled = status { return false }
        return true
    }

    func refreshStatus(now: Date = Date()) {
        let validation = settings?.validationError() ?? "No valid rclone configuration was found."
        status = evaluatedStatus(validationError: validation, now: now)
    }

    private func validateConfiguration() async {
        guard let settings else { return }
        let validation = await runner.validate(settings)
        if let validation {
            status = .disabled(reason: validation)
            return
        }
        status = evaluatedStatus(validationError: nil)
        scheduler.start(interval: settings.intervalSeconds) { [weak self] in self?.syncNow() }
    }

    private func start(_ kind: RcloneProcessRunner.RunKind) async {
        guard !running else { return }
        guard let settings else { return }
        running = true
        status = .running
        if let validation = await runner.validate(settings) {
            running = false
            status = .disabled(reason: validation)
            return
        }
        let startedAt = Date()
        let result = await runner.run(kind, settings: settings, transcriptURL: paths.latestTranscriptFile)
        let finishedAt = Date()
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
        try? runStateStore.save(record)
        transcriptLines = result.lines
        running = false
        status = evaluatedStatus(validationError: nil, now: finishedAt)
    }

    private func evaluatedStatus(validationError: String?, now: Date = Date()) -> SyncStatus {
        evaluator.status(
            validationError: validationError,
            isRunning: running,
            latestRun: latestRun,
            now: now,
            awakeSince: awakeSince
        )
    }
}
