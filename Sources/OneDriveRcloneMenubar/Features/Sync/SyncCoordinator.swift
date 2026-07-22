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
        status = evaluator.status(validationError: validation, isRunning: running, latestRun: latestRun, now: now, awakeSince: awakeSince)
    }

    private func validateConfiguration() async {
        guard let settings else { return }
        let validation = await runner.validate(settings)
        guard validation == nil else { status = .disabled(reason: validation!); return }
        status = evaluator.status(validationError: nil, isRunning: running, latestRun: latestRun, now: Date(), awakeSince: awakeSince)
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
        let record = SyncRunRecord(startedAt: startedAt, finishedAt: finishedAt, outcome: succeeded ? .success : .failure, failureReason: succeeded ? nil : result.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "rclone exited with status \(result.exitCode).", lastSuccessAt: succeeded ? finishedAt : previousSuccess)
        latestRun = record
        try? runStateStore.save(record)
        transcriptLines = transcriptStore.displayLines()
        running = false
        status = evaluator.status(validationError: nil, isRunning: false, latestRun: latestRun, now: finishedAt, awakeSince: awakeSince)
    }
}
