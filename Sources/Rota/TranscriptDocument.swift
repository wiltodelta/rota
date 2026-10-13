import AppKit
import RotaCore

/// The entire visible conversation is one attributed string, so selection crosses every block and turn.
@MainActor
struct TranscriptDocument {
    let style: TranscriptStyle

    func make(items: [TranscriptItem], record: RunRecord, running: Bool,
              activity: [Int: Bool]) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        let turns = TranscriptTurn.group(items)
        for (index, turn) in turns.enumerated() {
            append(turn, to: text, harness: record.harness, activity: activity,
                   live: running && index == turns.count - 1)
        }
        if running { append("Working…", to: text, small: true) }
        return text
    }

    private func append(_ turn: TranscriptTurn, to text: NSMutableAttributedString, harness: Harness,
                        activity: [Int: Bool], live: Bool) {
        if let prompt = turn.prompt {
            append("You", to: text, bold: true)
            append(prompt.text, to: text)
            appendAttachments(prompt.attachments, to: text)
            if let state = prompt.delivery?.title { append(state, to: text, small: true) }
        }
        for message in turn.work where message.kind == .user {
            append("You", to: text, bold: true)
            append(message.text, to: text)
            appendAttachments(message.attachments, to: text)
            if let state = message.delivery?.title { append(state, to: text, small: true) }
        }
        let response = turn.answer.last { $0.kind == .agent } ?? turn.work.last { $0.kind == .agent }
        let responseModel = response?.model
        append(harness.title + (responseModel.map { "  " + $0 } ?? ""), to: text, bold: true)
        work(turn, to: text, open: activity[turn.id] ?? live)
        if let plan = turn.plan { appendPlan(plan, to: text) }
        for item in turn.answer {
            if item.kind == .output { append(item.text, to: text, code: true) } else {
                markdown(item.text, to: text)
            }
        }
        for note in turn.notes { append(note.text, to: text, small: true) }
        append("", to: text)
    }

    private func appendAttachments(_ files: [ChatAttachment], to text: NSMutableAttributedString) {
        for file in files {
            if let image = AttachmentPreview.image(file) {
                let attachment = NSTextAttachment()
                attachment.image = image
                let scale = min(1, min(280 / image.size.width, 180 / image.size.height))
                attachment.bounds = NSRect(origin: .zero, size: NSSize(width: image.size.width * scale,
                                                                       height: image.size.height * scale))
                text.append(NSAttributedString(attachment: attachment))
                append("", to: text)
            }
            var attributes = style.attributes(small: true)
            attributes[.link] = file.url
            text.append(NSAttributedString(string: file.name + "\n", attributes: attributes))
        }
    }

    private func work(_ turn: TranscriptTurn, to text: NSMutableAttributedString, open: Bool) {
        let activityItems = turn.work.filter { $0.kind != .user }
        guard !activityItems.isEmpty else { return }
        let count = turn.toolCount
        let label = count == 0 ? "Activity" : count == 1 ? "1 tool call" : "\(count) tool calls"
        let attributes = style.attributes(small: true).merging([
            .link: URL(string: "rota-activity://\(turn.id)")!
        ]) { _, new in new }
        text.append(NSAttributedString(string: (open ? "Hide activity: " : "Show activity: ") + label + "\n",
                                       attributes: attributes))
        if open {
            for item in activityItems {
                append(item.text, to: text, code: item.kind == .tool || item.kind == .output)
                if let state = item.delivery?.title { append(state, to: text, small: true) }
            }
        }
    }

    private func appendPlan(_ plan: TranscriptItem, to text: NSMutableAttributedString) {
        append("Plan", to: text, bold: true, small: true)
        for step in PlanStep.parse(plan.text) {
            let label: String
            switch step.status {
            case .pending: label = "To do"
            case .inProgress: label = "In progress"
            case .completed: label = "Done"
            }
            append("\(label): \(step.text)", to: text, small: true)
        }
    }

    private func append(_ value: String, to text: NSMutableAttributedString,
                        bold: Bool = false, code: Bool = false, small: Bool = false) {
        var attributes = style.attributes(code: code, small: small)
        if bold, let font = attributes[.font] as? NSFont {
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        text.append(NSAttributedString(string: value + "\n", attributes: attributes))
    }

    private func markdown(_ source: String, to text: NSMutableAttributedString) {
        for block in MarkdownBlock.parse(source) {
            switch block {
            case .heading(_, let value): inline(value, to: text, bold: true)
            case .paragraph(let value): inline(value, to: text)
            case .listItem(let marker, let value, let indent):
                inline(marker + " " + value, to: text, indent: CGFloat(indent) * 16)
            case .code(let value, let language):
                if let language { append(language, to: text, small: true) }
                append(value, to: text, code: true)
            }
        }
    }

    private func inline(_ source: String, to text: NSMutableAttributedString,
                        bold: Bool = false, indent: CGFloat = 0) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes = style.attributes(code: intent.contains(.code), indent: indent)
            if let font = attributes[.font] as? NSFont {
                var traits: NSFontTraitMask = []
                if bold || intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            if let link = run.link { attributes[.link] = link }
            text.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        text.append(NSAttributedString(string: "\n", attributes: style.attributes(indent: indent)))
    }
}
