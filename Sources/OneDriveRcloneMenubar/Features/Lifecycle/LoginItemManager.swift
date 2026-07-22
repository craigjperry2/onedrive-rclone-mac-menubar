import ServiceManagement

enum LoginItemManager {
    static func register() -> String? {
        do {
            try SMAppService.mainApp.register()
            return nil
        } catch {
            return "Launch at login needs approval in System Settings: \(error.localizedDescription)"
        }
    }
}
