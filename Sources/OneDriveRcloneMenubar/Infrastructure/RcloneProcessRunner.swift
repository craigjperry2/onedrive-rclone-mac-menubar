import Darwin
import Foundation

protocol RcloneRunning: Sendable {
    func validate(_ settings: SyncSettings) async -> String?
    func run(_ kind: RcloneProcessRunner.RunKind, settings: SyncSettings, transcriptURL: URL) async -> RcloneProcessRunner.Result
    func hasRemote(_ settings: SyncSettings) async -> Bool
    /// Creates the OneDrive remote through rclone's browser sign-in, returning a
    /// failure reason or nil. Cancelling the calling task stops rclone.
    func authorize(_ settings: SyncSettings, onSignInURL: @escaping @Sendable (URL) -> Void) async -> String?
    /// Creates the RCLONE_TEST file that `--check-access` needs on the OneDrive side.
    func createRemoteCheckFile(_ settings: SyncSettings) async -> String?
    /// The first line of `rclone version`, such as "rclone v1.75.2", or nil.
    func version(_ settings: SyncSettings) async -> String?
}

actor RcloneProcessRunner: RcloneRunning {
    /// `syncAllowingDeletes` is one sync without bisync's `--max-delete` safety abort.
    enum RunKind { case sync, syncAllowingDeletes, resync }
    struct Result: Sendable {
        let exitCode: Int32
        let lines: [String]
        let failureReason: String?
        let persistenceWarning: String?
    }

    private let timeout: TimeInterval

    init(timeout: TimeInterval = 30 * 60) {
        self.timeout = timeout
    }

    func validate(_ settings: SyncSettings) async -> String? {
        if let error = settings.configurationError() { return error }
        let result = await runProcess(settings, arguments: ["listremotes"])
        guard result.exitCode == 0 else { return "Unable to read the rclone configuration." }
        return result.lines.contains("\(settings.remoteName):")
            ? nil
            : SyncSettings.readyToSetUp
    }

    // rclone colours bisync's messages even when its output is a pipe unless told
    // not to. At the default log level a successful run logs nothing, so its final
    // stats are raised to NOTICE for the menu's summary of what changed.
    func run(_ kind: RunKind, settings: SyncSettings, transcriptURL: URL) async -> Result {
        var arguments = [
            "bisync", "\(settings.remoteName):", settings.localPath,
            "--check-access", "--create-empty-src-dirs", "--exclude=/Personal Vault/**",
            "--modify-window", "2s", "--resilient", "--fast-list", "--onedrive-delta",
            "--color", "NEVER", "--stats-log-level", "NOTICE"
        ]
        switch kind {
        case .sync: break
        case .syncAllowingDeletes: arguments.append("--force")
        case .resync: arguments.append("--resync")
        }
        return await runProcess(settings, arguments: arguments, transcriptURL: transcriptURL)
    }

    func hasRemote(_ settings: SyncSettings) async -> Bool {
        let result = await runProcess(settings, arguments: ["listremotes"])
        return result.exitCode == 0 && result.lines.contains("\(settings.remoteName):")
    }

    // rclone takes the default answer to the questions after sign-in, which picks
    // the account's own OneDrive. --no-output keeps the token out of the output.
    func authorize(_ settings: SyncSettings, onSignInURL: @escaping @Sendable (URL) -> Void) async -> String? {
        let result = await runProcess(settings, arguments: ["config", "create", settings.remoteName, "onedrive", "--no-output"]) { text in
            if let url = Self.signInURL(in: text) { onSignInURL(url) }
        }
        return result.exitCode == 0 ? nil : result.failureReason ?? "rclone could not connect to OneDrive."
    }

    func createRemoteCheckFile(_ settings: SyncSettings) async -> String? {
        let result = await runProcess(settings, arguments: ["touch", "\(settings.remoteName):RCLONE_TEST"])
        return result.exitCode == 0 ? nil : result.failureReason ?? "rclone could not create RCLONE_TEST in OneDrive."
    }

    func version(_ settings: SyncSettings) async -> String? {
        let result = await runProcess(settings, arguments: ["version"])
        return result.exitCode == 0 ? result.lines.first : nil
    }

    /// The local page rclone prints in case the browser does not open by itself.
    static func signInURL(in output: String) -> URL? {
        output.firstMatch(of: /http:\/\/127\.0\.0\.1:\d+\/auth\?state=[A-Za-z0-9_-]+/).flatMap { URL(string: String($0.output)) }
    }

    private func runProcess(
        _ settings: SyncSettings,
        arguments: [String],
        transcriptURL: URL? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> Result {
        await runProcess(executable: settings.rcloneExecutablePath, arguments: arguments, environment: ["RCLONE_CONFIG": settings.configPath], transcriptURL: transcriptURL, onOutput: onOutput)
    }

    private func runProcess(executable: String, arguments: [String], environment: [String: String], transcriptURL: URL?, onOutput: (@Sendable (String) -> Void)?) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }

        if let transcriptURL {
            let directoryURL = transcriptURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: transcriptURL.path(percentEncoded: false), contents: nil)
            guard let transcriptHandle = try? FileHandle(forWritingTo: transcriptURL) else {
                return Result(exitCode: -1, lines: [], failureReason: "Unable to create the rclone output log.", persistenceWarning: nil)
            }
            try? transcriptHandle.close()
        }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputTask = Task.detached(priority: .utility) {
            BoundedOutputReader.read(from: outputPipe.fileHandleForReading, onOutput: onOutput)
        }

        // Cancelling the calling task stops rclone, like a timeout without the reason.
        let execution = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion = ProcessCompletion()
                let finish: @Sendable () -> Void = {
                    guard completion.claimCompletion() else { return }
                    let timedOut = completion.didTimeOut()
                    let exitCode: Int32 = timedOut ? -1 : process.terminationStatus
                    continuation.resume(returning: ProcessExecution(exitCode: exitCode, timedOut: timedOut, launchError: nil))
                }
                process.terminationHandler = { _ in finish() }
                do {
                    try process.run()
                } catch {
                    try? outputPipe.fileHandleForWriting.close()
                    continuation.resume(returning: ProcessExecution(exitCode: -1, timedOut: false, launchError: error.localizedDescription))
                    return
                }
                try? outputPipe.fileHandleForWriting.close()
                let timeoutTask = Task.detached { [timeout] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    guard process.isRunning, completion.markTimedOutIfNeeded() else { return }
                    process.terminate()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                completion.installTimeoutTask(timeoutTask)
                if Task.isCancelled { process.terminate() }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        let outputData = await outputTask.value
        let lines = TranscriptStore.displayLines(from: outputData)
        var persistenceWarning: String?
        if let transcriptURL {
            do {
                try TranscriptStore(fileURL: transcriptURL).replace(with: outputData)
            } catch {
                persistenceWarning = "The latest transcript could not be saved: \(error.localizedDescription)"
            }
        }
        let timeoutReason = execution.timedOut ? "rclone timed out after \(Int(timeout / 60)) minutes." : nil
        // All of the kept output, not just the displayed end, since the cause comes before bisync's summary.
        let problem = SyncProblem(rcloneOutput: String(decoding: outputData, as: UTF8.self).components(separatedBy: .newlines))
        return Result(
            exitCode: execution.exitCode,
            lines: lines,
            failureReason: execution.launchError ?? timeoutReason ?? problem?.name,
            persistenceWarning: persistenceWarning
        )
    }
}

