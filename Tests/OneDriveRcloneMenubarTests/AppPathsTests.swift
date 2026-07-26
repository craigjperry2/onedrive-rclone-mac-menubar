import Foundation
import Testing
@testable import OneDriveRcloneMenubar

struct AppPathsTests {
    @Test func applicationSupportArtifactsStayWithinRoot() {
        let root = FileManager.default.temporaryDirectory.appending(path: "onedrive-rclone-menubar-tests", directoryHint: .isDirectory)
        let paths = AppPaths(rootDirectory: root)

        #expect(paths.settingsFile.path().hasPrefix(root.path()))
        #expect(paths.runStateFile.path().hasPrefix(root.path()))
        #expect(paths.latestTranscriptFile.path().hasPrefix(root.path()))
    }

    @Test func missingJSONStoreReturnsNil() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "missing-settings-\(UUID().uuidString).json")
        let store = JSONFileStore<SyncSettings>(fileURL: file)

        #expect(try store.load() == nil)
    }
}
