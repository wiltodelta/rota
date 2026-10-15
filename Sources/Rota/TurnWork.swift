import AppKit

/// Native fonts and paragraph styles shared by every block in the selectable transcript.
@MainActor
struct TranscriptStyle {
    let font: NSFont
    let codeFont: NSFont
    let smallFont: NSFont

    init(family: String, codeFamily: String, size: Double) {
        func font(_ family: String, size: Double, fallback: NSFont) -> NSFont {
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? fallback
        }
        let bodySize = InterfaceTypography.readableSize(size)
        let codeSize = InterfaceTypography.readableSize(size * 0.9)
        let captionSize = InterfaceTypography.readableSize(size * 0.82)
        self.font = font(family, size: bodySize, fallback: .systemFont(ofSize: bodySize))
        codeFont = font(codeFamily, size: codeSize,
                        fallback: .monospacedSystemFont(ofSize: codeSize, weight: .regular))
        smallFont = font(family, size: captionSize, fallback: .systemFont(ofSize: captionSize))
    }

    func attributes(code: Bool = false, small: Bool = false, indent: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = (code ? 4 : 8)
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: code ? codeFont : small ? smallFont : font,
                .foregroundColor: small ? NSColor.labelColor.withAlphaComponent(0.66) : NSColor.labelColor,
                .paragraphStyle: paragraph]
    }
}
