import AppKit
import Testing
@testable import OneDriveRcloneMenubar

/// Text and icons the menu shows that come from logic rather than layout.
@MainActor
struct MenuTests {
    static let resyncAdvice = "rclone needs a resync to recover.\nChoose Resync… to run one."
    static let retryAdvice = "Choose Sync Now to try again.\nLatest run shows what rclone reported."

    @Test(arguments: [
        "2026/11/09 10:00:00 ERROR : Bisync aborted. Must run --resync to recover.",
        "2026/11/09 10:00:00 ERROR : Bisync critical error: cannot find prior Path1 or Path2 listings, likely due to critical error on prior run",
        "ERROR : MUST RUN --RESYNC TO RECOVER.",
    ])
    func bisyncThatNeedsAResyncSaysSo(line: String) {
        let transcript = ["2026/11/09 10:00:00 NOTICE: bisync is IN BETA.", line, "2026/11/09 10:00:01 Failed to bisync: bisync aborted"]

        #expect(MenuBarView.advice(for: .unhealthy(reason: "Failed to bisync"), transcriptLines: transcript) == Self.resyncAdvice)
    }

    @Test(arguments: [
        // rclone mentions --resync here only to say it is not needed.
        ["ERROR : Bisync aborted. Error is retryable without --resync due to --resilient mode."],
        ["ERROR : Failed to bisync: connection reset by peer"],
        [],
    ])
    func otherFailuresSuggestTryingAgain(transcript: [String]) {
        #expect(MenuBarView.advice(for: .unhealthy(reason: "x"), transcriptLines: transcript) == Self.retryAdvice)
    }

    @Test(arguments: [SyncStatus.healthy(lastSuccess: .now), .running, .waitingForFirstSync, .disabled(reason: "x")])
    func onlyNeedsAttentionGivesAdvice(status: SyncStatus) {
        #expect(MenuBarView.advice(for: status, transcriptLines: ["Must run --resync to recover."]) == nil)
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

        #expect(Set(symbols).count == 5)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol) is not an SF Symbol")
        }
    }
}
