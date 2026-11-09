import AppKit
import Testing
@testable import OneDriveRcloneMenubar

/// Text and icons the menu shows that come from logic rather than layout.
@MainActor
struct MenuTests {
    @Test(arguments: [
        RcloneOutput.needsResync,
        ["2026/11/09 10:00:00 ERROR : Bisync aborted. Must run --resync to recover.", "2026/11/09 10:00:01 NOTICE: Failed to bisync: bisync aborted"],
    ])
    func bisyncThatNeedsAResyncOffersResync(output: [String]) {
        let fix = MenuBarView.fix(for: .unhealthy(reason: "rclone lost track of the last sync"), transcriptLines: output)

        #expect(fix == .resync)
        #expect(fix?.actionTitle == "Resync…")
    }

    /// rclone calls these retryable, but every sync fails the same way until the
    /// file is back, so the menu offers to recreate it on the side that lost it.
    @Test(arguments: [
        (RcloneOutput.checkFileMissingOnOneDrive, MenuBarView.Fix.recreateCheckFile(.oneDrive), "Recreate Check File on OneDrive…"),
        (RcloneOutput.checkFileMissingLocally, .recreateCheckFile(.localFolder), "Recreate Check File in Your Folder…"),
        (RcloneOutput.checkFileMissingOnBothSides, .recreateCheckFile(.both), "Recreate Check Files…"),
        // rclone asks for a resync here, but it fails the same way until the file is back.
        (RcloneOutput.resyncWithCheckFileMissingOnOneDrive, .recreateCheckFile(.oneDrive), "Recreate Check File on OneDrive…"),
    ])
    func missingCheckFileOffersToRecreateItInsteadOfRetrying(output: [String], expected: MenuBarView.Fix, action: String) {
        let fix = MenuBarView.fix(for: .unhealthy(reason: "The RCLONE_TEST check file is missing"), transcriptLines: output)

        #expect(fix == expected)
        #expect(fix?.actionTitle == action)
        #expect(fix?.advice == "Every sync fails until it is back.")
    }

    @Test func expiredSignInDoesNotSuggestSyncNowOrResync() {
        let fix = MenuBarView.fix(for: .unhealthy(reason: "The OneDrive sign-in has expired"), transcriptLines: RcloneOutput.signInExpired)

        #expect(fix == .signInAgain)
        #expect(fix?.advice == "Every sync fails until rclone signs in again.")
        #expect(fix?.actionTitle == nil)
    }

    @Test(arguments: [
        RcloneOutput.unreachableDNS,
        RcloneOutput.tooManyDeletes,
        // rclone mentions --resync here only to say it is not needed.
        ["ERROR : Bisync aborted. Error is retryable without --resync due to --resilient mode."],
        [],
    ])
    func otherFailuresSuggestTryingAgainWithoutRecommendingResync(output: [String]) {
        let fix = MenuBarView.fix(for: .unhealthy(reason: "x"), transcriptLines: output)

        #expect(fix == .tryAgain)
        #expect(fix?.advice == "Choose Sync Now to try again.\nLatest run shows what rclone reported.")
        #expect(fix?.actionTitle == nil)
    }

    /// The output is from an earlier run, so it must not decide the fix while the
    /// drive is unplugged: no run can start until it is back.
    @Test func unpluggedDriveSaysSyncingResumesWithoutAnAction() {
        let fix = MenuBarView.fix(for: .unhealthy(reason: SyncSettings.volumeUnavailable), transcriptLines: RcloneOutput.needsResync)

        #expect(fix == .reconnectDrive)
        #expect(fix?.advice == "Syncing resumes when the drive is connected again.")
        #expect(fix?.actionTitle == nil)
    }

    @Test(arguments: [SyncStatus.healthy(lastSuccess: .now), .running, .waitingForFirstSync, .paused(.retrying(failure: "x")), .paused(.lowDataNetwork), .paused(.volumeUnavailable), .disabled(reason: "x")])
    func onlyNeedsAttentionOffersAFix(status: SyncStatus) {
        #expect(MenuBarView.fix(for: status, transcriptLines: RcloneOutput.needsResync) == nil)
    }

