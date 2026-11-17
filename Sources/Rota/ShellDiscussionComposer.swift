import RotaCore
import SwiftUI

/// The field under a finished Shell session: a message to an agent of the user's choice about
/// this run. Sending starts that agent's session with the run attached as context and opens it;
/// the Shell session links to every discussion it started.
struct ShellDiscussionComposer: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord
    @FocusState private var focused: Bool
    @State private var starting = false

    private var input: Binding<String> { model.draft(for: record) }
    private var message: String { input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        // Installed agents are checked on disk: once per update, shared by the picker and Send.
        let choices = model.restartChoices(for: record)
        let agent = model.discussionAgent(in: choices)
        let canSend = !message.isEmpty && !starting && agent != nil && model.scheduler.canDiscuss(record)
        VStack(alignment: .leading, spacing: metrics.points(8)) {
            DiscussionLinks(record: record)
            box(agent: agent, choices: choices, canSend: canSend)
        }
    }

    private func box(agent: Harness?, choices: [(harness: Harness, installed: Bool)], canSend: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.points(10)) {
            TextField("Ask an agent about this run", text: input, axis: .vertical)
                .font(model.chatText.body)
                .lineSpacing(model.chatText.bodyLineSpacing)
                .lineLimit(2...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { send(to: canSend ? agent : nil) }
                .onChange(of: model.keyboard.composerFocus) { focused = true }
                .onExitCommand { if model.sidebarShown { model.keyboard.focusList() } }
                .help("Starts a session on the chosen agent with this run attached. "
                      + "Return sends, Option-Return starts a new line.")
                .accessibilityLabel("Message")
                .accessibilityIdentifier("composer")
            GlassControls(spacing: metrics.points(8)) {
                HStack(spacing: metrics.points(8)) {
                    agentPicker(agent: agent, choices: choices)
                    Spacer(minLength: 8)
                    if starting {
                        ProgressView().controlSize(.small).frame(width: metrics.points(28), height: metrics.points(28))
                    } else {
                        RoundButton(symbol: "arrow.up", filled: canSend, fill: Color.accentColor,
                                    foreground: canSend ? .white : Color.secondaryText) { send(to: agent) }
                            .disabled(!canSend)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Send (Return)")
                            .accessibilityLabel("Send")
                            .accessibilityIdentifier("send")
                    }
                }
            }
        }
        .modifier(ComposerBox(compact: false, highlighted: focused))
        .onTapGesture { focused = true }
    }

    private func agentPicker(agent: Harness?, choices: [(harness: Harness, installed: Bool)]) -> some View {
        Menu {
            DiscussionAgentChoices(model: model, choices: choices, agent: agent)
            Divider()
            Button("Agent Settings\u{2026}") { model.showSettings(.agents) }
                .accessibilityIdentifier("discussionAgentSettings")
        } label: {
            HStack(spacing: metrics.points(6)) {
                if let agent { HarnessLogo(harness: agent) }
                Text(agent?.title ?? "No agent installed")
                Image(systemName: "chevron.down").interfaceSystemFont(size: 9, weight: .semibold)
            }
            .interfaceFont(.callout)
            .foregroundStyle(Color.secondaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The agent that answers. It uses its default model.")
        .accessibilityLabel("Agent")
        .accessibilityValue(agent?.title ?? "None")
        .accessibilityIdentifier("discussionAgent")
    }

    private func send(to agent: Harness?) {
        guard let agent, !message.isEmpty, !starting else { return }
        let text = message
        starting = true
        Task {
            defer { starting = false }
            guard let next = await model.scheduler.discuss(record, with: agent, message: text) else { return }
            model.sessionDrafts[record.id] = nil
            model.selection = .session(next.id)
        }
    }
}

/// The agents a Shell run can be discussed with, the chosen one checked; shared by the field's
/// picker and Session > Ask Agent About Run. The model is passed in: the menu bar's commands
/// have no `AppModel` in their environment, and reading it there traps.
struct DiscussionAgentChoices: View {
    let model: AppModel
    let choices: [(harness: Harness, installed: Bool)]
    let agent: Harness?
    var picked: () -> Void = {}

    var body: some View {
        ForEach(choices, id: \.harness) { harness, installed in
            Toggle(harness.title, isOn: Binding(get: { harness == agent }, set: { _ in
                model.settings.discussionAgent = harness
                picked()
            }))
            .disabled(!installed)
            .accessibilityIdentifier("discussWith-\(harness.rawValue)")
        }
    }
}

/// The Shell session's discussions as chips in the quick replies' place, since it has none.
/// A separate view, so typing in the field does not rescan the routine's history.
private struct DiscussionLinks: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord

    var body: some View {
        let discussions = model.scheduler.discussions(of: record)
        if !discussions.isEmpty {
            SessionFilterFlow(spacing: metrics.points(6)) {
                ForEach(discussions) { discussion in
                    Button { model.selection = .session(discussion.id) } label: {
                        HStack(spacing: metrics.points(6)) {
                            HarnessLogo(harness: discussion.harness, size: 12)
                            Text("\(discussion.harness.title), "
                                 + discussion.startedAt.formatted(date: .omitted, time: .shortened))
                                .interfaceFont(.callout).lineLimit(1)
                        }
                        .modifier(Chip())
                    }
                    .buttonStyle(.plain)
                    .help("Open the discussion with \(discussion.harness.title)")
                    .accessibilityLabel("Open the discussion with \(discussion.harness.title)")
                    .accessibilityIdentifier("shellDiscussion-\(discussion.id.uuidString)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.points(4))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Discussions")
        }
    }
}

extension AppModel {
    /// A session's message draft, kept per session until it is sent.
    func draft(for record: RunRecord) -> Binding<String> {
        Binding(get: { self.sessionDrafts[record.id] ?? "" }, set: { value in
            self.sessionDrafts[record.id] = value.isEmpty ? nil : value
        })
    }

    /// The remembered discussion agent while it is installed, else the first installed one.
    func discussionAgent(in choices: [(harness: Harness, installed: Bool)]) -> Harness? {
        choices.first { $0.harness == settings.discussionAgent && $0.installed }?.harness
            ?? choices.first(where: \.installed)?.harness
    }
}
