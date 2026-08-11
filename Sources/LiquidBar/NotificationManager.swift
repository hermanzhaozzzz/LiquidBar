import AppKit
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var onNotificationActivated: (() -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
            await refreshAuthorization()
            return granted
        } catch {
            AppLogger.shared.log("notification authorization failed: \(error.localizedDescription)")
            await refreshAuthorization()
            return false
        }
    }

    func send(severity: AlertSeverity, soundEnabled: Bool) {
        guard authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text(severity == .critical ? "criticalTitle" : "warningTitle")
        content.body = L10n.text(severity == .critical ? "criticalBody" : "warningBody")
        if severity == .critical && soundEnabled {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: "LiquidBar.thermal.\(severity.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLogger.shared.log("notification delivery failed: \(error.localizedDescription)")
            }
        }
    }

    func sendDeviceError() {
        guard authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "LiquidBar"
        content.body = L10n.text("deviceError")
        let request = UNNotificationRequest(
            identifier: "LiquidBar.device.offline",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.onNotificationActivated?()
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
