import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(coordinator.status.title)
            if let explanation = coordinator.status.explanation { lines(explanation) }
            if let loginWarning = coordinator.loginWarning {
                lines(loginWarning)
                Button("Open Login Items Settings…", action: LoginItemManager.openSystemSettings)
            }
            if let persistenceWarning = coordinator.persistenceWarning { Text(persistenceWarning) }
            if let lastSuccess = coordinator.latestRun?.lastSuccessAt {
                Text("Last successful sync: \(lastSuccess.formatted(date: .abbreviated, time: .shortened))")
            }
            if let reason = coordinator.status.reason { lines(reason) }
            if let advice = Self.advice(for: coordinator.status, transcriptLines: coordinator.transcriptLines) { lines(advice) }
            if let skip = coordinator.activity.entries.last, skip.outcome == .skipped(.lowDataNetwork) {
                Text("Scheduled syncs paused on a low-data network")
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

    /// What to do about Needs attention. Only a resync recovers when bisync says so,
    /// or when its listings from the last run are missing (it then still calls the
    /// error retryable under --resilient); anything else may pass on the next attempt.
    static func advice(for status: SyncStatus, transcriptLines: [String]) -> String? {
        guard case .unhealthy = status else { return nil }
        let needsResync = ["must run --resync", "cannot find prior Path1 or Path2 listings"]
        if transcriptLines.contains(where: { line in needsResync.contains { line.localizedCaseInsensitiveContains($0) } }) {
            return "rclone needs a resync to recover.\nChoose Resync… to run one."
        }
        return "Choose Sync Now to try again.\nLatest run shows what rclone reported."
    }

    /// Menu rows are single lines, so messages put each short line in its own row.
    private func lines(_ text: String) -> some View {
        ForEach(text.split(separator: "\n").map(String.init), id: \.self) { Text($0) }
    }

    // An NSAlert rather than .confirmationDialog: the menu closes before the
    // action runs, so a dialog attached to the menu content is never presented.
    private func confirmResync() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run recovery resync?"
        alert.informativeText = "Resync can overwrite files. Use it only to initialize or recover rclone bisync."
        alert.addButton(withTitle: "Resync").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { coordinator.resync() }
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
