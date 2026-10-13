import RotaCore
import SwiftUI

/// A live provider request. Choices are never submitted by opening the session.
struct SessionRequestView: View {
    @Environment(\.interfaceMetrics) private var metrics
    let request: SessionRequest
    let reply: (SessionResponse) -> Void
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: metrics(12)) {
            Text(request.title).scaledFont(.headline)
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail).scaledFont(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: metrics(110))
            }
            if !request.questions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: metrics(12)) {
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: metrics(6)) {
                    Text(question.title).scaledFont(.callout)
                    if !question.options.isEmpty && !question.multiple {
                        InterfacePicker("Choose an answer",
                                        value: answers[question.id, default: ""].isEmpty
                                        ? "Choose…" : answers[question.id, default: ""],
                                        selection: answer(question.id)) {
                            Text("Choose…").tag("")
                            ForEach(question.options, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if question.multiple {
                        ForEach(question.options, id: \.self) { option in
                            Toggle(option, isOn: selected(question.id, option: option)).toggleStyle(.checkbox)
                            if let description = question.descriptions[option] {
                                Text(description).scaledFont(.caption)
                            }
                        }
                    }
                    if let explanation = question.descriptions[answers[question.id, default: ""]] {
                        Text(explanation).scaledFont(.caption)
                    }
                    if question.allowsText {
                        if question.secret { SecureField("Answer", text: answer(question.id)) } else {
                            TextField("Answer", text: answer(question.id))
                        }
                    }
                }
            }
                    }
                }
                .frame(maxHeight: metrics(180))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: metrics(8)) { buttons }
                VStack(alignment: .leading, spacing: metrics(8)) { buttons }
            }
        }
        .padding(metrics(16))
        .background(.quaternary, in: RoundedRectangle(cornerRadius: metrics(12)))
        .padding(metrics(12))
    }

    private var buttons: some View {
        ForEach(request.choices) { choice in
            Button(choice.title) { reply(.init(choice: choice.id, answers: answers)) }
                .disabled(choice.id == "submit" && request.questions.contains {
                    answers[$0.id, default: ""].trimmingCharacters(in: .whitespaces).isEmpty
                })
                .accessibilityIdentifier("requestChoice-" + choice.id)
        }
    }

    private func selected(_ id: String, option: String) -> Binding<Bool> {
        Binding(get: { answers[id, default: ""].components(separatedBy: ", ").contains(option) }, set: { selected in
            var values = answers[id, default: ""].components(separatedBy: ", ").filter { !$0.isEmpty }
            values.removeAll { $0 == option }
            if selected { values.append(option) }
            answers[id] = values.joined(separator: ", ")
        })
    }

    private func answer(_ id: String) -> Binding<String> {
        Binding(get: { answers[id, default: ""] }, set: { answers[id] = $0 })
    }
}