private struct ProcessExecution: Sendable {
    let exitCode: Int32
    let timedOut: Bool
    let launchError: String?
}

private enum BoundedOutputReader {
    static func read(from handle: FileHandle, limit: Int = TranscriptStore.maximumStoredBytes, onOutput: (@Sendable (String) -> Void)? = nil) -> Data {
        defer { try? handle.close() }
        var output = Data()
        // availableData returns as soon as rclone writes anything, so callers see output live.
        while case let chunk = handle.availableData, !chunk.isEmpty {
            onOutput?(String(decoding: chunk, as: UTF8.self))
            output.append(chunk)
            if output.count > limit { output.removeFirst(output.count - limit) }
        }
        return TranscriptStore.recentData(from: output, limit: limit)
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var timedOut = false
    private var timeoutTask: Task<Void, Never>?

    func claimCompletion() -> Bool {
        let result = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            guard !completed else { return (false, nil) }
            completed = true
            let task = timeoutTask
            timeoutTask = nil
            return (true, task)
        }
        result.1?.cancel()
        return result.0
    }

    func markTimedOutIfNeeded() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            timedOut = true
            return true
        }
    }

    func didTimeOut() -> Bool {
        lock.withLock { timedOut }
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard !completed else { return true }
            timeoutTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }
}
