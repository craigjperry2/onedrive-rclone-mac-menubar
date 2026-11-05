import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: SyncCoordinator

    var body: some View {
        Group {
            Text(coordinator.status.title)
            if let loginWarning = coordinator.loginWarning {
                lines(loginWarning)
                Button("Open Login Items Settings…", action: LoginItemManager.openSystemSettings)
            }
            if let persistenceWarning = coordinator.persistenceWarning { Text(persistenceWarning) }
            if let lastSuccess = coordinator.latestRun?.lastSuccessAt {
                Text("Last successful sync: \(lastSuccess.formatted(date: .abbreviated, time: .shortened))")
            }
            if let reason = coordinator.status.reason { lines(reason) }
            if let skip = coordinator.activity.entries.last, skip.outcome == .skipped(.lowDataNetwork) {
                Text("Scheduled syncs paused on a low-data network")
                Text("Skipped \(skip.count == 1 ? "1 sync" : "\(skip.count) syncs") since \(skip.startedAt.formatted(date: .omitted, time: .shortened))")
            }
            if coordinator.isRunning { Text("rclone is running…") }

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
            Button("Sync Now", action: coordinator.syncNow).disabled(!coordinator.canStartSync)
            Button("Resync…", action: confirmResync).disabled(!coordinator.canStartSync)
            Divider()
            Text(versionTitle)
            Button("Quit OneDrive Sync") { NSApplication.shared.terminate(nil) }
                .disabled(coordinator.isRunning)
        }
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
    private var versionTitle: String {
        let info = Bundle.main.infoDictionary
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
