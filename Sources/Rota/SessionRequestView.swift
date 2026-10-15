import RotaCore
import SwiftUI

/// A live provider request. Choices are never submitted by opening the session.
struct SessionRequestView: View {
    let request: SessionRequest
    let reply: (SessionResponse) -> Void
    @State private var answers = QuestionAnswerDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).interfaceFont(.headline)
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail).interfaceFont(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            if !request.questions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.title).interfaceFont(.callout)
                    if !question.options.isEmpty && !question.multiple {
                        InterfacePicker("Choose an answer",
                                        value: answers.text[question.id, default: ""].isEmpty
                                        ? "Choose…" : answers.text[question.id, default: ""],
                                        selection: answer(question.id)) {
                            Text("Choose…").tag("")
                            ForEach(question.options, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if question.multiple {
                        ForEach(question.options, id: \.self) { option in
                            Toggle(option, isOn: selected(question.id, option: option)).toggleStyle(.checkbox)
                            if let description = question.descriptions[option] {
                                Text(description).interfaceFont(.caption)
                            }
                        }
                    }
                    if let explanation = question.descriptions[answers.text[question.id, default: ""]] {
                        Text(explanation).interfaceFont(.caption)
                    }
                    if question.allowsText {
                        if question.secret {
                            SecureField("Answer", text: answer(question.id)).accessibilityLabel(question.title)
                                .accessibilityIdentifier("requestAnswer-" + question.id)
                        } else {
                            TextField("Answer", text: answer(question.id))
                                .accessibilityLabel(question.title)
                                .accessibilityIdentifier("requestAnswer-" + question.id)
                        }
                    }
                }
            }
                    }
                }
                .scrollIndicators(.visible)
                .frame(minHeight: 90, maxHeight: 180)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }

    private var buttons: some View {
        ForEach(request.choices) { choice in
            Button(choice.title) { reply(.init(choice: choice.id, answers: answers.values(for: request.questions))) }
                .disabled(choice.id == "submit" && request.questions.contains {
                    answers.value(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
                .accessibilityIdentifier("requestChoice-" + choice.id)
        }
    }

    private func selected(_ id: String, option: String) -> Binding<Bool> {
        Binding(get: { answers.isSelected(id, option: option) }, set: { selected in
            answers.select(id, option: option, selected: selected)
        })
    }

    private func answer(_ id: String) -> Binding<String> {
        Binding(get: { answers.text[id, default: ""] }, set: { answers.text[id] = $0 })
    }
}

/// Question input stays local until the user submits the provider request.
struct QuestionAnswerDraft {
    var text: [String: String] = [:]
    private var selections: [String: Set<String>] = [:]

    func isSelected(_ id: String, option: String) -> Bool {
        selections[id, default: []].contains(option)
    }

    mutating func select(_ id: String, option: String, selected: Bool) {
        if selected { selections[id, default: []].insert(option) } else {
            selections[id, default: []].remove(option)
        }
    }

    func value(for question: SessionRequest.Question) -> String {
        let other = text[question.id, default: ""]
        guard question.multiple else { return other }
        var values = question.options.filter { isSelected(question.id, option: $0) }
        if !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append(other) }
        return values.joined(separator: ", ")
    }

    func values(for questions: [SessionRequest.Question]) -> [String: String] {
        questions.reduce(into: [:]) { $0[$1.id] = value(for: $1) }
    }
}
