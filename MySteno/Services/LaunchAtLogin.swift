import OSLog
import ServiceManagement

@Observable
final class LaunchAtLogin {
    private static let logger = Logger(subsystem: "dev.guptadhruv.mysteno", category: "LaunchAtLogin")

    private(set) var status = SMAppService.mainApp.status
    private(set) var errorMessage: String?

    var isEnabled: Bool {
        status == .enabled
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not turn \(enabled ? "on" : "off") launch at login: \(error.localizedDescription)"
            Self.logger.error("\(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
