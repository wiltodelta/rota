import AppKit
import SwiftUI

/// One persisted zoom for Rota's content. System-owned window chrome and menus
/// keep their native size. Fonts and layout are recomputed, never raster-scaled.
@MainActor
@Observable
final class InterfaceScaleSettings {
    static let levels: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5]
    private let defaults: UserDefaults

    var factor: Double {
        didSet {
            let normalized = Self.normalized(factor)
            if factor != normalized { factor = normalized }
            defaults.set(factor, forKey: "interfaceScale")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: "interfaceScale") == nil ? 1 : defaults.double(forKey: "interfaceScale")
        factor = Self.normalized(stored)
    }

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return levels.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    var canIncrease: Bool { factor < Self.levels.last! }
    var canDecrease: Bool { factor > Self.levels.first! }
    func increase() { factor = Self.levels.first { $0 > factor } ?? factor }
    func decrease() { factor = Self.levels.last { $0 < factor } ?? factor }
    func reset() { factor = 1 }
}

/// Logical point dimensions share a scale, while SwiftUI retains the display's
/// real backing scale. Core Text, SF Symbols and shapes render at the final size.
struct InterfaceScale: Equatable {
    var factor: Double = 1
    func points(_ value: CGFloat) -> CGFloat { value * factor }

    /// Native controls use their supported size variants instead of a view transform.
    var controlSize: ControlSize {
        if factor >= 1.5 { return .extraLarge }
        if factor >= 1.25 { return .large }
        return factor < 0.9 ? .small : .regular
    }

    /// Sheets, and Settings' readable form width, stay within the minimum main-window
    /// width even at maximum zoom.
    func sheetWidth(_ value: CGFloat) -> CGFloat { min(points(value), 780) }
}

extension EnvironmentValues {
    @Entry var interfaceScale = InterfaceScale()
}

extension View {
    func interfaceScale(_ settings: InterfaceScaleSettings) -> some View {
        modifier(InterfaceScaleModifier(settings: settings))
    }

    func interfaceFont(_ style: InterfaceTextStyle) -> some View {
        modifier(InterfaceFontModifier(style: style))
    }

    func interfaceSystemFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(InterfaceSystemFontModifier(size: size, weight: weight))
    }
}

/// Read the observable setting in a SwiftUI body, not when AppKit constructs
/// a hosting controller. Otherwise each window retains its initial scale.
private struct InterfaceScaleModifier: ViewModifier {
    let settings: InterfaceScaleSettings

    func body(content: Content) -> some View {
        let scale = InterfaceScale(factor: settings.factor)
        content.environment(\.interfaceScale, scale)
            .font(Font(InterfaceTypography.font(size: scale.points(NSFont.systemFontSize))))
            .environment(\.defaultMinListRowHeight, scale.points(22))
            .controlSize(scale.controlSize)
    }
}

/// The bundled interface face at native text-style sizes. Chat has its own preferences.
@MainActor
enum InterfaceTypography {
    static func font(size: CGFloat, semibold: Bool = false) -> NSFont {
        BundledFonts.register()
        return NSFontManager.shared.font(withFamily: BundledFonts.interfaceFamily, traits: [],
                                         weight: semibold ? 8 : 5, size: size)
            ?? .systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
    }
}

enum InterfaceTextStyle {
    case body, callout, caption, caption2, headline, title2

    var native: NSFont.TextStyle {
        switch self {
        case .body: .body
        case .callout: .callout
        case .caption: .caption1
        case .caption2: .caption2
        case .headline: .headline
        case .title2: .title2
        }
    }
}

private struct InterfaceFontModifier: ViewModifier {
    @Environment(\.interfaceScale) private var scale
    let style: InterfaceTextStyle

    func body(content: Content) -> some View {
        content.font(Font(InterfaceTypography.font(
            size: scale.points(NSFont.preferredFont(forTextStyle: style.native).pointSize),
            semibold: style == .headline)))
    }
}

private struct InterfaceSystemFontModifier: ViewModifier {
    @Environment(\.interfaceScale) private var scale
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: scale.points(size), weight: weight))
    }
}
