import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: SyncCoordinator
    @State private var showingResyncConfirmation = false

    var body: some View {
        Text(coordinator.status.title)
        if let loginWarning = coordinator.loginWarning { Text(loginWarning) }
        if let latestRun = coordinator.latestRun {
            Text("Most recent sync: \(latestRun.finishedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if case let .disabled(reason) = coordinator.status { Text(reason) }
        if case let .unhealthy(reason) = coordinator.status { Text(reason) }
        if case .running = coordinator.status { Text("rclone is running…") }

        Menu("Latest run output") {
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
            .confirmationDialog("Run recovery resync?", isPresented: $showingResyncConfirmation, titleVisibility: .visible) {
                Button("Resync", role: .destructive, action: coordinator.resync)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Resync can overwrite files. Use it only to initialize or recover rclone bisync.")
            }
    }
}
