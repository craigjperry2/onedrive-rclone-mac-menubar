import Darwin
import Foundation

actor RcloneProcessRunner {
    enum RunKind { case sync, resync }
    private let timeout: TimeInterval = 30 * 60

    func validate(_ settings: SyncSettings) async -> String? {
        if let error = settings.validationError() { return error }
        let result = await runProcess(executable: settings.rcloneExecutablePath, arguments: ["listremotes"], environment: ["RCLONE_CONFIG": settings.configPath], transcriptURL: nil)
        guard result.exitCode == 0 else { return "Unable to read the rclone configuration." }
        let remotes = result.output.split(whereSeparator: \.isNewline).map(String.init)
        return remotes.contains("\(settings.remoteName):") ? nil : "The configured OneDrive remote was not found."
    }

    func run(_ kind: RunKind, settings: SyncSettings, transcriptURL: URL) async -> (exitCode: Int32, output: String) {
        var arguments = [
            "bisync", "\(settings.remoteName):", settings.localPath,
            "--check-access", "--create-empty-src-dirs", "--exclude=/Personal Vault/**",
            "--modify-window", "2s", "--resilient", "--fast-list", "--onedrive-delta"
        ]
        if kind == .resync { arguments.append("--resync") }
        return await runProcess(executable: settings.rcloneExecutablePath, arguments: arguments, environment: ["RCLONE_CONFIG": settings.configPath], transcriptURL: transcriptURL)
    }

    private func runProcess(executable: String, arguments: [String], environment: [String: String], transcriptURL: URL?) async -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
        let temporaryCapture = transcriptURL == nil
        let captureURL = transcriptURL ?? FileManager.default.temporaryDirectory.appending(path: "rclone-validation-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: captureURL.path(), contents: nil)
        guard let captureHandle = try? FileHandle(forWritingTo: captureURL) else {
            return (-1, "Unable to create the rclone output log.")
        }
        process.standardOutput = captureHandle
        process.standardError = captureHandle

        return await withCheckedContinuation { continuation in
            let completion = ProcessCompletion()
            let finish: @Sendable () -> Void = {
                guard completion.claimCompletion() else { return }
                try? captureHandle.close()
                let store = TranscriptStore(fileURL: captureURL)
                store.trimToRecentBytes()
                let output = store.displayLines().joined(separator: "\n")
                if temporaryCapture { try? FileManager.default.removeItem(at: captureURL) }
                let timedOut = completion.didTimeOut()
                let exitCode: Int32 = timedOut ? -1 : process.terminationStatus
                let finalOutput = timedOut ? "rclone timed out after 30 minutes.\n\(output)" : output
                continuation.resume(returning: (exitCode, finalOutput))
            }
            process.terminationHandler = { _ in finish() }
            do {
                try process.run()
            } catch {
                try? captureHandle.close()
                if temporaryCapture { try? FileManager.default.removeItem(at: captureURL) }
                continuation.resume(returning: (-1, error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning, completion.markTimedOutIfNeeded() else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private(set) var timedOut = false

    func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }

    func markTimedOutIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return false }
        timedOut = true
        return true
    }

    func didTimeOut() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}
