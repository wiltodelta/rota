import AppKit
import RotaCore
import SwiftUI

/// Question controls inside the transcript scroll view. No option is preselected.
struct QuestionCard: View {
    @Environment(\.interfaceScale) private var metrics
    @Bindable var draft: QuestionDraft
    private var question: AgentQuestion { draft.question }
    let submit: (QuestionAnswer) throws -> Void
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(10)) {
            HStack {
                Text(question.title).interfaceFont(question.fields.isEmpty ? .headline : .callout)
                    .foregroundStyle(question.fields.isEmpty ? Color.primary : Color.secondaryText)
                    .accessibilityIdentifier("questionTitle")
                Spacer(minLength: metrics.points(8))
                if question.fields.count > 1 {
                    Text("\(draft.fieldIndex + 1) of \(question.fields.count)")
                        .interfaceFont(.callout).foregroundStyle(Color.secondaryText)
                        .accessibilityIdentifier("questionProgress")
                }
            }
            VStack(alignment: .leading, spacing: metrics.points(16)) {
                if !question.detail.isEmpty {
                    Text(question.detail).interfaceFont(.body).textSelection(.enabled)
                }
                if let text = question.url, let url = URL(string: text), ["https", "http"].contains(url.scheme) {
                    Link(destination: url) { Text("Open in Browser").interfaceFont(.body) }
                }
                if let field = draft.currentField { fieldView(field) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, metrics.points(8))
            // Native focus rings extend beyond the field's layout bounds.
            .padding(metrics.points(4))

            if let failure = draft.failure {
                Text(failure).interfaceFont(.callout).foregroundStyle(Color.errorText)
                    .accessibilityIdentifier("questionError")
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    dismissButtons
                    Spacer(minLength: metrics.points(12))
                    forwardButtons
                }
                HStack {
                    dismissButtons
                    Spacer(minLength: metrics.points(12))
                    compactForwardButtons
                }
                VStack(alignment: .leading, spacing: metrics.points(8)) {
                    HStack { dismissButtons; Spacer(minLength: 0) }
                    HStack { Spacer(minLength: 0); compactForwardButtons }
                }
            }
        }
        .padding(metrics.points(16))
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: metrics.points(12)))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.points(12)).strokeBorder(Color.primary.opacity(0.08))
        }
        .frame(maxWidth: metrics.points(760))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("questionCard")
    }

    @ViewBuilder private var forwardButtons: some View {
        if draft.isLastField { answerButtons } else if draft.composerField == nil { nextButton }
    }

    @ViewBuilder private var compactForwardButtons: some View {
        if draft.isLastField { compactAnswerButtons } else if draft.composerField == nil { nextButton }
    }

    private var nextButton: some View {
        Button(interfaceTitle: "Next") { draft.moveForward() }
            .disabled(!draft.canAdvance)
            .accessibilityIdentifier("nextQuestion")
    }

    @ViewBuilder private var dismissButtons: some View {
        if draft.fieldIndex > 0 {
            Button(interfaceTitle: "Back") { draft.moveBack() }
                .accessibilityIdentifier("previousQuestion")
        }
        Button(interfaceTitle: "Cancel") { send("cancel") }
            .accessibilityIdentifier("cancelQuestion")
        if question.allowsDecline == true {
            Button(interfaceTitle: "Decline") { send("decline") }
                .accessibilityIdentifier("declineQuestion")
        }
    }

    @ViewBuilder private var answerButtons: some View {
        ForEach(composerSends ? [] : question.actions) { action in
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
                    !draft.canSubmit(question.actions[0].id))
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
            !draft.canSubmit(action.id))
        .accessibilityIdentifier("answerQuestion-" + action.id)
    }

    private var composerSends: Bool { draft.isLastField && draft.composerField != nil && question.actions.count == 1 }

    private func send(_ action: String) { draft.send(action, submit: submit) }

    @ViewBuilder
    private func fieldView(_ field: QuestionField) -> some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            Text(field.title + (field.required ? "" : " (optional)"))
                .interfaceFont(.headline)
            if !field.detail.isEmpty {
                Text(field.detail).interfaceFont(.callout).foregroundStyle(Color.secondaryText)
            }
            if field.kind == .boolean {
                choiceRows([.init(id: "true", label: "Yes"), .init(id: "false", label: "No")], field: field)
            } else {
                choiceRows(field.options, field: field)
                if !field.options.isEmpty, field.allowsOther {
                    choiceRow(number: field.options.count + 1,
                              option: .init(id: "other", label: "Something else…",
                                            detail: draft.customFields.contains(field.id)
                                                ? draft.other[field.id] ?? "" : ""),
                              selected: draft.customFields.contains(field.id), multiple: field.kind == .multiple) {
                        selectOther(field.kind != .multiple || !draft.customFields.contains(field.id), field: field)
                    }
                    .accessibilityIdentifier("questionOther-" + field.id)
                }
                if field.options.isEmpty || draft.customFields.contains(field.id) {
                    if draft.usesComposer(field) {
                        Text("Type your answer below.")
                            .interfaceFont(.callout).foregroundStyle(Color.secondaryText)
                    } else {
                        answerField(field)
                    }
                }
            }
        }
    }

    @ViewBuilder private func answerField(_ field: QuestionField) -> some View {
        Group {
            if field.kind == .secret {
                SecureField("Your answer", text: draft.text(for: field))
            } else {
                TextField("Your answer", text: draft.text(for: field))
            }
        }
        .interfaceFont(.body)
        .textFieldStyle(.roundedBorder)
        .focused($focusedField, equals: field.id)
        .accessibilityLabel(field.title + (field.options.isEmpty ? "" : ", other answer"))
        .accessibilityIdentifier("questionField-" + field.id)
    }

    private func selectOther(_ selected: Bool, field: QuestionField) {
        draft.selectOther(selected, field: field)
        if selected, !draft.usesComposer(field) { focusedField = field.id }
    }

    private func choiceRows(_ options: [QuestionOption], field: QuestionField) -> some View {
        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
            choiceRow(number: index + 1, option: option,
                      selected: draft.values[field.id]?.contains(option.id) == true,
                      multiple: field.kind == .multiple) {
                if field.kind == .multiple {
                    var choices = draft.values[field.id] ?? []
                    if choices.contains(option.id) { choices.removeAll { $0 == option.id } } else {
                        choices.append(option.id)
                    }
                    draft.values[field.id] = choices
                } else {
                    selectOther(false, field: field)
                    draft.values[field.id] = [option.id]
                }
            }
            .accessibilityIdentifier("questionOption-" + field.id + "-" + option.id)
        }
    }

    private func choiceRow(number: Int, option: QuestionOption, selected: Bool,
                           multiple: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.points(12)) {
                Text(String(number)).monospacedDigit()
                    .frame(minWidth: metrics.points(18), alignment: .center)
                VStack(alignment: .leading, spacing: metrics.points(3)) {
                    Text(option.label)
                    if !option.detail.isEmpty {
                        Text(option.detail).interfaceFont(.callout).foregroundStyle(Color.secondaryText)
                    }
                }
                Spacer(minLength: metrics.points(6))
                if selected || multiple {
                    Image(systemName: selected ? "checkmark" : "square")
                        .accessibilityHidden(true)
                }
            }
            .interfaceFont(.body)
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(metrics.points(10))
            .background(selected ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: metrics.points(8)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityHint(option.detail)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
