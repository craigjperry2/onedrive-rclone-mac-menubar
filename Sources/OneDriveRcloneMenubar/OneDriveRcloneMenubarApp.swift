import SwiftUI

@main
struct OneDriveRcloneMenubarApp: App {
    @StateObject private var coordinator = SyncCoordinator()

    var body: some Scene {
        MenuBarExtra("OneDrive Sync", systemImage: coordinator.status.symbolName) {
            MenuBarView(coordinator: coordinator)
                .task { coordinator.load() }
        }
        .menuBarExtraStyle(.menu)
    }
}
