import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: SyncCoordinator

    var body: some View {
        Group {
            Text(coordinator.status.title)
            if let loginWarning = coordinator.loginWarning { Text(loginWarning) }
            if let persistenceWarning = coordinator.persistenceWarning { Text(persistenceWarning) }
            if let lastSuccess = coordinator.latestRun?.lastSuccessAt {
                Text("Last successful sync: \(lastSuccess.formatted(date: .abbreviated, time: .shortened))")
            }
            if let reason = coordinator.status.reason { Text(reason) }
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
            Button("Quit OneDrive Sync") { NSApplication.shared.terminate(nil) }
                .disabled(coordinator.isRunning)
        }
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

    private var latestRunTitle: String {
        guard let latestRun = coordinator.latestRun else { return "Latest run: none" }
        return "Latest run: \(latestRun.finishedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
