import AppKit
import RotaCore
import SwiftUI

/// A bounded, scrollable form. Only the footer submits, and no option is preselected.
struct QuestionCard: View {
    @Environment(\.interfaceScale) private var metrics
    let question: AgentQuestion
    let submit: (QuestionAnswer) throws -> Void
    @State private var values: [String: [String]] = [:]
    @State private var other: [String: String] = [:]
    @State private var customFields: Set<String> = []
    @FocusState private var focusedField: String?
    @State private var failure: String?
    @State private var contentHeight: CGFloat?

    private enum Selection: Hashable { case option(String), other }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(10)) {
            Label(question.title, systemImage: "exclamationmark.bubble.fill")
                .interfaceFont(.headline)
                .accessibilityIdentifier("questionTitle")
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.points(16)) {
                    if !question.detail.isEmpty {
                        Text(question.detail).interfaceFont(.body).textSelection(.enabled)
                    }
                    if let text = question.url, let url = URL(string: text), ["https", "http"].contains(url.scheme) {
                        Link(destination: url) { Text("Open in Browser").interfaceFont(.body) }
                    }
                    ForEach(question.fields) { field in fieldView(field) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, metrics.points(8))
                // Native focus rings extend beyond the field's layout bounds.
                .padding(metrics.points(4))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(minHeight: 0, maxHeight: min(contentHeight ?? .infinity, metrics.points(260)))
            if let failure {
                Text(failure).interfaceFont(.callout).foregroundStyle(Color.errorText)
                    .accessibilityIdentifier("questionError")
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    dismissButtons
                    Spacer(minLength: metrics.points(12))
                    answerButtons
                }
                HStack {
                    dismissButtons
                    Spacer(minLength: metrics.points(12))
                    compactAnswerButtons
                }
                VStack(alignment: .leading, spacing: metrics.points(8)) {
                    HStack { dismissButtons; Spacer(minLength: 0) }
                    HStack { Spacer(minLength: 0); compactAnswerButtons }
                }
            }
        }
        .padding(metrics.points(16))
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: metrics.points(12)))
        .padding(.horizontal, metrics.points(24))
        .padding(.vertical, metrics.points(12))
        .frame(maxWidth: metrics.points(760))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("questionCard")
    }

    private var answer: QuestionAnswer {
        var combined = values
        for (id, text) in other where !text.isEmpty {
            guard let field = question.fields.first(where: { $0.id == id }),
                field.options.isEmpty || customFields.contains(id) else { continue }
            if field.kind == .multiple {
                combined[id, default: []].append(text)
            } else {
                combined[id] = [text]
            }
        }
        return QuestionAnswer(values: combined)
    }

    @ViewBuilder private var dismissButtons: some View {
        Button(interfaceTitle: "Cancel") { send("cancel") }
            .accessibilityIdentifier("cancelQuestion")
        if question.allowsDecline == true {
            Button(interfaceTitle: "Decline") { send("decline") }
                .accessibilityIdentifier("declineQuestion")
        }
    }

    @ViewBuilder private var answerButtons: some View {
        ForEach(question.actions) { action in
            if question.actions.count == 1 {
                actionButton(action).buttonStyle(.borderedProminent)
            } else {
                actionButton(action)
            }
        }
    }

    @ViewBuilder private var compactAnswerButtons: some View {
        if question.actions.count > 1 {
            InterfacePicker(
                title: "Choose…",
                selection: Binding<String?>(get: { nil }, set: { selected in
                    if let selected { send(selected) }
                }),
                choices: [.item("Choose…", nil)] + question.actions.map { .item($0.label, Optional($0.id)) },
                identifier: "questionActions", hidesLabel: true, fitsSelectedTitle: true)
                .disabled(
                    hasEmptyCustomAnswer
                        || question.validationMessage(
                            QuestionAnswer(action: question.actions[0].id, values: answer.values)) != nil)
        } else {
            answerButtons
        }
    }

    private func actionButton(_ action: QuestionOption) -> some View {
        Button {
            send(action.id)
        } label: {
            Text(action.label).interfaceFont(.body)
        }
        .help(action.detail)
        .disabled(
            hasEmptyCustomAnswer
                || question.validationMessage(QuestionAnswer(action: action.id, values: answer.values)) != nil)
        .accessibilityIdentifier("answerQuestion-" + action.id)
    }

    private var hasEmptyCustomAnswer: Bool {
        customFields.contains { (other[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func send(_ action: String) {
        do { try submit(QuestionAnswer(action: action, values: answer.values)) } catch {
            failure = error.localizedDescription
        }
    }

    @ViewBuilder
    private func fieldView(_ field: QuestionField) -> some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            Text(field.title + (field.required ? "" : " (optional)"))
                .interfaceFont(.body).fontWeight(.semibold)
            if !field.detail.isEmpty {
                Text(field.detail).interfaceFont(.callout).foregroundStyle(Color.secondaryText)
            }
            if field.kind == .boolean {
                singleChoice([.init(id: "true", label: "Yes"), .init(id: "false", label: "No")], field: field)
            } else {
                if field.kind == .multiple {
                    ForEach(field.options) { option($0, field: field) }
                } else if !field.options.isEmpty {
                    singleChoice(field.options, field: field)
                }
                if field.kind == .multiple, !field.options.isEmpty, field.allowsOther {
                    Toggle("Other", isOn: Binding(
                        get: { customFields.contains(field.id) },
                        set: { selectOther($0, field: field) }))
                        .toggleStyle(.checkbox)
                        .interfaceFont(.body)
                        .accessibilityIdentifier("questionOther-" + field.id)
                }
                if field.options.isEmpty || customFields.contains(field.id) {
                    answerField(field)
                        .padding(.leading, field.options.isEmpty ? 0 : metrics.points(20))
                }
            }
        }
    }

    @ViewBuilder private func answerField(_ field: QuestionField) -> some View {
        Group {
            if field.kind == .secret {
                SecureField("Your answer", text: text(field))
            } else if field.kind == .number || field.kind == .integer {
                TextField("Your answer", text: text(field))
            } else {
                TextField("Your answer", text: text(field), axis: .vertical)
                    .lineLimit(2...4)
            }
        }
        .interfaceFont(.body)
        .textFieldStyle(.roundedBorder)
        .focused($focusedField, equals: field.id)
        .accessibilityLabel(field.title + (field.options.isEmpty ? "" : ", other answer"))
        .accessibilityIdentifier("questionField-" + field.id)
    }

    private func text(_ field: QuestionField) -> Binding<String> {
        Binding(get: { other[field.id] ?? "" }, set: { other[field.id] = $0 })
    }

    private func selectOther(_ selected: Bool, field: QuestionField) {
        if selected {
            customFields.insert(field.id)
            focusedField = field.id
        } else {
            customFields.remove(field.id)
        }
    }

    private func singleChoice(_ options: [QuestionOption], field: QuestionField) -> some View {
        Picker(field.title, selection: Binding<Selection?>(get: {
            customFields.contains(field.id) ? .other : values[field.id]?.first.map { .option($0) }
        }, set: { selection in
            if selection == .other {
                values[field.id] = nil
                selectOther(true, field: field)
            } else {
                values[field.id] = selection.flatMap {
                    if case let .option(id) = $0 { return [id] }
                    return nil
                }
                selectOther(false, field: field)
            }
        })) {
            ForEach(options) { option in
                QuestionOptionLabel(option: option)
                    .tag(Optional(Selection.option(option.id)))
                    .accessibilityIdentifier("questionOption-" + field.id + "-" + option.id)
            }
            if !field.options.isEmpty, field.allowsOther {
                Text("Other").interfaceFont(.body)
                    .tag(Optional(Selection.other))
                    .accessibilityIdentifier("questionOther-" + field.id)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    private func option(_ option: QuestionOption, field: QuestionField) -> some View {
        Toggle(
            isOn: Binding(
                get: { values[field.id]?.contains(option.id) == true },
                set: { selected in
                    var choices = values[field.id] ?? []
                    choices.removeAll { $0 == option.id }
                    if selected { choices.append(option.id) }
                    values[field.id] = choices
                })
        ) {
            QuestionOptionLabel(option: option)
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("questionOption-" + field.id + "-" + option.id)
    }
}

private struct QuestionOptionLabel: View {
    @Environment(\.interfaceScale) private var metrics
    let option: QuestionOption

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(2)) {
            Text(option.label).interfaceFont(.body)
            if !option.detail.isEmpty {
                Text(option.detail).interfaceFont(.callout).foregroundStyle(Color.secondaryText)
            }
        }
    }
}
