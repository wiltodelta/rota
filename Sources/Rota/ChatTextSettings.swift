import AppKit
import SwiftUI

/// Independent chat fonts and point size. Native navigation and controls keep
/// their standard sizes when the chat text changes.
@MainActor
@Observable
final class ChatTextSettings {
    static let defaultSize: Double = 14
    static let sizes: ClosedRange<Double> = 10...28

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
            let clamped = Self.normalize(size)
            if clamped != size { size = clamped }
            defaults.set(size, forKey: "chatTextPointSize")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        family = defaults.string(forKey: "chatFontFamily") ?? ""
        codeFamily = defaults.string(forKey: "chatCodeFontFamily") ?? ""
        if let stored = defaults.object(forKey: "chatTextPointSize") as? Double {
            size = Self.normalize(stored)
        } else {
            // Preserve the visible chat size once when retiring global interface zoom.
            let legacy = defaults.double(forKey: "chatFontSize")
            let percent = defaults.object(forKey: "appZoomPercent") as? Int ?? 100
            let bounded = min(max(percent, 50), 200)
            let appScale = (Double(bounded) / 10).rounded() / 10
            size = Self.normalize((legacy == 0 ? Self.defaultSize : legacy) * appScale)
            defaults.set(size, forKey: "chatTextPointSize")
        }
    }

    var scale: Double { size / Self.defaultSize }
    var canIncrease: Bool { size < Self.sizes.upperBound - 1e-7 }
    var canDecrease: Bool { size > Self.sizes.lowerBound + 1e-7 }

    func body() -> Font { font(family, size: size) }
    func code() -> Font { codeFont(size: InterfaceTypography.readableSize(size * 0.9)) }
    func bigger() { size += Self.defaultSize * 0.1 }
    func smaller() { size -= Self.defaultSize * 0.1 }
    func reset() { size = Self.defaultSize }

    private static func normalize(_ value: Double) -> Double {
        value.isFinite ? min(max(value, sizes.lowerBound), sizes.upperBound) : defaultSize
    }

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
