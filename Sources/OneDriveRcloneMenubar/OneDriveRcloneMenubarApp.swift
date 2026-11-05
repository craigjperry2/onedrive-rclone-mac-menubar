import SwiftUI

@main
@MainActor
struct OneDriveRcloneMenubarApp: App {
    @StateObject private var coordinator: SyncCoordinator

    init() {
        let coordinator = SyncCoordinator()
        _coordinator = StateObject(wrappedValue: coordinator)
        Task { await coordinator.load() }
    }

    var body: some Scene {
        MenuBarExtra("OneDrive Sync", systemImage: coordinator.status.symbolName) {
            MenuBarView(coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)

        Window("Set Up OneDrive Sync", id: "setup") {
            SetupView(coordinator: coordinator)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
