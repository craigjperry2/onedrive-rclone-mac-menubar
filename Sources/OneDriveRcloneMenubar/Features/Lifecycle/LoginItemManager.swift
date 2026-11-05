import ServiceManagement

@MainActor
protocol LoginItemControlling {
    func registerIfNeeded()
    /// Explains why the app will not start at login, or nil when it will.
    func warning() -> String?
}

struct LoginItemManager: LoginItemControlling {
    /// Registers an app that is not in the login items, including after the user
    /// removed it from the list. When they switched it off in System Settings, the
    /// status is requiresApproval and that choice stands until they change it there.
    func registerIfNeeded() {
        guard Self.isUnregistered else { return }
        try? SMAppService.mainApp.register()
    }

    // Removing the app from Login Items reports notFound rather than notRegistered.
    private static var isUnregistered: Bool { [.notRegistered, .notFound].contains(SMAppService.mainApp.status) }

    func warning() -> String? { Self.warning(for: SMAppService.mainApp.status) }

    nonisolated static func warning(for status: SMAppService.Status) -> String? {
        switch status {
        case .enabled: nil
        case .requiresApproval: "OneDrive Sync will not start at login\nuntil you allow it in Login Items."
        case .notRegistered, .notFound: "OneDrive Sync will not start at login.\nAllow it in Login Items to sync after restarts."
        @unknown default: "OneDrive Sync may not start at login.\nCheck Login Items in System Settings."
        }
    }

    /// Adds the app back to the login items if the user removed it, then opens Login
    /// Items so they can see it or approve it.
    static func openSystemSettings() {
        if isUnregistered { try? SMAppService.mainApp.register() }
        SMAppService.openSystemSettingsLoginItems()
    }
}
