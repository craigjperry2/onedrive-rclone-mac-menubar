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

    // Menu rows are single lines, so long explanations break into short lines.
    static let rcloneRequired = "rclone is required before OneDrive sync can be configured.\nInstall it with Homebrew (brew install rclone) or Nix."

    /// Where Homebrew (Apple silicon and Intel) and Nix install rclone, followed by
    /// the app's PATH, which for a login item is usually only the system directories.
    static func rcloneCandidates(
        home: String = NSHomeDirectory(),
        user: String = NSUserName(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.nix-profile/bin",
            "/etc/profiles/per-user/\(user)/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
        ] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { "\($0)/rclone" }
    }

    /// Uses `rcloneExecutablePath` when it names an executable, and otherwise the
    /// first executable candidate, so settings.json needs no rclone path.
    func resolvingRclone(candidates: [String], fileManager: FileManager = .default) -> SyncSettings {
        guard !fileManager.isExecutableFile(atPath: rcloneExecutablePath),
              let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else { return self }
        var resolved = self
        resolved.rcloneExecutablePath = found
        return resolved
    }

    func configurationError(fileManager: FileManager = .default) -> String? {
        guard fileManager.isExecutableFile(atPath: rcloneExecutablePath) else { return Self.rcloneRequired }
        guard fileManager.fileExists(atPath: configPath) else {
            return "This Mac is ready to configure OneDrive sync.\nrclone is installed but has no configuration yet."
        }
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
}
