import AppKit
import RotaCore
import SwiftUI

/// Selectable prose in one AppKit text view, so a drag or Select All runs across
/// paragraphs, headings and list items. SwiftUI's `Text` stops a selection at its
/// own edge and ignores paragraph styles, which a list's hanging indent needs.
struct ProseText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> ProseTextView { ProseTextView.make() }

    func updateNSView(_ view: ProseTextView, context: Context) {
        guard let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProseTextView, context: Context) -> CGSize? {
        nsView.fittingSize(width: proposal.width)
    }
}

final class ProseTextView: NSTextView {
    /// Unbounded, but finite: a container of `greatestFiniteMagnitude` lays out one line.
    private static let unbounded: CGFloat = 1e7

    static func make() -> ProseTextView {
        let view = ProseTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        // SwiftUI sizes the view; growing itself would set a zero-width frame mid-measurement.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        return view
    }

    // Width tracking, and any resize to the current width, which layout itself
    // issues, would reset a measurement to the frame mid-layout.
    override func setFrameSize(_ size: NSSize) {
        let resized = size.width != frame.width
        super.setFrameSize(size)
        if resized { textContainer?.size = NSSize(width: size.width, height: Self.unbounded) }
    }

    /// The laid-out text at `width`, or at its natural width when SwiftUI asks for the ideal size.
    func fittingSize(width: CGFloat?) -> CGSize {
        guard let container = textContainer, let layout = layoutManager else { return .zero }
        let bounded = width.flatMap { $0.isFinite ? max($0, 1) : nil }
        container.size = NSSize(width: bounded ?? Self.unbounded, height: Self.unbounded)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: bounded ?? ceil(used.width), height: ceil(used.height))
    }
}

/// An agent's Markdown as `MarkdownText` lays it out: consecutive headings,
/// paragraphs and list items share one `ProseText`; code, tables and images stay views.
@MainActor
enum MarkdownProse {
    enum Part {
        case prose([MarkdownBlock])
        case block(MarkdownBlock)
    }

    static func parts(_ blocks: [MarkdownBlock]) -> [Part] {
        var parts: [Part] = []
        for block in blocks {
            guard isProse(block) else {
                parts.append(.block(block))
                continue
            }
            if case .prose(let run) = parts.last {
                parts[parts.count - 1] = .prose(run + [block])
            } else {
                parts.append(.prose([block]))
            }
        }
        return parts
    }

    /// Images load as views of their own, so a block that shows one stays outside the run.
    private static func isProse(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .listItem, .paragraph: return MarkdownImageReference.references(in: [block]).isEmpty
        case .code, .table: return false
        }
    }

    /// Paragraphs and list indents follow the same two zooms as the text.
    static func attributed(_ blocks: [MarkdownBlock], text: ChatTextSettings) -> NSAttributedString {
        let spacing = text.effectiveSize(6)
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let style = NSMutableParagraphStyle()
            let paragraph: NSAttributedString
            switch block {
            case .heading(let level, let content):
                paragraph = inline(content, text: text, font: text.appKitHeading(level: level))
                style.minimumLineHeight = text.headingLineHeight(level: level)
                style.paragraphSpacingBefore = spacing + text.effectiveSize(4)
            case .listItem(let marker, let content, let level):
                let font = text.appKitBody
                let start = CGFloat(level) * text.effectiveSize(16)
                // The marker's own width plus the gap the row's stack had, so wrapped lines hang under the text.
                let textStart = start + (marker as NSString).size(withAttributes: [.font: font]).width + spacing
                style.firstLineHeadIndent = start
                style.headIndent = textStart
                style.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
                let item = NSMutableAttributedString(string: marker + "\t", attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.66),
                ])
                item.append(inline(content, text: text, font: font))
                paragraph = item
                style.paragraphSpacingBefore = spacing
            case .paragraph(let content):
                paragraph = inline(content, text: text, font: text.appKitBody)
                style.paragraphSpacingBefore = spacing
            case .code, .table:
                preconditionFailure("parts(_:) keeps code and tables out of a prose run")
            }
            if index == 0 {
                style.paragraphSpacingBefore = 0
            } else {
                result.append(NSAttributedString(string: "\n"))
            }
            let range = NSRange(location: result.length, length: paragraph.length)
            result.append(paragraph)
            if style.minimumLineHeight == 0 { style.minimumLineHeight = text.bodyLineHeight }
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    static func code(_ source: String, text: ChatTextSettings) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = text.codeLineHeight
        return NSAttributedString(string: source, attributes: [
            .font: text.appKitCode, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
    }

    /// Inline Markdown in AppKit attributes: emphasis, code spans, strikethrough and links.
    /// A line break inside a block stays inside its paragraph, under the same spacing.
    static func inline(_ source: String, text: ChatTextSettings, font: NSFont) -> NSAttributedString {
        let parsed = inlineMarkdown(source)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let string = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            let intent = run.inlinePresentationIntent ?? []
            var runFont = font
            if intent.contains(.code) { runFont = text.appKitCode(like: font) }
            let fonts = NSFontManager.shared
            if intent.contains(.stronglyEmphasized) { runFont = fonts.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = fonts.convert(runFont, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: NSColor.labelColor]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        return result
    }
}

/// Copies one message's text, then confirms with a checkmark for a moment.
struct CopyButton: View {
    let text: String
    var help = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : help)
        .accessibilityLabel(copied ? "Copied" : help)
    }
}
