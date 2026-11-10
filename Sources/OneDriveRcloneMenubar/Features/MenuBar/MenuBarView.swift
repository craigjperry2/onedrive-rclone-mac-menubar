import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            lines(Self.statusTitle(coordinator.status, runStartedAt: coordinator.runStartedAt, now: Date()))
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
            if let syncTimes = Self.syncTimes(
                status: coordinator.status,
                latestRun: coordinator.latestRun,
                nextScheduledSync: coordinator.nextScheduledSync,
                onLowDataNetwork: coordinator.isOnLowDataNetworkNow,
                now: Date()
            ) { lines(syncTimes) }
            if case .disabled(let reason) = coordinator.status { lines(reason) }
            if let skip = coordinator.activity.entries.last, skip.outcome == .skipped(.lowDataNetwork) {
                Text("Skipped \(skip.count == 1 ? "1 sync" : "\(skip.count) syncs") since \(skip.startedAt.formatted(date: .omitted, time: .shortened))")
            }

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
            Menu("Run Output") {
                let output = RunOutput(lines: coordinator.transcriptLines)
                if let headline = Self.latestRunHeadline(coordinator.latestRun, output: output) {
                    Text(headline)
                    if !output.otherRows.isEmpty { Divider() }
                }
                outputRows(output.errorRows)
                if !output.errorRows.isEmpty, !output.otherRows.isEmpty { Divider() }
                outputRows(output.otherRows)
                if let latestRun = coordinator.latestRun {
                    Divider()
                    Button("Open Full Log", action: coordinator.openFullLog)
                    if latestRun.outcome == .failure {
                        Button("Copy Error Details") { Task { await coordinator.copyErrorDetails() } }
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
            if coordinator.isRunning {
                Button(coordinator.isStopping ? "Stopping…" : "Stop Sync", action: coordinator.stopSync)
                    .disabled(coordinator.isStopping)
            }
            Button("Sync Now", action: coordinator.syncNow).disabled(!coordinator.canStartSync)
            Button("Resync…", action: confirmResync).disabled(!coordinator.canStartSync)
            Divider()
            Text(Self.versionTitle(info: Bundle.main.infoDictionary))
            Button("Quit OneDrive Sync") { NSApplication.shared.terminate(nil) }
                .disabled(coordinator.isRunning)
            if coordinator.isRunning { Text("Quit is unavailable until the sync stops.") }
        }
    }

    /// The first row. A run in progress also says how long it has been going.
    static func statusTitle(_ status: SyncStatus, runStartedAt: Date?, now: Date) -> String {
        guard status == .running, let runStartedAt else { return status.headline }
        let minutes = Int(now.timeIntervalSince(runStartedAt) / 60)
        return minutes < 1 ? "Syncing for less than a minute" : "Syncing for \(minutes) min"
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
        /// bisync's --max-delete check stopped a sync that would delete the files
        /// deleted on this side from the other side too. Every sync stops the same
        /// way until the user allows the deletions, or a resync copies the files back.
        case allowDeletes(SyncProblem.Side)
        /// Nothing known; the next attempt may pass.
        case tryAgain

        var advice: String {
            switch self {
            case .resync: "Ordinary syncs fail until a resync rebuilds it."
            case .recreateCheckFile: "Every sync fails until it is back."
            case .reconnectDrive: "Syncing resumes when the drive is connected again."
            case .signInAgain: "Every sync fails until rclone signs in again."
            case let .allowDeletes(side): """
                Syncing stopped rather than delete them from \(side.otherSide) too.
                If you meant to delete them, choose Allow Deletes and Sync…
                If not, choose Resync… to copy them back from \(side.otherSide).
                """
            case .tryAgain: "Choose Sync Now to try again.\nRun Output shows what rclone reported."
            }
        }

        var actionTitle: String? {
            switch self {
            case .resync: "Resync…"
            case .recreateCheckFile(.oneDrive): "Recreate Check File on OneDrive…"
            case .recreateCheckFile(.localFolder): "Recreate Check File in Your Folder…"
            case .recreateCheckFile(.both): "Recreate Check Files…"
            case .allowDeletes: "Allow Deletes and Sync…"
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
        case .tooManyDeletes(let side): .allowDeletes(side)
        case .oneDriveUnreachable, .unrecognized, nil: .tryAgain
        }
    }

    /// The Resync confirmation: why it is suggested, if it is, and what it does here.
    static func resyncConfirmation(for fix: Fix?, settings: SyncSettings) -> String {
        let why = switch fix {
        case .resync:
            "rclone lost its record of the last sync, so ordinary syncs fail until a resync rebuilds it."
        case let .allowDeletes(side):
            "\(SyncProblem.tooManyDeletes(side).name). If you did not mean to delete them, a resync copies them back from \(side.otherSide)."
        default:
            "The latest sync does not need a resync. Use it only when rclone asks for one; Sync Now handles ordinary changes."
        }
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

    /// The Allow Deletes confirmation. Cancel is the safe choice, so it says how to
    /// get the files back instead.
    static func deletesConfirmation(deletedFrom side: SyncProblem.Side, settings: SyncSettings) -> (title: String, message: String) {
        let oneDrive = "OneDrive (\(settings.remoteName):)"
        let (title, place, otherSide) = switch side {
        case .oneDrive: ("Delete these files from your folder too?", oneDrive, settings.localPath)
        case .localFolder: ("Delete these files from OneDrive too?", settings.localPath, oneDrive)
        case .both: ("Delete these files from the other side too?", "\(oneDrive) or \(settings.localPath)", "the other side")
        }
        let message = """
        Over half the files in \(place) were deleted since the last sync, so syncing stopped rather than delete them from \(otherSide) too. That can mean:

        • you deleted or moved them on purpose
        • they were deleted by mistake, or by another app or device

        Look in \(place) first. If you did not mean to delete them, cancel and choose Resync…, which copies them back from \(otherSide).

        Allow Deletes and Sync runs one sync without this safety check, so the files are deleted from \(otherSide) as well. This app cannot undo that.
        """
        return (title, message)
    }

    /// The first row of Run Output. rclone logs nothing about a successful run except
    /// its stats, so success gets a summary rather than looking like no run happened.
    static func latestRunHeadline(_ latestRun: SyncRunRecord?, output: RunOutput) -> String? {
        if latestRun?.outcome == .success { return output.successSummary }
        return output.errorLines.isEmpty && output.otherLines.isEmpty ? "No run output yet" : nil
    }

    /// How long ago the folder last synced and when the schedule syncs next. The
    /// times are relative, worked out each time the menu opens; Recent Activity keeps
    /// the absolute times. After a failure, or when syncs have stopped working, the
    /// last success is the last good sync, which shows how urgent the problem is.
    /// The next sync is shown only while scheduled syncs can run: Syncing, Disabled,
    /// and Paused until the drive is reconnected already say why they cannot.
    static func syncTimes(status: SyncStatus, latestRun: SyncRunRecord?, nextScheduledSync: Date?, onLowDataNetwork: Bool, now: Date) -> String? {
        var rows: [String] = []
        if let lastSuccess = latestRun?.lastSuccessAt {
            let upToDate = switch status {
            case .healthy, .running, .paused(.lowDataNetwork): latestRun?.outcome == .success
            case .waitingForFirstSync, .paused(.retrying), .paused(.volumeUnavailable), .unhealthy, .disabled: false
            }
            let ago = relative(now.timeIntervalSince(lastSuccess)).map { "\($0) ago" } ?? "just now"
            rows.append("\(upToDate ? "Synced" : "Last good sync") \(ago)")
        }
        switch status {
        case .healthy, .unhealthy, .waitingForFirstSync, .paused(.retrying), .paused(.lowDataNetwork):
            guard let nextScheduledSync else { break }
            if onLowDataNetwork {
                // Paused on a low-data network already says so in its headline.
                if status != .paused(.lowDataNetwork) { rows.append("Next scheduled sync will be skipped: low-data network") }
            } else {
                let next = relative(nextScheduledSync.timeIntervalSince(now)) ?? "under a minute"
                if rows.isEmpty { rows.append("Next sync in \(next)") } else { rows[0] += " · next sync in \(next)" }
            }
        case .running, .disabled, .paused(.volumeUnavailable):
            break
        }
        return rows.isEmpty ? nil : rows.joined(separator: "\n")
    }

    /// A rough duration, rounded down, or nil for under a minute.
    private static func relative(_ interval: TimeInterval) -> String? {
        let minutes = Int(max(0, interval) / 60)
        if minutes == 0 { return nil }
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return "\(minutes / 60) h" }
        let days = minutes / (24 * 60)
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// Menu rows are single lines, so messages put each short line in its own row.
    private func lines(_ text: String) -> some View {
        ForEach(text.split(separator: "\n").map(String.init), id: \.self) { Text($0) }
    }

    private func outputRows(_ rows: [String]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            Text(row).font(.caption.monospaced())
        }
    }

    // An NSAlert rather than .confirmationDialog: the menu closes before the
    // action runs, so a dialog attached to the menu content is never presented.
    private func confirmResync() {
        guard let settings = coordinator.settings else { return }
        let fix = Self.fix(for: coordinator.status, transcriptLines: coordinator.transcriptLines)
        guard confirm("Run recovery resync?", Self.resyncConfirmation(for: fix, settings: settings), action: "Resync") else { return }
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
        case let .allowDeletes(side):
            guard let settings = coordinator.settings else { return }
            let confirmation = Self.deletesConfirmation(deletedFrom: side, settings: settings)
            guard confirm(confirmation.title, confirmation.message, action: "Allow Deletes and Sync") else { return }
            coordinator.syncAllowingDeletes()
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
}
