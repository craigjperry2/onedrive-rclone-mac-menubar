import Foundation
import Testing
@testable import OneDriveRcloneMenubar

/// Paths reach the app from the folder picker (directory URLs with trailing
/// slashes, `..`, spaces), from hand-edited settings.json, and from the places
/// Homebrew and Nix install rclone, where Nix profiles are chains of symlinks.
@MainActor
struct PathHandlingTests {
    static let home = URL(filePath: "/Users/alex", directoryHint: .isDirectory)

    @Test(arguments: [
        "/Users/alex/OneDrive",
        "/Users/alex/OneDrive/",
        "/Users/alex/Documents/OneDrive",
        "/Users/alex/My OneDrive",
        "/Users/alex/Café ☁️",
        "/Users/alex/100% OneDrive",
        "/Users/alex/LibraryBackup",
        "/Users/alex/Documents/Library",
        "/Users/alex/.Trashed",
        "/Users/alex/Documents/../OneDrive",
        "/Volumes/Backup/OneDrive",
        "/Volumes/My Passport/OneDrive/",
    ])
    func folderPickerAccepts(_ path: String) {
        #expect(SetupModel.folderProblem(URL(filePath: path), home: Self.home) == nil)
    }

    @Test(arguments: [
        "/",
        "/Users",
        "/Users/alex",
        "/Users/alex/",
        "/Users/alex/.",
        "/Users/alex/OneDrive/..",
        "/Users/alexandra/OneDrive",
        "/Users/alex/../bob/OneDrive",
        "/Users/alex/Library",
        "/Users/alex/Library/Mobile Documents",
        "/Users/alex/.Trash",
        "/Users/alex/.Trash/OneDrive",
        "/Volumes",
        "/Volumes/Backup",
        "/Volumes/Backup/",
        "/Applications/OneDrive",
        "/private/tmp/OneDrive",
    ])
    func folderPickerRefuses(_ path: String) {
        #expect(SetupModel.folderProblem(URL(filePath: path), home: Self.home) != nil)
    }

    @Test func folderPickerTreatsAHomeWithATrailingSlashTheSame() {
        let home = URL(filePath: "/Users/alex/")
        #expect(SetupModel.folderProblem(URL(filePath: "/Users/alex/OneDrive"), home: home) == nil)
        #expect(SetupModel.folderProblem(URL(filePath: "/Users/alex"), home: home) != nil)
    }

    /// The default APFS volume is case-insensitive, so ~/library is ~/Library.
    @Test func folderPickerRefusesLibraryInAnyCase() {
        withKnownIssue("folderProblem compares the Library component case-sensitively") {
            #expect(SetupModel.folderProblem(URL(filePath: "/Users/alex/library/OneDrive"), home: Self.home) != nil)
        }
    }

    @Test func refusalNamesTheChosenFolderWithoutPercentEncoding() {
        let problem = SetupModel.folderProblem(URL(filePath: "/Applications/My Stuff"), home: Self.home)
        #expect(problem == "Choose a folder inside your home folder or on an external drive, not /Applications/My Stuff.")
    }

    // MARK: External volumes

    @Test(arguments: [
        ("/Volumes/Backup/OneDrive", ["/Volumes/Backup"], nil),
        ("/Volumes/Backup/OneDrive", [], "The configured external volume is unavailable."),
        ("/Volumes/My Passport/One Drive", ["/Volumes/My Passport"], nil),
        // Another volume being mounted does not count.
        ("/Volumes/Backup/OneDrive", ["/Volumes/Backup 1"], "The configured external volume is unavailable."),
        ("/Volumes/Backup", [], "The configured external volume is unavailable."),
        // Folders on the startup disk never depend on a mount.
        ("/Users/alex/OneDrive", [], nil),
    ] as [(String, [String], String?)])
    func externalVolumeAvailability(localPath: String, mounted: [String], expected: String?) {
        var settings = SyncSettings.initialTemplate
        settings.localPath = localPath
        #expect(settings.availabilityError(fileManager: MountedVolumes(mounted)) == expected)
    }

