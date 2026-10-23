import AppKit
import SwiftUI

/// The chat's text: one family for messages, a monospaced one for commands and
/// output, and one base size both follow, multiplied by the app-wide scale.
@MainActor
@Observable
final class ChatTextSettings {
    static let sizes: ClosedRange<Double> = 10...28
    static let defaultSize: Double = 14

    private let defaults: UserDefaults
    private let interfaceScale: InterfaceScaleSettings?

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

    init(defaults: UserDefaults = .standard, interfaceScale: InterfaceScaleSettings? = nil) {
        self.interfaceScale = interfaceScale
        self.defaults = defaults
        family = defaults.string(forKey: "chatFontFamily") ?? ""
        codeFamily = defaults.string(forKey: "chatCodeFontFamily") ?? ""
        let stored = defaults.double(forKey: "chatFontSize")
        size = stored == 0 ? Self.defaultSize : min(max(stored, Self.sizes.lowerBound), Self.sizes.upperBound)
    }

    var body: Font { font(family, size: size) }
    var code: Font { codeFont(size: size * 0.9) }
    var small: Font { font(family, size: size * 0.82) }

    /// A heading's size steps down from 1.35 times the body for `#` to the body size.
    func heading(level: Int) -> Font {
        font(family, size: size * Self.headingScale(level)).weight(.semibold)
    }

    private static func headingScale(_ level: Int) -> Double {
        [1.35, 1.2, 1.1, 1.0, 1.0, 1.0][min(max(level, 1), 6) - 1]
    }
    var smallCode: Font { codeFont(size: size * 0.82) }

    /// Clamp the base size before zooming; zoom must not overwrite the user's preference.
    func effectiveSize(_ size: Double) -> Double {
        max(Self.sizes.lowerBound, size) * (interfaceScale?.factor ?? 1)
    }

    private func font(_ family: String, size: Double) -> Font {
        let size = effectiveSize(size)
        return family.isEmpty ? .system(size: size) : .custom(family, size: size)
    }

    private func codeFont(size: Double) -> Font {
        let size = effectiveSize(size)
        return codeFamily.isEmpty ? .system(size: size, design: .monospaced) : .custom(codeFamily, size: size)
    }

    /// `body` and `heading(level:)` as AppKit fonts, for the selectable prose view.
    var appKitBody: NSFont { appKitFont(size: size, bold: false) }

    func appKitHeading(level: Int) -> NSFont {
        appKitFont(size: size * Self.headingScale(level), bold: true)
    }

    private func appKitFont(size: Double, bold: Bool) -> NSFont {
        let size = effectiveSize(size)
        if !family.isEmpty, let font = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [],
                                                                 weight: bold ? 9 : 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// A code span in running text: the code family at the surrounding size.
    func appKitCode(like font: NSFont) -> NSFont {
        if !codeFamily.isEmpty, let code = NSFont(name: codeFamily, size: font.pointSize)
            ?? NSFontManager.shared.font(withFamily: codeFamily, traits: [], weight: 5, size: font.pointSize) {
            return code
        }
        return .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
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
