import Foundation

/// Guided setup: check rclone, connect OneDrive through rclone's browser sign-in,
/// choose the local folder, then initialise bisync with a first resync. Nothing
/// changes on disk or in OneDrive until the user confirms the first sync, apart
/// from the remote that a completed sign-in adds to rclone.conf.
@MainActor
final class SetupModel: ObservableObject {
    enum Step: Equatable {
        case checking
        case rcloneMissing
        case connect
        case signingIn
        case chooseFolder
        case confirmFirstSync
        case firstSyncRunning
        case finished
        case firstSyncFailed(reason: String)
    }

    @Published private(set) var step: Step = .checking
    @Published private(set) var isConnected = false
    @Published private(set) var signInURL: URL?
    @Published private(set) var localFolder: URL?
    /// Explains why setup cannot continue, such as a cancelled sign-in.
    @Published private(set) var message: String?

    private let coordinator: SyncCoordinator
    private let home: URL
    private let fileManager = FileManager.default
    private var settings: SyncSettings
    private var signInTask: Task<Void, Never>?

    init(coordinator: SyncCoordinator, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.coordinator = coordinator
        self.home = home
        settings = coordinator.setupSettings()
    }

    private var runner: any RcloneRunning { coordinator.runner }

    /// The chosen folder as settings.json stores it, without the trailing slash of a directory URL.
    var localPath: String? { localFolder.map { $0.path(percentEncoded: false).trimmingSuffix("/") } }

    /// Checks rclone and whether OneDrive is already connected. Also used by Check Again.
    func start() async {
        settings = coordinator.setupSettings()
        message = nil
        guard fileManager.isExecutableFile(atPath: settings.rcloneExecutablePath) else {
            step = .rcloneMissing
            return
        }
        step = .checking
        isConnected = await runner.hasRemote(settings)
        step = .connect
    }

    func signIn() {
        guard step == .connect else { return }
        message = nil
        signInURL = nil
        step = .signingIn
        let settings = settings
        signInTask = Task {
            let failure = await runner.authorize(settings) { url in
                Task { @MainActor [weak self] in self?.signInURL = url }
            }
            guard step == .signingIn else { return }
            if Task.isCancelled {
                message = "Sign-in was cancelled, so OneDrive is not configured yet. Sign in to continue."
                step = .connect
            } else if let failure {
                message = "OneDrive is not configured yet: \(failure)"
                step = .connect
            } else {
                isConnected = true
                step = .chooseFolder
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    /// Stops a sign-in in progress when the window closes, leaving setup incomplete.
    func close() {
        signInTask?.cancel()
    }

    func continueToFolder() {
        guard isConnected else { return }
        message = nil
        step = .chooseFolder
    }

    func chooseFolder(_ url: URL) {
        if let problem = Self.folderProblem(url, home: home) {
            message = problem
            return
        }
        message = nil
        localFolder = url
    }

    func continueToFirstSync() {
        guard localFolder != nil else {
            message = "Choose a local folder to finish setup."
            return
        }
        message = nil
        step = .confirmFirstSync
    }

    func back() {
        message = nil
        switch step {
        case .chooseFolder: step = .connect
        case .confirmFirstSync: step = .chooseFolder
        default: break
        }
    }

    /// Creates RCLONE_TEST on both sides, saves the folder, and runs the first resync.
    func startFirstSync() async {
        guard step == .confirmFirstSync, let localFolder, let localPath else { return }
        step = .firstSyncRunning
        do {
            try fileManager.createDirectory(at: localFolder, withIntermediateDirectories: true)
            let checkFile = localFolder.appending(path: "RCLONE_TEST")
            if !fileManager.fileExists(atPath: checkFile.path(percentEncoded: false)) {
                try Data().write(to: checkFile)
            }
        } catch {
            step = .firstSyncFailed(reason: "The folder could not be prepared: \(error.localizedDescription)")
            return
        }
        if let failure = await runner.createRemoteCheckFile(settings) {
            step = .firstSyncFailed(reason: failure)
            return
        }
        do {
            try await coordinator.completeSetup(localPath: localPath)
        } catch {
            step = .firstSyncFailed(reason: "The settings could not be saved: \(error.localizedDescription)")
            return
        }
        await coordinator.run(.resync)
        if let run = coordinator.latestRun, run.outcome == .success {
            step = .finished
        } else {
            step = .firstSyncFailed(reason: coordinator.latestRun?.failureReason ?? coordinator.status.reason ?? "The first sync did not finish.")
        }
    }

    /// Syncing the whole home folder, or a system folder, would upload far more
    /// than the user means to.
    static func folderProblem(_ url: URL, home: URL) -> String? {
        let path = url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        let homePath = home.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        let insideHome = path.hasPrefix(homePath + "/")
        let onVolume = path.hasPrefix("/Volumes/") && path.split(separator: "/").count > 2
        guard insideHome || onVolume else {
            return "Choose a folder inside your home folder or on an external drive, not \(path)."
        }
        if insideHome, ["Library", ".Trash"].contains(path.dropFirst(homePath.count + 1).split(separator: "/").first.map(String.init)) {
            return "Choose a folder outside your Library folder."
        }
        return nil
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        count > suffix.count && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
