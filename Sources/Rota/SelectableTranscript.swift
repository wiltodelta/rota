import AppKit

/// A single read-only native text view owns all transcript selection and standard Copy commands.
@MainActor
final class TranscriptScrollView: NSScrollView, NSTextViewDelegate {
    private var firstUpdate = true
    private var preserveViewportOnNextUpdate = false
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
        // Activity links use quiet caption colors; document links keep the system link color.
        text.linkTextAttributes = [:]
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
        text.textContainerInset = NSSize(width: inset, height: text.textContainerInset.height)
        container.containerSize = NSSize(width: max(1, width - 2 * inset), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        // Layout bookkeeping can extend past the final glyph. Scroll to content, not blank paragraphs.
        let last = (text.string as NSString)
            .rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        let end: CGRect
        if last.location == NSNotFound {
            end = .zero
        } else {
            let glyphs = layout.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
            end = layout.boundingRect(forGlyphRange: glyphs, in: container)
        }
        let verticalInset = min(20, max(0, (contentSize.height - end.height) / 2))
        text.textContainerInset = NSSize(width: inset, height: verticalInset)
        let size = NSSize(width: width,
                          height: max(contentSize.height, end.maxY + 2 * verticalInset))
        if text.frame.size != size { text.setFrameSize(size) }
        scrollViewport(to: contentView.bounds.origin)
    }

    /// A resized document can no longer contain the old scroll point.
    private func scrollViewport(to origin: NSPoint) {
        var bounds = contentView.bounds
        bounds.origin = origin
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }

    func update(_ document: NSAttributedString) {
        guard transcript.textStorage?.isEqual(to: document) != true else { return }
        let old = transcript.string
        let ranges = transcript.selectedRanges.map { $0.rangeValue }
        let origin = contentView.bounds.origin
        let follow = !preserveViewportOnNextUpdate && (firstUpdate || (ranges.allSatisfy { $0.length == 0 }
                                      && contentView.bounds.maxY >= transcript.frame.maxY - 60))
        preserveViewportOnNextUpdate = false
        transcript.textStorage?.setAttributedString(document)
        fitText()
        let translate = Self.selectionTranslation(replacing: old, with: document.string)
        transcript.selectedRanges = ranges.map { NSValue(range: translate($0)) }
        if follow {
            scrollViewport(to: NSPoint(x: 0, y: max(0, transcript.frame.height - contentSize.height)))
        } else {
            scrollViewport(to: origin)
        }
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
            preserveViewportOnNextUpdate = true
            activityToggled?(id)
            return true
        }
        return false
    }
}
