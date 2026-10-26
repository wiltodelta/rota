import AppKit
import SwiftUI

/// The chat's text: one family for messages, a monospaced one for commands and
/// output, and one text scale, multiplied by the app-wide interface scale.
@MainActor
@Observable
final class ChatTextSettings {
    static let scales: ClosedRange<Double> = 0.7...2
    static let baseSize: Double = 14
    static let defaultFamily = BundledFonts.interfaceFamily
    static let defaultCodeFamily = BundledFonts.monospacedFamily
    private static let fontMetrics = NSLayoutManager()

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

    var scale: Double {
        didSet {
            let normalized = Self.normalized(scale)
            if normalized != scale { scale = normalized }
            defaults.set(scale, forKey: "chatTextScale")
        }
    }

    init(defaults: UserDefaults = .standard, interfaceScale: InterfaceScaleSettings? = nil) {
        BundledFonts.register()
        self.interfaceScale = interfaceScale
        self.defaults = defaults
        family = defaults.string(forKey: "chatFontFamily") ?? Self.defaultFamily
        codeFamily = defaults.string(forKey: "chatCodeFontFamily") ?? Self.defaultCodeFamily
        if defaults.object(forKey: "chatTextScale") != nil {
            scale = Self.normalized(defaults.double(forKey: "chatTextScale"))
        } else {
            let stored = defaults.double(forKey: "chatFontSize")
            let legacySize = stored.isFinite && stored > 0 ? min(max(stored, 10), 28) : Self.baseSize
            scale = legacySize / Self.baseSize
            defaults.set(scale, forKey: "chatTextScale")
        }
    }

    private static func normalized(_ scale: Double) -> Double {
        scale.isFinite ? min(max(scale, scales.lowerBound), scales.upperBound) : 1
    }

    var body: Font { Font(appKitBody) }
    var code: Font { Font(appKitCode) }
    var small: Font { font(family, size: 11.5) }
    var smallCode: Font { codeFont(size: 11.5) }

    var bodyLineHeight: Double { effectiveSize(22) }
    var codeLineHeight: Double { effectiveSize(20) }
    var bodyLineSpacing: Double { max(0, bodyLineHeight - Self.fontMetrics.defaultLineHeight(for: appKitBody)) }

    func heading(level: Int) -> Font {
        Font(appKitHeading(level: level))
    }

    func headingLineHeight(level: Int) -> Double {
        effectiveSize(Self.headingMetrics(level).lineHeight)
    }

    func headingLineSpacing(level: Int) -> Double {
        max(0, headingLineHeight(level: level) - Self.fontMetrics.defaultLineHeight(for: appKitHeading(level: level)))
    }

    private static func headingMetrics(_ level: Int) -> (size: Double, lineHeight: Double) {
        [(19, 27), (17, 25), (14.5, 22), (14, 22), (13.5, 21), (13.5, 21)][min(max(level, 1), 6) - 1]
    }

    /// Both zooms apply to typography, without changing either saved preference.
    func effectiveSize(_ size: Double) -> Double {
        size * scale * (interfaceScale?.factor ?? 1)
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
    var appKitBody: NSFont { appKitFont(size: Self.baseSize, semibold: false) }
    var appKitCode: NSFont { appKitCode(like: .systemFont(ofSize: effectiveSize(12.5))) }

    func appKitHeading(level: Int) -> NSFont {
        appKitFont(size: Self.headingMetrics(level).size, semibold: level <= 4)
    }

    private func appKitFont(size: Double, semibold: Bool) -> NSFont {
        let size = effectiveSize(size)
        if !family.isEmpty, let font = NSFontManager.shared.font(withFamily: family, traits: [],
                                                                 weight: semibold ? 8 : 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
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
