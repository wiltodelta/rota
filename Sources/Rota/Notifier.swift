import Foundation
import os
import RotaCore
import UserNotifications

/// Posts a macOS notification when a run fails, and on success when asked to.
@MainActor
final class Notifier: NSObject, RunNotifying, UNUserNotificationCenterDelegate {
    nonisolated private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "notifications")
    var notifyOnSuccess: () -> Bool = { false }
    nonisolated private static let sessionKey = "session"
    nonisolated private static let routineKey = "routine"
    /// Opens what a clicked notification is about.
    var open: (SidebarItem) -> Void = { _ in }
    /// Sends what the user typed into a notification's Reply field to its session.
    var reply: (UUID, String) -> Void = { _, _ in }
    var canReply: (RunRecord) -> Bool = { _ in false }
    private static let replyCategory = "rota.reply"
    private static let replyAction = "reply"

    // Keep delivery, expiry and removal injectable: tests must never post real notifications.
    typealias DeliveryCompletion = @MainActor @Sendable (Error?) -> Void
    var deliver: (UNNotificationRequest, @escaping DeliveryCompletion) -> Void = { request, completion in
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in completion(error) }
        }
    }
    var scheduleExpiry: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
    var removeDelivered: ([String]) -> Void = { identifiers in
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func post(_ content: UNNotificationContent, id: String, temporary: Bool) {
        // A later failure may reuse the run id. An old success timer must not remove it.
        let identifier = temporary ? "\(id)-\(UUID().uuidString)" : id
        deliver(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
            if let error {
                Self.log.error("Notification delivery failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let self, temporary else { return }
            // macOS owns the app-wide banner style. With Persistent selected,
            // withdraw only informational notifications after their brief display.
            scheduleExpiry(8) { [weak self] in self?.removeDelivered([identifier]) }
        }
    }

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
        guard record.outcome.isFailure || (record.outcome == .succeeded && notifyOnSuccess())
        else { return }
        let content = UNMutableNotificationContent()
        content.title = routine.name
        content.body = "\(record.outcome.title) on \(record.harness.title)"
        if record.outcome.isFailure { content.sound = .default }
        // A skipped slot has no session to open; its routine shows it.
        content.userInfo = record.isSkip ? [Self.routineKey: routine.id] : [Self.sessionKey: record.id.uuidString]
        post(content, id: record.id.uuidString, temporary: !requiresAttention(record))
    }

    func routinePaused(_ routine: Routine, failures: Int) {
        let content = UNMutableNotificationContent()
        content.title = routine.name
        content.body = "Paused after \(failures) failed runs in a row. Turn it on again once it is fixed."
        content.sound = .default
        content.userInfo = [Self.routineKey: routine.id]
        post(content, id: "paused-\(routine.id)", temporary: false)
    }

    func routineAdded(_ routine: Routine) {
        let content = UNMutableNotificationContent()
        content.title = routine.name
        let state = routine.enabled ? (ScheduleText.describe(routine.schedule) ?? routine.schedule) : "turned off"
        content.body = "Added by an agent: \(routine.harness.title), \(state)."
        content.userInfo = [Self.routineKey: routine.id]
        post(content, id: "added-\(routine.id)", temporary: true)
    }

    func sessionNotified(_ record: RunRecord?, routine: Routine?, title: String?, text: String, needsReply: Bool) {
        let content = sessionContent(record, routine: routine, title: title, text: text, needsReply: needsReply)
        let id = "notify-\(record?.id.uuidString ?? "rota")-\(UUID().uuidString)"
        post(content, id: id, temporary: !(needsReply || requiresAttention(record)))
        Self.log.info("Notified from \(record?.routineID ?? "outside a routine", privacy: .public)")
    }

    private func requiresAttention(_ record: RunRecord?) -> Bool {
        record?.attention != nil || record?.questions?.isEmpty == false || record?.outcome.isFailure == true
    }

    /// Build the same content used for delivery without requesting notification permission.
    func sessionContent(_ record: RunRecord?, routine: Routine?, title: String?, text: String,
                        needsReply: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title ?? routine?.name ?? "Rota"
        if needsReply {
            content.subtitle = record.map { canReply($0) ? "Needs your reply" : "Needs your attention" }
                ?? "Needs your attention"
        }
        content.body = text
        content.sound = .default
        if let record {
            content.userInfo = [Self.sessionKey: record.id.uuidString]
            if canReply(record), record.questions?.isEmpty != false {
                content.categoryIdentifier = Self.replyCategory
            }
        }
        return content
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
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
