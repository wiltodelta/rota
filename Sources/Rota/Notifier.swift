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
    private static let replyCategory = "rota.reply"
    private static let replyAction = "reply"

    /// The notification center needs a bundle; the bare debug binary has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func configure() {
        guard let center else { return }
        center.delegate = self
        // A session's notification can be answered from the banner, as Messages' can.
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.replyCategory, actions: [reply],
                                                                 intentIdentifiers: [])])
    }

    func requestAuthorization() {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.info("Notifications \(granted ? "allowed" : "denied", privacy: .public)")
            }
        }
    }

    func runEnded(_ record: RunRecord, routine: Routine) {
        guard center != nil, record.outcome.isFailure || (record.outcome == .succeeded && notifyOnSuccess())
        else { return }
        let content = UNMutableNotificationContent()
        content.title = routine.name
        content.body = "\(record.outcome.title) on \(record.harness.title)"
        if record.outcome.isFailure { content.sound = .default }
        // A skipped slot has no session to open; its routine shows it.
        content.userInfo = record.isSkip ? [Self.routineKey: routine.id] : [Self.sessionKey: record.id.uuidString]
        post(content, id: record.id.uuidString)
    }

    func routinePaused(_ routine: Routine, failures: Int) {
        guard center != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = routine.name
        content.body = "Paused after \(failures) failed runs in a row. Turn it on again once it is fixed."
        content.sound = .default
        content.userInfo = [Self.routineKey: routine.id]
        post(content, id: "paused-\(routine.id)")
    }

    func routineAdded(_ routine: Routine) {
        guard center != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = routine.name
        let state = routine.enabled ? (ScheduleText.describe(routine.schedule) ?? routine.schedule) : "turned off"
        content.body = "Added by an agent: \(routine.harness.title), \(state)."
        content.userInfo = [Self.routineKey: routine.id]
        post(content, id: "added-\(routine.id)")
    }

    func sessionNotified(_ record: RunRecord?, routine: Routine?, title: String?, text: String, needsReply: Bool) {
        guard center != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title ?? routine?.name ?? "Rota"
        if needsReply { content.subtitle = "Needs your reply" }
        content.body = text
        content.sound = .default
        if let record {
            content.userInfo = [Self.sessionKey: record.id.uuidString]
            if record.harness.takesMessages { content.categoryIdentifier = Self.replyCategory }
        }
        let id = "notify-\(record?.id.uuidString ?? "rota")-\(UUID().uuidString)"
        post(content, id: id)
        Self.log.info("Notification requested from \(record?.routineID ?? "outside a routine", privacy: .public)")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        guard center != nil else { return }
        // Audits exercise notification state without posting banners or requesting system grants.
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
           ProcessInfo.processInfo.environment["ROTA_TEST_DISABLE_NOTIFICATIONS"] == "1" { return }
        Task { @MainActor in
            do {
                let center = UNUserNotificationCenter.current()
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                Self.log.error("Could not deliver a notification: \(error.localizedDescription, privacy: .private)")
            }
        }
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
