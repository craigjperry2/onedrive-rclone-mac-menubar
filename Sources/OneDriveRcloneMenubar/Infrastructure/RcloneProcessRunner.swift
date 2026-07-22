import Darwin
import Foundation

actor RcloneProcessRunner {
    enum RunKind { case sync, resync }
    struct Result: Sendable {
        let exitCode: Int32
        let lines: [String]
        let failureReason: String?
    }

    private let timeout: TimeInterval = 30 * 60

    func validate(_ settings: SyncSettings) async -> String? {
        if let error = settings.validationError() { return error }
        let result = await runProcess(executable: settings.rcloneExecutablePath, arguments: ["listremotes"], environment: ["RCLONE_CONFIG": settings.configPath], transcriptURL: nil)
        guard result.exitCode == 0 else { return "Unable to read the rclone configuration." }
        return result.lines.contains("\(settings.remoteName):") ? nil : "The configured OneDrive remote was not found."
    }

    func run(_ kind: RunKind, settings: SyncSettings, transcriptURL: URL) async -> Result {
        var arguments = [
            "bisync", "\(settings.remoteName):", settings.localPath,
            "--check-access", "--create-empty-src-dirs", "--exclude=/Personal Vault/**",
            "--modify-window", "2s", "--resilient", "--fast-list", "--onedrive-delta"
        ]
        if kind == .resync { arguments.append("--resync") }
        return await runProcess(executable: settings.rcloneExecutablePath, arguments: arguments, environment: ["RCLONE_CONFIG": settings.configPath], transcriptURL: transcriptURL)
    }

    private func runProcess(executable: String, arguments: [String], environment: [String: String], transcriptURL: URL?) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }

        if let transcriptURL {
            FileManager.default.createFile(atPath: transcriptURL.path(), contents: nil)
            guard let transcriptHandle = try? FileHandle(forWritingTo: transcriptURL) else {
                return Result(exitCode: -1, lines: [], failureReason: "Unable to create the rclone output log.")
            }
            try? transcriptHandle.close()
        }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputTask = Task.detached(priority: .utility) {
            BoundedOutputReader.read(from: outputPipe.fileHandleForReading)
        }

        let execution = await withCheckedContinuation { continuation in
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
        }

        let outputData = await outputTask.value
        let lines = TranscriptStore.displayLines(from: outputData)
        if let transcriptURL { TranscriptStore(fileURL: transcriptURL).replace(with: outputData) }
        let timeoutReason = execution.timedOut ? "rclone timed out after 30 minutes." : nil
        return Result(
            exitCode: execution.exitCode,
            lines: lines,
            failureReason: execution.launchError ?? lines.last ?? timeoutReason
        )
    }
}

private struct ProcessExecution: Sendable {
    let exitCode: Int32
    let timedOut: Bool
    let launchError: String?
}

private enum BoundedOutputReader {
    static func read(from handle: FileHandle, limit: Int = TranscriptStore.maximumStoredBytes) -> Data {
        defer { try? handle.close() }
        var output = Data()
        while let chunk = try? handle.read(upToCount: 8 * 1024), !chunk.isEmpty {
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
