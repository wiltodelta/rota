import AppKit
import SwiftUI

/// The chat's text: one family for messages, a monospaced one for commands and
/// output, and one base size both follow. App zoom scales this and the system
/// sizes used by the sidebar and forms independently of this preference.
@MainActor
@Observable
final class ChatTextSettings {
    static let defaultSize: Double = 14
    static let scales: ClosedRange<Double> = 0.5...2
    /// Stored size is relative to app zoom, so it can compensate at either limit.
    static let sizes: ClosedRange<Double> = (defaultSize * 0.25)...(defaultSize * 4)

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
            defaults.set(size, forKey: "chatFontSize")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        family = defaults.string(forKey: "chatFontFamily") ?? ""
        codeFamily = defaults.string(forKey: "chatCodeFontFamily") ?? ""
        let stored = defaults.double(forKey: "chatFontSize")
        size = Self.normalize(stored == 0 ? Self.defaultSize : stored)
    }

    func body(scale: Double) -> Font { font(family, size: effectiveSize(appScale: scale)) }
    func code(scale: Double) -> Font { codeFont(size: effectiveSize(appScale: scale) * 0.9) }

    func effectiveScale(appScale: Double) -> Double {
        min(max(size / Self.defaultSize * appScale, Self.scales.lowerBound), Self.scales.upperBound)
    }

    func effectiveSize(appScale: Double) -> Double { Self.defaultSize * effectiveScale(appScale: appScale) }

    func canIncrease(appScale: Double) -> Bool { effectiveScale(appScale: appScale) < Self.scales.upperBound - 1e-7 }
    func canDecrease(appScale: Double) -> Bool { effectiveScale(appScale: appScale) > Self.scales.lowerBound + 1e-7 }

    func bigger(appScale: Double = 1) { adjust(1, appScale: appScale) }
    func smaller(appScale: Double = 1) { adjust(-1, appScale: appScale) }
    func reset(appScale: Double = 1) { size = Self.defaultSize / appScale }

    private func adjust(_ direction: Double, appScale: Double) {
        let current = effectiveScale(appScale: appScale)
        let next = current + direction * 0.1 * appScale
        let bounded = min(max(next, Self.scales.lowerBound), Self.scales.upperBound)
        guard abs(bounded - current) > 1e-7 else { return }
        size = Self.defaultSize * bounded / appScale
    }

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
