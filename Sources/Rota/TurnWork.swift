import AppKit

/// Native fonts and paragraph styles shared by every block in the selectable transcript.
@MainActor
struct TranscriptStyle {
    let font: NSFont
    let codeFont: NSFont
    let smallFont: NSFont
    let interfaceScale: Double

    init(family: String, codeFamily: String, size: Double, interfaceScale: Double = 1) {
        self.interfaceScale = interfaceScale
        func font(_ family: String, size: Double, fallback: NSFont) -> NSFont {
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? fallback
        }
        self.font = font(family, size: size, fallback: .systemFont(ofSize: size))
        codeFont = font(codeFamily, size: size * 0.9,
                        fallback: .monospacedSystemFont(ofSize: size * 0.9, weight: .regular))
        smallFont = font(family, size: size * 0.82, fallback: .systemFont(ofSize: size * 0.82))
    }

    func attributes(code: Bool = false, small: Bool = false, indent: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = (code ? 4 : 8) * interfaceScale
        paragraph.firstLineHeadIndent = indent * interfaceScale
        paragraph.headIndent = indent * interfaceScale
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: code ? codeFont : small ? smallFont : font,
                .foregroundColor: small ? NSColor.labelColor.withAlphaComponent(0.66) : NSColor.labelColor,
                .paragraphStyle: paragraph]
    }
}
