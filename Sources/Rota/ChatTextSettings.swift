import AppKit
import SwiftUI

/// The chat's text: one family for messages, a monospaced one for commands and
/// output, and one size both follow. The sidebar and forms keep the system's.
@MainActor
@Observable
final class ChatTextSettings {
    static let sizes: ClosedRange<Double> = 10...28
    static let defaultSize: Double = 14

    private let defaults: UserDefaults

    /// A font family name, or empty for the system font.
    var family: String {
        didSet { defaults.set(family, forKey: "chatFontFamily") }
    }

    /// A monospaced family name, or empty for the system's monospaced font.
    var codeFamily: String {
        didSet { defaults.set(codeFamily, forKey: "chatCodeFontFamily") }
    }

    var size: Double {
        didSet {
            let clamped = min(max(size, Self.sizes.lowerBound), Self.sizes.upperBound)
            if clamped != size { size = clamped }
            defaults.set(size, forKey: "chatFontSize")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        family = defaults.string(forKey: "chatFontFamily") ?? ""
        codeFamily = defaults.string(forKey: "chatCodeFontFamily") ?? ""
        let stored = defaults.double(forKey: "chatFontSize")
        size = stored == 0 ? Self.defaultSize : stored
    }

    var body: Font { font(family, size: size) }
    var code: Font { codeFont(size: size * 0.9) }
    var small: Font { font(family, size: size * 0.82) }

    /// A heading's size steps down from 1.35 times the body for `#` to the body size.
    func heading(level: Int) -> Font {
        let scale = [1.35, 1.2, 1.1, 1.0, 1.0, 1.0][min(max(level, 1), 6) - 1]
        return font(family, size: size * scale).weight(.semibold)
    }
    var smallCode: Font { codeFont(size: size * 0.82) }

    func bigger() { size += 1 }
    func smaller() { size -= 1 }
    func reset() { size = Self.defaultSize }

    private func font(_ family: String, size: Double) -> Font {
        family.isEmpty ? .system(size: size) : .custom(family, size: size)
    }

    private func codeFont(size: Double) -> Font {
        codeFamily.isEmpty ? .system(size: size, design: .monospaced) : .custom(codeFamily, size: size)
    }

    /// Installed families, for the pickers.
    static var families: [String] { NSFontManager.shared.availableFontFamilies }

    /// Families whose regular face is fixed-pitch.
    static var monospacedFamilies: [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12)
                ?? manager.availableMembers(ofFontFamily: family)?.first
                    .flatMap({ $0.first as? String }).flatMap({ NSFont(name: $0, size: 12) }) else { return false }
            return font.isFixedPitch
        }
    }
}
