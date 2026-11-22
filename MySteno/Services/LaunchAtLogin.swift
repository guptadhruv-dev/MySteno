import OSLog
import ServiceManagement

@Observable
final class LaunchAtLogin {
    private static let logger = Logger(subsystem: "dev.guptadhruv.mysteno", category: "LaunchAtLogin")

    var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Self.logger.error("\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
