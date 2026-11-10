import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            lines(coordinator.status.headline)
            if let explanation = coordinator.status.explanation { lines(explanation) }
            // The fix for a problem sits directly under the headline that names it.
            if let fix = Self.fix(for: coordinator.status, transcriptLines: coordinator.transcriptLines) {
                lines(fix.advice)
                if let actionTitle = fix.actionTitle {
                    Button(actionTitle) { perform(fix) }.disabled(!coordinator.canStartSync)
                }
            }
            if let loginWarning = coordinator.loginWarning {
                lines(loginWarning)
                Button("Open Login Items Settings…", action: LoginItemManager.openSystemSettings)
            }
            if let persistenceWarning = coordinator.persistenceWarning { Text(persistenceWarning) }
            if let lastSuccess = coordinator.latestRun?.lastSuccessAt {
                Text("Last successful sync: \(lastSuccess.formatted(date: .abbreviated, time: .shortened))")
            }
            if case .disabled(let reason) = coordinator.status { lines(reason) }
            if let skip = coordinator.activity.entries.last, skip.outcome == .skipped(.lowDataNetwork) {
                Text("Skipped \(skip.count == 1 ? "1 sync" : "\(skip.count) syncs") since \(skip.startedAt.formatted(date: .omitted, time: .shortened))")
            }
            if coordinator.isRunning { Text("rclone is running…") }

            Menu("Recent Activity") {
                let now = Date()
                if coordinator.activity.recent.isEmpty { Text("No sync activity yet") }
                ForEach(Array(coordinator.activity.recent.enumerated()), id: \.offset) { _, entry in
                    if case .failed(let reason) = entry.outcome {
                        Menu(entry.summary(now: now)) { lines(reason) }
                    } else {
                        Text(entry.summary(now: now))
                    }
                }
            }
            Menu(latestRunTitle) {
                if coordinator.transcriptLines.isEmpty {
                    Text("No run output yet")
                } else {
                    ForEach(Array(coordinator.transcriptLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }

            Divider()
            if case .disabled = coordinator.status {
                Button("Set Up OneDrive…") {
                    NSApp.activate()
                    openWindow(id: "setup")
                }
            }
            Button("Sync Now", action: coordinator.syncNow).disabled(!coordinator.canStartSync)
            Button("Resync…", action: confirmResync).disabled(!coordinator.canStartSync)
            Divider()
            Text(Self.versionTitle(info: Bundle.main.infoDictionary))
            Button("Quit OneDrive Sync") { NSApplication.shared.terminate(nil) }
                .disabled(coordinator.isRunning)
        }
    }

    /// What fixes a Needs attention problem, shown under the headline that names it.
    enum Fix: Equatable {
        /// bisync lost its listings from the last run, and only a resync rebuilds them.
        case resync
        /// --check-access found RCLONE_TEST missing; every sync fails the same way
        /// until it is back.
        case recreateCheckFile(SyncProblem.Side)
        /// The external drive holding the folder is not mounted.
        case reconnectDrive
        /// rclone's OneDrive sign-in expired, which no sync can fix.
        case signInAgain
        /// Nothing known; the next attempt may pass.
        case tryAgain

        var advice: String {
            switch self {
            case .resync: "Ordinary syncs fail until a resync rebuilds it."
            case .recreateCheckFile: "Every sync fails until it is back."
            case .reconnectDrive: "Syncing resumes when the drive is connected again."
            case .signInAgain: "Every sync fails until rclone signs in again."
            case .tryAgain: "Choose Sync Now to try again.\nLatest run shows what rclone reported."
            }
        }

        var actionTitle: String? {
            switch self {
            case .resync: "Resync…"
            case .recreateCheckFile(.oneDrive): "Recreate Check File on OneDrive…"
            case .recreateCheckFile(.localFolder): "Recreate Check File in Your Folder…"
            case .recreateCheckFile(.both): "Recreate Check Files…"
            case .reconnectDrive, .signInAgain, .tryAgain: nil
            }
        }
    }

    /// The fix for the problem in the latest run's output. Under --resilient rclone
    /// calls a missing check file or missing listings retryable, but neither passes
    /// on a retry: one needs the file back, the other a resync. While the drive is
    /// unplugged the output is from an earlier run, so it does not decide the fix.
    static func fix(for status: SyncStatus, transcriptLines: [String]) -> Fix? {
        guard case let .unhealthy(reason) = status else { return nil }
        if reason == SyncSettings.volumeUnavailable { return .reconnectDrive }
        return switch SyncProblem(rcloneOutput: transcriptLines) {
        case .needsResync: .resync
        case .checkFileMissing(let side): .recreateCheckFile(side)
        case .signInExpired: .signInAgain
        case .tooManyDeletes, .oneDriveUnreachable, .unrecognized, nil: .tryAgain
        }
    }

    /// The Resync confirmation: why it is suggested, if it is, and what it does here.
    static func resyncConfirmation(suggested: Bool, settings: SyncSettings) -> String {
        let why = suggested
            ? "rclone lost its record of the last sync, so ordinary syncs fail until a resync rebuilds it."
            : "The latest sync does not need a resync. Use it only when rclone asks for one; Sync Now handles ordinary changes."
        return """
        \(why)

        Resync makes OneDrive (\(settings.remoteName):) and \(settings.localPath) match. Files that are only on one side are copied to the other, and nothing is deleted. If a file is on both sides with different contents, the OneDrive version replaces the one in the folder.
        """
    }

    /// The check file confirmation, which explains why the file may be missing:
    /// exactly the cases --check-access exists to catch.
    static func checkFileConfirmation(missingFrom side: SyncProblem.Side, settings: SyncSettings) -> (title: String, message: String) {
        let oneDrive = "OneDrive (\(settings.remoteName):)"
        let (title, place, otherSide) = switch side {
        case .oneDrive: ("Recreate the check file on OneDrive?", oneDrive, "from \(settings.localPath)")
        case .localFolder: ("Recreate the check file in your folder?", settings.localPath, "from OneDrive")
        case .both: ("Recreate both check files?", "both \(oneDrive) and \(settings.localPath)", "from the other side")
        }
        let message = """
        Every sync first checks that RCLONE_TEST is in \(oneDrive) and in \(settings.localPath), to make sure it syncs the right account with the right folder. It is missing in \(place). That can mean:

        • rclone is connected to a different account or folder
        • files were deleted there

        Look in \(place) first. If your files are missing, cancel: once the check file is back, the next sync treats them as deleted and deletes them \(otherSide) too.

        Recreate adds an empty RCLONE_TEST, then syncs.
        """
        return (title, message)
    }

    /// Menu rows are single lines, so messages put each short line in its own row.
    private func lines(_ text: String) -> some View {
        ForEach(text.split(separator: "\n").map(String.init), id: \.self) { Text($0) }
    }

    // An NSAlert rather than .confirmationDialog: the menu closes before the
    // action runs, so a dialog attached to the menu content is never presented.
    private func confirmResync() {
        guard let settings = coordinator.settings else { return }
        let suggested = Self.fix(for: coordinator.status, transcriptLines: coordinator.transcriptLines) == .resync
        guard confirm("Run recovery resync?", Self.resyncConfirmation(suggested: suggested, settings: settings), action: "Resync") else { return }
        coordinator.resync()
    }

    private func perform(_ fix: Fix) {
        switch fix {
        case .resync:
            confirmResync()
        case let .recreateCheckFile(side):
            guard let settings = coordinator.settings else { return }
            let confirmation = Self.checkFileConfirmation(missingFrom: side, settings: settings)
            guard confirm(confirmation.title, confirmation.message, action: "Recreate and Sync") else { return }
            Task {
                guard let failure = await coordinator.recreateCheckFile(missingFrom: side) else { return }
                let alert = NSAlert()
                alert.messageText = "The check file could not be recreated."
                alert.informativeText = failure
                NSApp.activate()
                alert.runModal()
            }
        case .reconnectDrive, .signInAgain, .tryAgain:
            break
        }
    }

    /// Asks before a fix that changes files. Cancel stays the default button.
    private func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Release builds get MARKETING_VERSION and CURRENT_PROJECT_VERSION from CI;
    // the project's 0.0.0 default and `swift run` (no bundle) mark local builds.
    static func versionTitle(info: [String: Any]?) -> String {
        guard let version = info?["CFBundleShortVersionString"] as? String, version != "0.0.0" else {
            return "Development build"
        }
        guard let build = info?["CFBundleVersion"] as? String, build != version else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }

    private var latestRunTitle: String {
        guard let latestRun = coordinator.latestRun else { return "Latest run: none" }
        return "Latest run: \(latestRun.finishedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