    static let settings = SyncSettings(rcloneExecutablePath: "/opt/homebrew/bin/rclone", configPath: "/Users/craig/.config/rclone/rclone.conf", remoteName: "onedrive-work", localPath: "/Users/craig/OneDrive", intervalSeconds: 600)

    /// The confirmation names the side that lost the file and warns that its
    /// deletions spread to the other side once the check passes again.
    @Test func checkFileConfirmationExplainsTheRiskForTheSideThatLostIt() {
        let oneDrive = MenuBarView.checkFileConfirmation(missingFrom: .oneDrive, settings: Self.settings)
        #expect(oneDrive.title == "Recreate the check file on OneDrive?")
        #expect(oneDrive.message.contains("It is missing in OneDrive (onedrive-work:)."))
        #expect(oneDrive.message.contains("rclone is connected to a different account or folder"))
        #expect(oneDrive.message.contains("deletes them from /Users/craig/OneDrive too"))

        let folder = MenuBarView.checkFileConfirmation(missingFrom: .localFolder, settings: Self.settings)
        #expect(folder.title == "Recreate the check file in your folder?")
        #expect(folder.message.contains("It is missing in /Users/craig/OneDrive."))
        #expect(folder.message.contains("deletes them from OneDrive too"))
    }

    @Test func resyncConfirmationSaysWhyAndWhatItDoesHere() {
        let suggested = MenuBarView.resyncConfirmation(suggested: true, settings: Self.settings)
        #expect(suggested.hasPrefix("rclone lost its record of the last sync"))
        #expect(suggested.contains("Resync makes OneDrive (onedrive-work:) and /Users/craig/OneDrive match."))

        let unprompted = MenuBarView.resyncConfirmation(suggested: false, settings: Self.settings)
        #expect(unprompted.hasPrefix("The latest sync does not need a resync."))
    }

    @Test(arguments: [
        (RcloneOutput.checkFileMissingOnOneDrive, "Needs attention: The RCLONE_TEST check file is missing from OneDrive"),
        (RcloneOutput.needsResync, "Needs attention: rclone lost track of the last sync"),
        (RcloneOutput.signInExpired, "Needs attention: The OneDrive sign-in has expired"),
    ] as [([String], String)])
    func firstRowNamesTheProblem(output: [String], headline: String) throws {
        let reason = try #require(SyncProblem(rcloneOutput: output)).name

        #expect(SyncStatus.unhealthy(reason: reason).headline == headline)
    }

    @Test func willTryAgainNamesTheFailureInTheFirstRow() {
        #expect(SyncStatus.paused(.retrying(failure: "OneDrive cannot be reached")).headline == "Will try again: OneDrive cannot be reached")
    }

    @Test(arguments: [SyncStatus.healthy(lastSuccess: .now), .running, .waitingForFirstSync, .paused(.lowDataNetwork), .paused(.volumeUnavailable), .disabled(reason: "x")])
    func otherStatesKeepTheirTitleAsTheFirstRow(status: SyncStatus) {
        #expect(status.headline == status.title)
    }

    @Test(arguments: [
        (nil, "Development build"),
        (["CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "0"], "Development build"),
        (["CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "57"], "Version 1.4.2 (57)"),
        (["CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "1.4.2"], "Version 1.4.2"),
        (["CFBundleShortVersionString": "1.4.2"], "Version 1.4.2"),
    ] as [([String: String]?, String)])
    func versionRowIdentifiesTheRelease(info: [String: String]?, expected: String) {
        #expect(MenuBarView.versionTitle(info: info) == expected)
    }

    /// A misspelt SF Symbol name leaves the menu-bar item blank.
    @Test func everyStatusHasItsOwnMenuBarIcon() {
        let symbols = SyncStatus.legend.map(\.symbolName)

        #expect(Set(symbols).count == 8)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol) is not an SF Symbol")
        }
    }
}
