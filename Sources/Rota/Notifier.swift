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
    /// Sends what the user typed into a notification's Reply field to its session.
    var reply: (UUID, String) -> Void = { _, _ in }
    private static let replyCategory = "rota.reply"
    private static let replyAction = "reply"

    /// The notification center needs a bundle; the bare debug binary has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        // A session's notification can be answered from the banner, as Messages' can.
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.replyCategory, actions: [reply],
                                                                 intentIdentifiers: [])])
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

    func routineAdded(_ routine: Routine) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = routine.name
        let state = routine.enabled ? (ScheduleText.describe(routine.schedule) ?? routine.schedule) : "turned off"
        content.body = "Added by an agent: \(routine.harness.title), \(state)."
        content.userInfo = [Self.routineKey: routine.id]
        center.add(UNNotificationRequest(identifier: "added-\(routine.id)", content: content, trigger: nil))
    }

    func sessionNotified(_ record: RunRecord?, routine: Routine?, title: String?, text: String, needsReply: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title ?? routine?.name ?? "Rota"
        if needsReply { content.subtitle = "Needs your reply" }
        content.body = text
        content.sound = .default
        if let record {
            content.userInfo = [Self.sessionKey: record.id.uuidString]
            content.categoryIdentifier = Self.replyCategory
        }
        let id = "notify-\(record?.id.uuidString ?? "rota")-\(UUID().uuidString)"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        Self.log.info("Notified from \(record?.routineID ?? "outside a routine", privacy: .public)")
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
        if let typed = (response as? UNTextInputNotificationResponse)?.userText,
           let session = (info[Self.sessionKey] as? String).flatMap(UUID.init(uuidString:)) {
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { DispatchQueue.main.async { self.reply(session, text) } }
            return completionHandler()
        }
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
