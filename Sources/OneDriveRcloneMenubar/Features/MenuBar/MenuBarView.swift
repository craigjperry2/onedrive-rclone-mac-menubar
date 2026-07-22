import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @State private var showingResyncConfirmation = false

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
            Button("Resync…") { showingResyncConfirmation = true }.disabled(!coordinator.canStartSync)
            Divider()
            Button("Quit OneDrive Sync") { NSApplication.shared.terminate(nil) }
                .disabled(coordinator.isRunning)
        }
        .confirmationDialog("Run recovery resync?", isPresented: $showingResyncConfirmation, titleVisibility: .visible) {
            Button("Resync", role: .destructive, action: coordinator.resync)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Resync can overwrite files. Use it only to initialize or recover rclone bisync.")
        }
    }

    private var latestRunTitle: String {
        guard let latestRun = coordinator.latestRun else { return "Latest run: none" }
        return "Latest run: \(latestRun.finishedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
