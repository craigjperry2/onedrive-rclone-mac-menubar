import Foundation

struct SyncSettings: Codable, Equatable, Sendable {
    var rcloneExecutablePath: String
    var configPath: String
    var remoteName: String
    var localPath: String
    var intervalSeconds: TimeInterval

    static let initialTemplate = SyncSettings(
        rcloneExecutablePath: "",
        configPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/rclone/rclone.conf").path(),
        remoteName: "onedrive",
        localPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: "onedrive-rclone").path(),
        intervalSeconds: 600
    )

    func configurationError(fileManager: FileManager = .default) -> String? {
        guard !rcloneExecutablePath.isEmpty else { return "Set rcloneExecutablePath in settings.json." }
        guard fileManager.isExecutableFile(atPath: rcloneExecutablePath) else { return "The configured rclone executable is unavailable." }
        guard fileManager.fileExists(atPath: configPath) else { return "No valid rclone configuration was found." }
        guard !remoteName.isEmpty else { return "Set a OneDrive remote name in settings.json." }
        guard !localPath.isEmpty else { return "Set a local mirror path in settings.json." }
        guard intervalSeconds > 0 else { return "Set a positive sync interval in settings.json." }
        return nil
    }

    func availabilityError(fileManager: FileManager = .default) -> String? {
        if localPath.hasPrefix("/Volumes/") {
            let volumeName = localPath.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? ""
            guard fileManager.fileExists(atPath: "/Volumes/\(volumeName)") else { return "The configured external volume is unavailable." }
        }
        return nil
    }

    func validationError(fileManager: FileManager = .default) -> String? {
        configurationError(fileManager: fileManager) ?? availabilityError(fileManager: fileManager)
    }
}
