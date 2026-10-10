import Foundation
import os
import RotaCore
import UserNotifications

/// Posts a macOS notification when a run fails, and on success when asked to.
final class Notifier: NSObject, RunNotifying, UNUserNotificationCenterDelegate {
    private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "notifications")
    var notifyOnSuccess: () -> Bool = { false }
    private static let sessionKey = "session"
    private static let routineKey = "routine"
    /// Opens what a clicked notification is about.
    var open: (SidebarItem) -> Void = { _ in }

    /// The notification center needs a bundle; the bare debug binary has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.info("Notifications \(granted ? "allowed" : "denied", privacy: .public)")
            }
        }
    }

    func runEnded(_ record: RunRecord, routine: Routine) {
        guard let center, record.outcome.isFailure || (record.outcome == .succeeded && notifyOnSuccess())
        else { return }
        let content = UNMutableNotificationContent()
        content.title = routine.name
        content.body = "\(record.outcome.title) on \(record.harness.title)"
        if record.outcome.isFailure { content.sound = .default }
        // A skipped slot has no session to open; its routine shows it.
        content.userInfo = record.isSkip ? [Self.routineKey: routine.id] : [Self.sessionKey: record.id.uuidString]
        center.add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
    }

    func routinePaused(_ routine: Routine, failures: Int) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = routine.name
        content.body = "Paused after \(failures) failed runs in a row. Turn it on again once it is fixed."
        content.sound = .default
        content.userInfo = [Self.routineKey: routine.id]
        center.add(UNNotificationRequest(identifier: "paused-\(routine.id)", content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let item: SidebarItem? = if let session = (info[Self.sessionKey] as? String).flatMap(UUID.init(uuidString:)) {
            .session(session)
        } else if let routine = info[Self.routineKey] as? String {
            .routine(routine)
        } else {
            nil
        }
        if let item { DispatchQueue.main.async { self.open(item) } }
        completionHandler()
    }
}
