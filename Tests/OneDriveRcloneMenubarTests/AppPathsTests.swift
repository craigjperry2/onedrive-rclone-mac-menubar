import Foundation
import Testing
@testable import OneDriveRcloneMenubar

struct AppPathsTests {
    @Test func applicationSupportArtifactsStayWithinRoot() {
        let root = URL(filePath: "/tmp/onedrive-rclone-menubar-tests", directoryHint: .isDirectory)
        let paths = AppPaths(rootDirectory: root)

        #expect(paths.settingsFile.path().hasPrefix(root.path()))
        #expect(paths.runStateFile.path().hasPrefix(root.path()))
        #expect(paths.latestTranscriptFile.path().hasPrefix(root.path()))
    }
}
