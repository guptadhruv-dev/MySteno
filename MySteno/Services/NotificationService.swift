import OSLog
import UserNotifications

actor NotificationService {
    private static let logger = Logger(subsystem: "dev.guptadhruv.mysteno", category: "Notifications")

    func send(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            }
            let updatedSettings = await center.notificationSettings()
            guard updatedSettings.authorizationStatus == .authorized ||
                    updatedSettings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try await center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        } catch {
            Self.logger.error("\(error.localizedDescription, privacy: .public)")
        }
    }
}
