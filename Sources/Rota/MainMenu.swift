import AppKit
import RotaCore
import SwiftUI

/// SwiftUI drops a trailing command-group divider before AppKit adds Full Screen.
@MainActor
enum MainMenu {
    static func separateFullScreen(in menu: NSMenu) {
        guard let index = menu.items.firstIndex(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }),
              index > 0, !menu.items[index - 1].isSeparatorItem else { return }
        menu.insertItem(.separator(), at: index)
    }
}

/// View > Hide Sidebar / Show Sidebar, the Schedule, and interface/chat zoom.
struct ViewMenuCommands: View {
    @State private var model = AppModel.shared

    var body: some View {
        @Bindable var schedule = model.schedule
        let unavailable = model.scheduler.routines.isEmpty || model.settingsPane != nil
        Button(model.sidebarShown ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
            .keyboardShortcut("s", modifiers: [.control, .command])
            // Settings' sections and Back live in the sidebar.
            .disabled(model.settingsPane != nil)
        // A checkmark rather than Show/Hide: AppKit refreshes a command's title only when its menu opens.
        Toggle("Show Schedule", isOn: Binding(get: { model.showsSchedule }, set: { _ in model.toggleSchedule() }))
            .keyboardShortcut("s", modifiers: [.shift, .command])
            .disabled(unavailable)
        Menu("Schedule") {
            Button("Today") {
                model.showSchedule()
                schedule.goToToday(now: model.scheduler.now(), calendar: model.scheduler.calendar)
            }
            Button("Previous Week") {
                model.showSchedule()
                schedule.step(-1, calendar: model.scheduler.calendar)
            }
            Button("Next Week") {
                model.showSchedule()
                schedule.step(1, calendar: model.scheduler.calendar)
            }
            Divider()
            Toggle("Show Paused Routines", isOn: $schedule.showPaused)
        }
        .disabled(unavailable)
        Divider()
        Button("Zoom In") { model.interfaceScale.increase() }
            .disabled(!model.interfaceScale.canIncrease)
            .keyboardShortcut("+")
        Button("Zoom Out") { model.interfaceScale.decrease() }
            .disabled(!model.interfaceScale.canDecrease)
            .keyboardShortcut("-")
        Button("Reset") { model.interfaceScale.reset() }
            .keyboardShortcut("0")
        Divider()
        Menu("Chat Zoom") {
            Button("Zoom In") { model.chatText.increase() }
                .disabled(!model.chatText.canIncrease)
                .keyboardShortcut("+", modifiers: [.command, .option])
            Button("Zoom Out") { model.chatText.decrease() }
                .disabled(!model.chatText.canDecrease)
                .keyboardShortcut("-", modifiers: [.command, .option])
            Button("Reset") { model.chatText.reset() }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
        Divider()
    }
}

/// The Routine menu: what a person does to the routine in front of them.
struct RoutineCommands: Commands {
    var body: some Commands {
        CommandMenu("Routine") {
            let model = AppModel.shared
            let routine = model.selectedRoutine
            let running = routine.map { model.scheduler.hasActiveSession($0.id) } ?? false
            let selectedSession: UUID? = if case .session(let id) = model.selection { id } else { nil }
            let canStop = selectedSession.map { model.scheduler.active[$0] != nil } ?? running
            Button("Run Now") {
                guard let routine else { return }
                model.scheduler.run(routine, trigger: .manual)
                model.selection = model.latest(of: routine.id)
            }
            .keyboardShortcut("r")
            .disabled(routine == nil || running)
            Button("Stop") {
                if let selectedSession { model.scheduler.stop(selectedSession) } else {
                    routine.map { model.scheduler.stop($0.id) }
                }
            }
                .keyboardShortcut(".")
                .disabled(!canStop)
            Divider()
            Button("Edit Routine\u{2026}") { model.editSelectedRoutine() }
                .keyboardShortcut("e")
                .disabled(routine == nil)
        }
    }
}

/// The Session menu: everything the open session's header, banners and chat offer,
/// so each works from the keyboard wherever focus is.
struct SessionCommands: Commands {
    var body: some Commands {
        CommandMenu("Session") {
            let model = AppModel.shared
            let routine = model.selectedRoutine
            let record: RunRecord? = if case .session(let id) = model.selection {
                model.scheduler.current(id, routineID: routine?.id)
            } else { nil }
            Button("Show Routine") { routine.map { model.selection = .routine($0.id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(record == nil)
            Menu("Restart With") {
                if let record {
                    ForEach(model.restartChoices(for: record), id: \.harness) { harness, installed in
                        Button(harness.title) { Task { await model.restart(record, with: harness) } }
                            .disabled(!installed)
                    }
                }
            }
            .disabled(record.map { !$0.harness.isAgent || !model.scheduler.canRestart($0) } ?? true)
            // The keyboard route to a Shell session's agent picker: choose, then write in the field.
            Menu("Ask Agent About Run") {
                if let record, model.scheduler.canDiscuss(record) {
                    let choices = model.restartChoices(for: record)
                    DiscussionAgentChoices(model: model, choices: choices, agent: model.discussionAgent(in: choices),
                                           picked: model.keyboard.focusComposer)
                }
            }
            .disabled(record.map { !model.scheduler.canDiscuss($0) } ?? true)
            Button(record.map(model.terminalTitle) ?? "Continue in Terminal") { record.map(model.openInTerminal) }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(record.map { model.scheduler.terminalCommand(for: $0) == nil } ?? true)
            Button("Show Log in Finder") {
                record.map(model.revealLog)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(record?.logPath == nil)
            Divider()
            Button("Show Question") { model.keyboard.revealQuestion() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(record?.nextQuestion == nil)
            // The banner's Dismiss or Done: a request without a question form.
            Button("Dismiss Attention") { record.map { model.scheduler.dismissAttention($0) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(record?.showsAttentionBanner != true)
            Menu("Quick Replies") {
                let replies = model.settings.sendableReplies
                let canSend = record.map(model.scheduler.acceptsMessage) ?? false
                ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
                    Button(reply.label) { model.keyboard.sendQuickReply(reply) }
                        .keyboardShortcut(QuickReply.shortcut(at: index))
                        .disabled(!canSend)
                }
                if !replies.isEmpty { Divider() }
                Button("Edit Quick Replies\u{2026}") { model.showSettings(.chat) }
            }
            Button("Load Earlier Messages") { model.keyboard.loadEarlierMessages() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(record == nil || model.keyboard.sessionWithEarlier != record?.id)
            Divider()
            // Delete in the focused session list asks too; Command-Delete stays text editing.
            Button("Delete Session\u{2026}") { model.sessionToDelete = record }
                .disabled(record.map { !model.scheduler.canDelete($0) } ?? true)
        }
    }
}