    // MARK: Finding rclone

    @Test func rcloneCandidatesIgnoreEmptyPathEntries() {
        let candidates = SyncSettings.rcloneCandidates(home: "/Users/alex", user: "alex", environment: ["PATH": ":/usr/bin::/custom/bin:"])

        #expect(!candidates.contains("/rclone"))
        #expect(Array(candidates.suffix(2)) == ["/usr/bin/rclone", "/custom/bin/rclone"])
    }

    @Test func rcloneCandidatesWorkWithoutAPath() {
        let candidates = SyncSettings.rcloneCandidates(home: "/Users/alex", user: "alex", environment: [:])

        #expect(candidates.last == "/nix/var/nix/profiles/default/bin/rclone")
    }

    @Test func rcloneDetectionSkipsFilesThatAreNotExecutable() throws {
        let directory = try TemporaryDirectory()
        let notExecutable = directory.url.appending(path: "homebrew/rclone")
        try FileManager.default.createDirectory(at: notExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: notExecutable)
        let executable = try makeExecutableScript("#!/bin/sh\n", at: directory.url.appending(path: "nix/rclone"))

        let resolved = SyncSettings.initialTemplate.resolvingRclone(candidates: [notExecutable.path(percentEncoded: false), executable.path(percentEncoded: false)])

        #expect(resolved.rcloneExecutablePath == executable.path(percentEncoded: false))
    }

    /// Nix profiles link bin/rclone to a store path. The app keeps the profile path,
    /// so an upgrade that repoints the profile is followed, and a garbage-collected
    /// store path (a dangling link) falls back to the next install.
    @Test func rcloneDetectionFollowsNixProfileLinksAndSkipsDanglingOnes() throws {
        let directory = try TemporaryDirectory()
        let storeRclone = try makeExecutableScript("#!/bin/sh\n", at: directory.url.appending(path: "nix/store/abc-rclone-1.71/bin/rclone"))
        let profileRclone = directory.url.appending(path: "nix-profile/bin/rclone")
        try FileManager.default.createDirectory(at: profileRclone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profileRclone, withDestinationURL: storeRclone)
        let homebrewRclone = try makeExecutableScript("#!/bin/sh\n", at: directory.url.appending(path: "homebrew/bin/rclone"))
        let candidates = [profileRclone, homebrewRclone].map { $0.path(percentEncoded: false) }

        #expect(SyncSettings.initialTemplate.resolvingRclone(candidates: candidates).rcloneExecutablePath == candidates[0])

        try FileManager.default.removeItem(at: storeRclone)
        #expect(SyncSettings.initialTemplate.resolvingRclone(candidates: candidates).rcloneExecutablePath == candidates[1])
    }

    // MARK: The chosen folder in settings.json

    @Test(arguments: ["OneDrive", "My OneDrive", "100% OneDrive", "Café ☁️", "a#b?c"])
    func chosenFolderIsSavedAsAPlainPath(_ name: String) async throws {
        let harness = try Harness(localPath: "")
        await harness.coordinator.load()
        let model = SetupModel(coordinator: harness.coordinator, home: harness.root)
        let folder = harness.root.appending(path: name, directoryHint: .isDirectory)
        let expected = harness.root.path(percentEncoded: false) + name

        model.chooseFolder(folder)
        #expect(model.localPath == expected)

        try await harness.coordinator.completeSetup(localPath: try #require(model.localPath))
        #expect(try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).load()?.localPath == expected)
    }
}

/// A file manager in which only the given volume roots exist.
private final class MountedVolumes: FileManager, @unchecked Sendable {
    private let mounted: Set<String>

    init(_ mounted: [String]) {
        self.mounted = Set(mounted)
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool { mounted.contains(path) }
}

/// A uniquely named directory that is deleted with the value.
final class TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}
