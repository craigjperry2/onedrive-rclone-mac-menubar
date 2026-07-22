import ServiceManagement

enum LoginItemManager {
    static func register() -> String? {
        if SMAppService.mainApp.status == .enabled { return nil }
        do {
            try SMAppService.mainApp.register()
            return nil
        } catch {
            return "Launch at login needs approval in System Settings: \(error.localizedDescription)"
        }
    }
}
