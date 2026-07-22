import Foundation

struct AppPaths: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OneDriveRcloneMenubar", directoryHint: .isDirectory)
    }

    var settingsFile: URL { rootDirectory.appending(path: "settings.json") }
    var runStateFile: URL { rootDirectory.appending(path: "run-state.json") }
    var latestTranscriptFile: URL { rootDirectory.appending(path: "latest-run.log") }

    func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }
}
