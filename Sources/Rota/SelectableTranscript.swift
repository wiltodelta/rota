import AppKit

/// A single read-only native text view owns all transcript selection and standard Copy commands.
@MainActor
final class TranscriptScrollView: NSScrollView, NSTextViewDelegate {
    private var firstUpdate = true
    var activityToggled: ((Int) -> Void)?

    let transcript: NSTextView

    init() {
        transcript = NSTextView(frame: .zero)
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        let text = transcript
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.lineFragmentPadding = 0
        text.backgroundColor = .textBackgroundColor
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue]
        text.setAccessibilityIdentifier("chatTranscript")
        text.setAccessibilityLabel("Chat transcript")
        text.delegate = self
        documentView = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tile() {
        super.tile()
        fitText()
    }

    private func fitText() {
        guard let text = documentView as? NSTextView, let container = text.textContainer,
              let layout = text.layoutManager else { return }
        let width = contentSize.width
        let inset = min(width / 4, max(24, (width - 712) / 2))
        text.textContainerInset = NSSize(width: inset, height: 20)
        container.containerSize = NSSize(width: max(1, width - 2 * inset), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let size = NSSize(width: width,
                          height: max(contentSize.height, layout.usedRect(for: container).maxY + 40))
        if text.frame.size != size { text.setFrameSize(size) }
    }

    func update(_ document: NSAttributedString) {
        guard transcript.textStorage?.isEqual(to: document) != true else { return }
        let old = transcript.string
        let ranges = transcript.selectedRanges.map { $0.rangeValue }
        let origin = contentView.bounds.origin
        let follow = firstUpdate || (ranges.allSatisfy { $0.length == 0 }
                                     && contentView.bounds.maxY >= transcript.frame.maxY - 60)
        transcript.textStorage?.setAttributedString(document)
        fitText()
        let translate = Self.selectionTranslation(replacing: old, with: document.string)
        transcript.selectedRanges = ranges.map { NSValue(range: translate($0)) }
        if follow {
            contentView.scroll(to: NSPoint(x: 0, y: max(0, transcript.frame.height - contentSize.height)))
        } else {
            contentView.scroll(to: origin)
        }
        reflectScrolledClipView(contentView)
        firstUpdate = false
    }

    /// Translate UTF-16 selection offsets across a changed region, including text inserted before it.
    private static func selectionTranslation(replacing old: String, with new: String) -> (NSRange) -> NSRange {
        if old == new { return { $0 } }
        let oldScalars = Array(old.unicodeScalars)
        let newScalars = Array(new.unicodeScalars)
        var prefix = 0
        while prefix < min(oldScalars.count, newScalars.count), oldScalars[prefix] == newScalars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldScalars.count, newScalars.count) - prefix,
              oldScalars[oldScalars.count - suffix - 1] == newScalars[newScalars.count - suffix - 1] { suffix += 1 }
        let head = oldScalars.prefix(prefix).reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
        let tail = oldScalars.suffix(suffix).reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
        let oldLength = old.utf16.count
        let newLength = new.utf16.count
        func move(_ offset: Int) -> Int {
            if offset <= head { return offset }
            if offset >= oldLength - tail { return offset + newLength - oldLength }
            return head + min(offset - head, newLength - head - tail)
        }
        return { range in
            let start = min(max(move(range.location), 0), newLength)
            let end = min(max(move(NSMaxRange(range)), start), newLength)
            return NSRange(location: start, length: end - start)
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if url?.scheme == "rota-activity", let id = url?.host.flatMap(Int.init) {
            activityToggled?(id)
            return true
        }
        return false
    }
}
